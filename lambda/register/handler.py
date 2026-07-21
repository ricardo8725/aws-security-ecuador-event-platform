"""
Registration handler for AWS GenAI Security Day 2026.
Validates incoming registrations, stores them in DynamoDB, sends confirmation email via SES.
Compliant with Ecuador's LOPDP (Ley Organica de Proteccion de Datos Personales).
"""
import json
import os
import re
import uuid
import string
import random
import html
import io
import base64
from datetime import datetime, timezone
from urllib.request import urlopen, Request
from urllib.parse import urlencode

import boto3
import qrcode
from botocore.exceptions import ClientError

# Config
TABLE_NAME = os.environ["TABLE_NAME"]
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "")
SES_FROM_ADDRESS = os.environ.get("SES_FROM_ADDRESS", "noreply@awssecurityecuador.com")
EVENT_NAME = os.environ.get("EVENT_NAME", "AWS GenAI Security Day 2026")
EVENT_DATE = os.environ.get("EVENT_DATE", "18 de Julio, 2026")
EVENT_TIME = os.environ.get("EVENT_TIME", "08h30 - 16h00 ECT")
EVENT_VENUE = os.environ.get("EVENT_VENUE", "Por confirmar")
EVENT_URL = os.environ.get("EVENT_URL", "https://aisecurity.awssecurityecuador.com")
MAX_REGISTRATIONS = int(os.environ.get("MAX_REGISTRATIONS", "200"))
TURNSTILE_SECRET = os.environ.get("TURNSTILE_SECRET", "")
QR_BUCKET = os.environ.get("QR_BUCKET", "")
QR_CDN_DOMAIN = os.environ.get("QR_CDN_DOMAIN", "")

# AWS clients
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
ses = boto3.client("sesv2", region_name="us-east-1")
s3 = boto3.client("s3", region_name="us-east-1")

# Validation patterns
EMAIL_RE = re.compile(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
PHONE_RE = re.compile(r"^[\d\s\+\-\(\)]{7,20}$")

ALLOWED_EXPERIENCE = {"beginner", "intermediate", "advanced", "expert"}
ALLOWED_AI_EXPERIENCE = {"none", "basic", "intermediate", "advanced"}
ALLOWED_CITIES = {
    "quito", "guayaquil", "cuenca", "ambato", "manta",
    "loja", "machala", "other_ec", "other_country"
}
ALLOWED_EMPLOYMENT = {
    "employed", "open_to_offers", "seeking", "freelance", "student", "prefer_not_to_say"
}


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        },
        "body": json.dumps(body),
    }


def sanitize_string(value, max_length):
    """Strip whitespace and limit length to prevent abuse."""
    if not isinstance(value, str):
        return ""
    return value.strip()[:max_length]


# Regex to detect URLs in free-text fields (SSRF prevention)
URL_PATTERN = re.compile(
    r'(https?://[^\s<>"\']+|ftp://[^\s<>"\']+|file://[^\s<>"\']+)',
    re.IGNORECASE
)


def sanitize_freetext(value, max_length):
    """Strip whitespace, limit length, and remove URLs to prevent SSRF via email content."""
    if not isinstance(value, str):
        return ""
    cleaned = value.strip()[:max_length]
    # Remove any URLs from free-text fields
    cleaned = URL_PATTERN.sub("[URL removed]", cleaned)
    return cleaned


def mask_email(email):
    """Mask email for logging: u***@d***.com"""
    if not email or "@" not in email:
        return "***"
    local, domain = email.split("@", 1)
    masked_local = local[0] + "***" if local else "***"
    parts = domain.split(".")
    masked_domain = parts[0][0] + "***" if parts[0] else "***"
    return f"{masked_local}@{masked_domain}.{parts[-1]}" if len(parts) > 1 else f"{masked_local}@{masked_domain}"


def generate_registration_code():
    """Generate a short 8-character alphanumeric registration code."""
    chars = string.ascii_uppercase + string.digits
    return ''.join(random.choices(chars, k=8))


def generate_qr_code_base64(data_str):
    """Generate a QR code as base64-encoded PNG image."""
    qr = qrcode.QRCode(version=1, error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=8, border=2)
    qr.add_data(data_str)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buffer = io.BytesIO()
    img.save(buffer, format="PNG")
    buffer.seek(0)
    return base64.b64encode(buffer.read()).decode("utf-8")


def upload_qr_to_s3(qr_data_str, registration_id):
    """Generate QR code, upload to S3, return CloudFront URL (never expires)."""
    qr = qrcode.QRCode(version=1, error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=8, border=2)
    qr.add_data(qr_data_str)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buffer = io.BytesIO()
    img.save(buffer, format="PNG")
    buffer.seek(0)

    if not QR_BUCKET or not QR_CDN_DOMAIN:
        return None

    key = f"qr/{registration_id}.png"

    try:
        s3.put_object(
            Bucket=QR_BUCKET,
            Key=key,
            Body=buffer.getvalue(),
            ContentType="image/png",
        )
        # Return CloudFront URL — no expiration, bucket stays private
        return f"https://{QR_CDN_DOMAIN}/{key}"
    except ClientError as exc:
        print(f"[s3-error] Failed to upload QR: {exc}")
        return None


def verify_turnstile(token, remote_ip=""):
    """Verify Cloudflare Turnstile token. Returns True if valid."""
    if not TURNSTILE_SECRET:
        return True  # Skip if not configured
    if not token:
        return False

    try:
        payload = urlencode({
            "secret": TURNSTILE_SECRET,
            "response": token,
            "remoteip": remote_ip,
        }).encode("utf-8")

        req = Request(
            "https://challenges.cloudflare.com/turnstile/v0/siteverify",
            data=payload,
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with urlopen(req, timeout=5) as resp:
            result = json.loads(resp.read())
            return result.get("success", False)
    except Exception as exc:
        print(f"[turnstile-error] {exc}")
        return False


def get_registration_count(event_id):
    """Count real registrations for an event via the event-index GSI.

    Excludes EMAIL_LOCK# items (which also carry the `event` attribute) by
    filtering on lock_type, and paginates so the count is exact even past 1MB.
    """
    try:
        count = 0
        last_key = None
        while True:
            kwargs = {
                "IndexName": "event-index",
                "KeyConditionExpression": "event = :eid",
                "FilterExpression": "attribute_not_exists(lock_type)",
                "ExpressionAttributeValues": {":eid": event_id},
                "Select": "COUNT",
            }
            if last_key:
                kwargs["ExclusiveStartKey"] = last_key
            result = table.query(**kwargs)
            count += result.get("Count", 0)
            last_key = result.get("LastEvaluatedKey")
            if not last_key:
                break
        return count
    except ClientError:
        # Fail-closed: if we can't count, assume full to prevent over-registration
        return MAX_REGISTRATIONS


def validate_payload(data):
    """Validate the registration payload. Returns (is_valid, error_message)."""

    required = ["first_name", "last_name", "email", "experience", "ai_experience", "city"]
    for field in required:
        if not data.get(field):
            return False, f"El campo '{field}' es obligatorio."

    # Type validation — all fields must be strings (fixes type confusion 500 errors)
    string_fields = ["first_name", "last_name", "email", "experience", "ai_experience", "city",
                     "phone", "company", "role", "expectations", "event", "employment_status"]
    for field in string_fields:
        val = data.get(field)
        if val is not None and not isinstance(val, str):
            return False, f"El campo '{field}' debe ser texto."

    email = sanitize_string(data["email"], 120).lower()
    if not EMAIL_RE.match(email):
        return False, "El email proporcionado no es valido."

    phone = sanitize_string(data.get("phone", ""), 20)
    if phone and not PHONE_RE.match(phone):
        return False, "El telefono proporcionado no es valido."

    if data["experience"] not in ALLOWED_EXPERIENCE:
        return False, "Nivel de experiencia con AWS no valido."
    if data["ai_experience"] not in ALLOWED_AI_EXPERIENCE:
        return False, "Nivel de experiencia con IA no valido."
    if data["city"] not in ALLOWED_CITIES:
        return False, "Ciudad no valida."

    # Employment status is optional; validate only if provided
    employment_status = data.get("employment_status")
    if employment_status and employment_status not in ALLOWED_EMPLOYMENT:
        return False, "Situacion laboral no valida."

    if not data.get("consent_data"):
        return False, "Debe aceptar el tratamiento de datos personales."

    return True, None


def already_registered(email, event_id):
    """Check if this email already registered for this event using GSI."""
    try:
        result = table.query(
            IndexName="email-index",
            KeyConditionExpression="email = :email",
            ExpressionAttributeValues={":email": email},
        )
        for item in result.get("Items", []):
            if item.get("event") == event_id:
                return True
        return False
    except ClientError as exc:
        # Fail-closed: if we can't check, reject to prevent duplicates
        print(f"[query-error] {exc}")
        return True


def build_confirmation_email(first_name, registration_id, registration_code, qr_url):
    """Build HTML and text confirmation email with QR code URL."""

    # HTML-escape user input to prevent injection
    safe_first_name = html.escape(first_name)

    subject = f"Registro confirmado - {EVENT_NAME}"

    text_body = f"""Hola {first_name},

Gracias por registrarte al {EVENT_NAME}!

Tu inscripcion ha sido confirmada exitosamente.

DETALLES DEL EVENTO
-------------------
Evento:    {EVENT_NAME}
Fecha:     {EVENT_DATE}
Hora:      {EVENT_TIME}
Sede:      {EVENT_VENUE}
Acceso:    Gratuito
Sitio:     {EVENT_URL}

CODIGO DE REGISTRO: {registration_code}
ID: {registration_id}

INSTRUCCIONES
-------------
- Presenta tu codigo QR en la entrada del evento para el check-in.
- Te enviaremos un recordatorio una semana antes del evento.
- Si necesitas cancelar tu inscripcion, escribe a privacy@awssecurityecuador.com.

PROTECCION DE DATOS
-------------------
Tus datos son tratados conforme a la Ley Organica de Proteccion de Datos
Personales del Ecuador (LOPDP). Para ejercer tus derechos de acceso,
rectificacion o eliminacion, escribe a privacy@awssecurityecuador.com.

— AWS User Group Security Ecuador
   https://www.awssecurityecuador.com
"""

    html_body = f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Registro confirmado</title>
</head>
<body style="margin:0;padding:0;background:#ffffff;font-family:Arial,Helvetica,sans-serif;color:#1a1a1a;">
<table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background:#ffffff;padding:40px 20px;">
  <tr>
    <td align="center">
      <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="600" style="max-width:600px;background:#ffffff;">

        <!-- Header -->
        <tr>
          <td style="padding:24px 32px;text-align:center;border-bottom:2px solid #0a73ff;">
            <h1 style="margin:0;color:#1a1a1a;font-size:22px;font-weight:bold;">{EVENT_NAME}</h1>
            <p style="margin:8px 0 0;color:#555;font-size:14px;">{EVENT_DATE} &middot; {EVENT_TIME}</p>
            <p style="margin:4px 0 0;color:#555;font-size:13px;">{EVENT_VENUE}</p>
          </td>
        </tr>

        <!-- Body -->
        <tr>
          <td style="padding:32px;">
            <p style="font-size:16px;color:#1a1a1a;margin:0 0 16px 0;">Hola <strong>{safe_first_name}</strong>,</p>
            <p style="font-size:15px;color:#555;line-height:1.6;margin:0 0 24px 0;">
              Tu registro ha sido confirmado. Esta es tu entrada digital para el evento.
            </p>

            <!-- Registration Code -->
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background:#f5f5f5;border:1px solid #e0e0e0;border-radius:8px;margin:24px 0;">
              <tr><td style="padding:20px;text-align:center;">
                <p style="font-size:12px;color:#0a73ff;margin:0 0 8px;letter-spacing:2px;font-weight:bold;">CODIGO DE REGISTRO</p>
                <p style="font-size:28px;color:#1a1a1a;font-weight:bold;letter-spacing:4px;margin:0;font-family:'Courier New',monospace;">{registration_code}</p>
              </td></tr>
            </table>

            <!-- QR Code -->
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin:24px 0;">
              <tr><td align="center" style="padding:20px;background:#f9f9f9;border:1px solid #e0e0e0;border-radius:8px;">
                <img src="{qr_url}" alt="QR Code de registro" width="180" height="180" style="display:block;width:180px;height:180px;" />
                <p style="font-size:12px;color:#777;margin:12px 0 0 0;">Presenta este QR en la entrada del evento</p>
              </td></tr>
            </table>

            <!-- Event details -->
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background:#f5f5f5;border:1px solid #e0e0e0;border-radius:8px;margin:24px 0;">
              <tr><td style="padding:20px;">
                <p style="font-size:13px;color:#0a73ff;margin:0 0 12px;font-weight:bold;">Detalles del evento</p>
                <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                  <tr><td style="padding:4px 0;font-size:13px;color:#777;width:70px;">Evento:</td><td style="padding:4px 0;font-size:14px;color:#1a1a1a;">{EVENT_NAME}</td></tr>
                  <tr><td style="padding:4px 0;font-size:13px;color:#777;">Fecha:</td><td style="padding:4px 0;font-size:14px;color:#1a1a1a;font-weight:bold;">{EVENT_DATE}</td></tr>
                  <tr><td style="padding:4px 0;font-size:13px;color:#777;">Hora:</td><td style="padding:4px 0;font-size:14px;color:#1a1a1a;">{EVENT_TIME}</td></tr>
                  <tr><td style="padding:4px 0;font-size:13px;color:#777;">Sede:</td><td style="padding:4px 0;font-size:14px;color:#1a1a1a;">{EVENT_VENUE}</td></tr>
                  <tr><td style="padding:4px 0;font-size:13px;color:#777;">Acceso:</td><td style="padding:4px 0;font-size:14px;color:#0a73ff;font-weight:bold;">GRATUITO</td></tr>
                </table>
              </td></tr>
            </table>

            <!-- Instructions -->
            <p style="font-size:14px;color:#555;font-weight:bold;margin:24px 0 8px;">Siguientes pasos:</p>
            <ul style="font-size:14px;color:#555;line-height:1.7;padding-left:20px;margin:0 0 24px 0;">
              <li>Guarda este correo como tu comprobante.</li>
              <li>Presenta tu QR en la entrada del evento para el check-in.</li>
              <li>Te enviaremos un recordatorio una semana antes.</li>
              <li>Si necesitas cancelar, escribe a <a href="mailto:privacy@awssecurityecuador.com" style="color:#0a73ff;">privacy@awssecurityecuador.com</a>.</li>
            </ul>

            <!-- LOPDP -->
            <p style="font-size:11px;color:#999;line-height:1.6;margin:24px 0 0 0;border-top:1px solid #e0e0e0;padding-top:16px;">
              Tus datos son tratados conforme a la LOPDP del Ecuador.
              Para ejercer tus derechos escribe a
              <a href="mailto:privacy@awssecurityecuador.com" style="color:#0a73ff;">privacy@awssecurityecuador.com</a>.
            </p>
          </td>
        </tr>

        <!-- Footer -->
        <tr>
          <td style="padding:20px 32px;text-align:center;border-top:1px solid #e0e0e0;">
            <p style="font-size:12px;color:#999;margin:0;">
              AWS User Group Security Ecuador
            </p>
            <p style="margin:8px 0 0;">
              <a href="https://www.awssecurityecuador.com" style="color:#0a73ff;font-size:12px;text-decoration:none;">awssecurityecuador.com</a>
              <span style="color:#ccc;margin:0 8px;">&middot;</span>
              <a href="https://www.meetup.com/aws-user-group-security-ecuador/" style="color:#0a73ff;font-size:12px;text-decoration:none;">meetup</a>
            </p>
          </td>
        </tr>

      </table>
    </td>
  </tr>
</table>
</body>
</html>"""

    return subject, text_body, html_body


def send_confirmation_email(email, first_name, registration_id, registration_code, qr_url):
    """Send confirmation email via SES with QR code URL. Returns True if sent, False otherwise."""
    subject, text_body, html_body = build_confirmation_email(first_name, registration_id, registration_code, qr_url)

    try:
        ses.send_email(
            FromEmailAddress=SES_FROM_ADDRESS,
            Destination={"ToAddresses": [email]},
            Content={
                "Simple": {
                    "Subject": {"Data": subject, "Charset": "UTF-8"},
                    "Body": {
                        "Text": {"Data": text_body, "Charset": "UTF-8"},
                        "Html": {"Data": html_body, "Charset": "UTF-8"},
                    },
                }
            },
        )
        print(f"[email-sent] to={mask_email(email)}")
        return True
    except ClientError as exc:
        print(f"[email-error] to={mask_email(email)} error={exc}")
        return False


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    if method == "OPTIONS":
        return response(200, {"ok": True})

    try:
        raw_body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            import base64 as b64mod
            raw_body = b64mod.b64decode(raw_body).decode("utf-8")
        data = json.loads(raw_body)
    except (json.JSONDecodeError, ValueError):
        return response(400, {"message": "Cuerpo de la solicitud invalido."})

    is_valid, error_msg = validate_payload(data)
    if not is_valid:
        return response(400, {"message": error_msg})

    # Verify Turnstile CAPTCHA
    turnstile_token = data.get("turnstile_token", "")
    source_ip = event.get("requestContext", {}).get("http", {}).get("sourceIp", "")
    if not verify_turnstile(turnstile_token, source_ip):
        return response(403, {"message": "Verificacion de seguridad fallida. Recarga la pagina e intenta nuevamente."})

    email = sanitize_string(data["email"], 120).lower()
    event_id = sanitize_string(data.get("event", "aws-gen-ai-security-day-2026"), 80)

    # Validate event_id format — only allow alphanumeric, hyphens, and underscores (SSRF prevention)
    if not re.match(r'^[a-zA-Z0-9_-]+$', event_id):
        event_id = "aws-gen-ai-security-day-2026"

    # Check capacity (200 max)
    current_count = get_registration_count(event_id)
    if current_count >= MAX_REGISTRATIONS:
        return response(409, {
            "message": "Lo sentimos, se han agotado los cupos disponibles para este evento."
        })

    if already_registered(email, event_id):
        # Generic response to prevent email enumeration
        return response(409, {
            "message": "No se pudo completar el registro. Si ya te registraste anteriormente, "
                       "revisa tu correo. Para soporte contacta a privacy@awssecurityecuador.com."
        })

    # Generate short registration code and QR
    registration_code = generate_registration_code()
    registration_id = str(uuid.uuid4())

    # QR contains the registration code for check-in validation
    qr_data = json.dumps({
        "code": registration_code,
        "id": registration_id,
        "event": event_id
    })

    # Upload QR to S3 and get presigned URL
    qr_url = upload_qr_to_s3(qr_data, registration_id)
    if not qr_url:
        # Fallback: generate base64 and use data URI (won't show in Gmail but works elsewhere)
        qr_base64 = generate_qr_code_base64(qr_data)
        qr_url = f"data:image/png;base64,{qr_base64}"

    now_iso = datetime.now(timezone.utc).isoformat()
    item = {
        "registration_id": registration_id,
        "registration_code": registration_code,
        "event": event_id,
        "email": email,
        "first_name": sanitize_freetext(data["first_name"], 80),
        "last_name": sanitize_freetext(data["last_name"], 80),
        "phone": sanitize_string(data.get("phone", ""), 20),
        "company": sanitize_freetext(data.get("company", ""), 120),
        "role": sanitize_freetext(data.get("role", ""), 120),
        "experience": data["experience"],
        "ai_experience": data["ai_experience"],
        "city": data["city"],
        "employment_status": sanitize_string(data.get("employment_status", ""), 30),
        "expectations": sanitize_freetext(data.get("expectations", ""), 500),
        "consent_data": bool(data.get("consent_data", False)),
        "consent_communications": bool(data.get("consent_communications", False)),
        "consent_image": bool(data.get("consent_image", False)),
        "consent_recruiters": bool(data.get("consent_recruiters", False)),
        "consent_sponsors": bool(data.get("consent_sponsors", False)),
        "registered_at": now_iso,
        "checked_in": False,
        "checked_in_at": None,
    }

    # Use TransactWriteItems to atomically prevent TOCTOU race condition:
    # 1. Write the registration item
    # 2. Write an email lock item (keyed by email+event) — fails if already exists
    # Both succeed or both fail, preventing concurrent duplicate registrations
    dynamodb_client = boto3.client("dynamodb")
    email_lock_id = f"EMAIL_LOCK#{email}#{event_id}"

    try:
        from boto3.dynamodb.types import TypeSerializer
        serializer = TypeSerializer()

        # Serialize the registration item for low-level client
        serialized_item = {k: serializer.serialize(v) for k, v in item.items() if v is not None}

        dynamodb_client.transact_write_items(
            TransactItems=[
                {
                    "Put": {
                        "TableName": TABLE_NAME,
                        "Item": serialized_item,
                        "ConditionExpression": "attribute_not_exists(registration_id)"
                    }
                },
                {
                    "Put": {
                        "TableName": TABLE_NAME,
                        "Item": {
                            "registration_id": {"S": email_lock_id},
                            "email": {"S": email},
                            "event": {"S": event_id},
                            "lock_type": {"S": "email_uniqueness"},
                            "created_at": {"S": now_iso},
                        },
                        "ConditionExpression": "attribute_not_exists(registration_id)"
                    }
                }
            ]
        )
        print(f"[register-ok] event={event_id} email={mask_email(email)} code={registration_code}")
    except ClientError as exc:
        error_code = exc.response["Error"]["Code"]
        if error_code == "TransactionCanceledException":
            # One of the conditions failed — duplicate email lock means race condition prevented
            return response(409, {
                "message": "No se pudo completar el registro. Si ya te registraste anteriormente, "
                           "revisa tu correo. Para soporte contacta a privacy@awssecurityecuador.com."
            })
        print(f"[register-error] {exc}")
        return response(500, {"message": "No se pudo procesar el registro. Intenta nuevamente."})

    # Send confirmation email with QR code
    email_sent = send_confirmation_email(email, item["first_name"], registration_id, registration_code, qr_url)

    return response(201, {
        "ok": True,
        "registration_id": registration_id,
        "registration_code": registration_code,
        "email_sent": email_sent,
        "message": "Registro confirmado.",
        "spots_remaining": MAX_REGISTRATIONS - current_count - 1,
    })
