"""
Certificate generator Lambda — AWS GenAI Security Day 2026.

Triggered manually from the admin dashboard (POST /api/certificates/generate).
For each checked-in registrant that does not yet have a certificate:
  1. Generates a PDF using reportlab (background image overlay).
  2. Uploads the PDF to the private certificates S3 bucket.
  3. Writes cert_id and cert_url back to the DynamoDB registration record.
  4. Sends a certificate email via SES.

GET /api/certificates/status returns progress counts (generated / total checked-in).
"""
import json
import os
import uuid
import html
import io
import datetime
import sys

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

# ── Config (from Lambda env vars) ────────────────────────────────────────────
TABLE_NAME       = os.environ["TABLE_NAME"]
CERT_BUCKET      = os.environ["CERT_BUCKET"]
CERT_CDN_DOMAIN  = os.environ["CERT_CDN_DOMAIN"]
SES_FROM_ADDRESS = os.environ.get("SES_FROM_ADDRESS", "noreply@awssecurityecuador.com")
EVENT_NAME       = os.environ.get("EVENT_NAME", "AWS GenAI Security Day 2026")
EVENT_DATE       = os.environ.get("EVENT_DATE", "Guayaquil, Ecuador  ·  18 de Julio de 2026")
EVENT_ID         = os.environ.get("EVENT_ID", "aws-gen-ai-security-day-2026")
ALLOWED_ORIGIN   = os.environ.get("ALLOWED_ORIGIN", "https://admin.awssecurityecuador.com")

# ── AWS clients ───────────────────────────────────────────────────────────────
dynamodb = boto3.resource("dynamodb")
table    = dynamodb.Table(TABLE_NAME)
s3       = boto3.client("s3", region_name="us-east-1")
ses      = boto3.client("sesv2", region_name="us-east-1")


# ── Helpers ───────────────────────────────────────────────────────────────────

def response(status_code, body, content_type="application/json"):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": content_type,
            "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
        },
        "body": body if isinstance(body, str) else json.dumps(body),
    }


def is_lock(item):
    return item.get("lock_type") is not None or str(item.get("registration_id", "")).startswith("EMAIL_LOCK#")


def query_checked_in(event_id):
    """Return all real, checked-in registrations (paginated, no lock items)."""
    items, kwargs = [], {
        "IndexName": "event-index",
        "KeyConditionExpression": Key("event").eq(event_id),
    }
    while True:
        result = table.query(**kwargs)
        for it in result.get("Items", []):
            if not is_lock(it) and it.get("checked_in"):
                items.append(it)
        last = result.get("LastEvaluatedKey")
        if not last:
            break
        kwargs["ExclusiveStartKey"] = last
    return items


def get_groups(event):
    """Extract Cognito groups from the verified JWT claims."""
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    raw = claims.get("cognito:groups", "")
    if isinstance(raw, list):
        return set(raw), claims.get("email", claims.get("sub", "unknown"))
    return set(raw.strip("[]").replace(",", " ").split()), claims.get("email", claims.get("sub", "unknown"))


# ── PDF generation (reportlab) ────────────────────────────────────────────────

# Certificate background is stored at the Lambda root alongside handler.py
_BG_IMAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "certificate.png")


def generate_certificate_pdf(attendee_name, cert_id):
    """
    Overlay dynamic text on the certificate background image and return
    the PDF as bytes.

    Layout (coordinates tuned against certificate.png — 2480×1748 px,
    A4 landscape at 300 DPI, mapped to reportlab's 841.89×595.28 pt canvas):

      H * 0.49  — Attendee name (Helvetica-Bold 34pt, #e6edf3, purple underline)
      H * 0.385 — Participation line (Helvetica 13pt)
      H * 0.33  — Event name (Helvetica-Bold 17pt, #00ff88)
      H * 0.27  — Date + location (Helvetica 12pt)
      H * 0.13  — Verification code block
    """
    from reportlab.pdfgen import canvas as rl_canvas
    from reportlab.lib.pagesizes import landscape, A4
    from reportlab.lib.colors import HexColor

    GREEN    = HexColor("#00ff88")
    TEXT     = HexColor("#e6edf3")
    TEXT_DIM = HexColor("#6e7681")
    PURPLE   = HexColor("#a371f7")

    W, H = landscape(A4)   # 841.89 × 595.28 pt

    buf = io.BytesIO()
    c = rl_canvas.Canvas(buf, pagesize=landscape(A4))
    c.setTitle(f"Certificado — {attendee_name} — {EVENT_NAME}")

    # Background image
    c.drawImage(_BG_IMAGE, 0, 0, width=W, height=H, preserveAspectRatio=False)

    # 1. Attendee name
    c.setFillColor(TEXT)
    c.setFont("Helvetica-Bold", 34)
    c.drawCentredString(W / 2, H * 0.49, attendee_name)
    name_w = c.stringWidth(attendee_name, "Helvetica-Bold", 34)
    c.setStrokeColor(PURPLE)
    c.setLineWidth(1.5)
    c.line(W/2 - name_w/2, H * 0.49 - 6, W/2 + name_w/2, H * 0.49 - 6)

    # 2. Participation text
    c.setFillColor(TEXT)
    c.setFont("Helvetica", 13)
    c.drawCentredString(W / 2, H * 0.385,
                        "Ha asistido y participado satisfactoriamente en el evento")

    # 3. Event name
    c.setFillColor(GREEN)
    c.setFont("Helvetica-Bold", 17)
    c.drawCentredString(W / 2, H * 0.33, EVENT_NAME)

    # 4. Date + location
    c.setFillColor(TEXT)
    c.setFont("Helvetica", 12)
    c.drawCentredString(W / 2, H * 0.27, EVENT_DATE)

    # 5. Verification code block
    cert_y = H * 0.13
    c.setFillColor(TEXT_DIM)
    c.setFont("Helvetica", 7)
    c.drawCentredString(W / 2, cert_y + 14, "CÓDIGO DE VERIFICACIÓN")

    c.setFillColor(GREEN)
    c.setFont("Helvetica-Bold", 10)
    c.drawCentredString(W / 2, cert_y, cert_id)

    issued = datetime.date.today().strftime("%d de %B de %Y")
    c.setFillColor(TEXT_DIM)
    c.setFont("Helvetica", 8)
    c.drawCentredString(W / 2, cert_y - 14, f"Emitido el {issued}")

    c.showPage()
    c.save()
    buf.seek(0)
    return buf.read()


# ── S3 upload ─────────────────────────────────────────────────────────────────

def upload_certificate(pdf_bytes, registration_id, cert_id):
    """Upload PDF to S3 and return the CloudFront URL."""
    key = f"certificates/{registration_id}/{cert_id}.pdf"
    try:
        s3.put_object(
            Bucket=CERT_BUCKET,
            Key=key,
            Body=pdf_bytes,
            ContentType="application/pdf",
            ContentDisposition="inline",
        )
        return f"https://{CERT_CDN_DOMAIN}/{key}"
    except ClientError as exc:
        print(f"[s3-error] registration_id={registration_id} error={exc}")
        return None


# ── DynamoDB update ───────────────────────────────────────────────────────────

def save_certificate_meta(registration_id, cert_id, cert_url):
    """Write cert_id and cert_url back to the registration record."""
    try:
        table.update_item(
            Key={"registration_id": registration_id},
            UpdateExpression="SET cert_id = :cid, cert_url = :curl, cert_issued_at = :ts",
            ExpressionAttributeValues={
                ":cid":  cert_id,
                ":curl": cert_url,
                ":ts":   datetime.datetime.now(datetime.timezone.utc).isoformat(),
            },
        )
    except ClientError as exc:
        print(f"[dynamo-error] registration_id={registration_id} error={exc}")


# ── SES email ─────────────────────────────────────────────────────────────────

def send_certificate_email(email, first_name, cert_url, cert_id):
    """Send the certificate email. Returns True on success."""
    safe_name = html.escape(first_name)
    subject = f"Tu certificado — {EVENT_NAME}"

    text_body = f"""Hola {first_name},

Felicitaciones por haber participado en el {EVENT_NAME}!

Puedes descargar tu certificado en el siguiente enlace:
{cert_url}

CÓDIGO DE VERIFICACIÓN: {cert_id}

Gracias por ser parte de la comunidad AWS User Group Security Ecuador.

— AWS User Group Security Ecuador
   https://www.awssecurityecuador.com
"""

    html_body = f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Tu certificado</title>
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
            <p style="margin:8px 0 0;color:#555;font-size:14px;">{EVENT_DATE}</p>
          </td>
        </tr>

        <!-- Body -->
        <tr>
          <td style="padding:32px;">
            <p style="font-size:16px;color:#1a1a1a;margin:0 0 16px 0;">
              Hola <strong>{safe_name}</strong>,
            </p>
            <p style="font-size:15px;color:#555;line-height:1.6;margin:0 0 24px 0;">
              Felicitaciones por haber participado en el <strong>{EVENT_NAME}</strong>.
              Tu certificado de participación está listo.
            </p>

            <!-- Download button -->
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin:24px 0;">
              <tr><td align="center">
                <a href="{cert_url}"
                   style="display:inline-block;padding:14px 32px;background:#0a73ff;color:#ffffff;
                          font-size:15px;font-weight:bold;text-decoration:none;border-radius:6px;">
                  Descargar certificado
                </a>
              </td></tr>
            </table>

            <!-- Verification code -->
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%"
                   style="background:#f5f5f5;border:1px solid #e0e0e0;border-radius:8px;margin:24px 0;">
              <tr><td style="padding:20px;text-align:center;">
                <p style="font-size:12px;color:#0a73ff;margin:0 0 8px;letter-spacing:2px;font-weight:bold;">
                  CÓDIGO DE VERIFICACIÓN
                </p>
                <p style="font-size:20px;color:#1a1a1a;font-weight:bold;letter-spacing:3px;margin:0;
                          font-family:'Courier New',monospace;">
                  {cert_id}
                </p>
              </td></tr>
            </table>

            <p style="font-size:13px;color:#777;line-height:1.6;margin:16px 0 0 0;">
              Si el botón no funciona, copia y pega este enlace en tu navegador:<br/>
              <a href="{cert_url}" style="color:#0a73ff;word-break:break-all;">{cert_url}</a>
            </p>

            <!-- LOPDP -->
            <p style="font-size:11px;color:#999;line-height:1.6;margin:24px 0 0 0;
                      border-top:1px solid #e0e0e0;padding-top:16px;">
              Tus datos son tratados conforme a la LOPDP del Ecuador.
              Para ejercer tus derechos escribe a
              <a href="mailto:privacy@awssecurityecuador.com" style="color:#0a73ff;">
                privacy@awssecurityecuador.com
              </a>.
            </p>
          </td>
        </tr>

        <!-- Footer -->
        <tr>
          <td style="padding:20px 32px;text-align:center;border-top:1px solid #e0e0e0;">
            <p style="font-size:12px;color:#999;margin:0;">AWS User Group Security Ecuador</p>
            <p style="margin:8px 0 0;">
              <a href="https://www.awssecurityecuador.com"
                 style="color:#0a73ff;font-size:12px;text-decoration:none;">
                awssecurityecuador.com
              </a>
            </p>
          </td>
        </tr>

      </table>
    </td>
  </tr>
</table>
</body>
</html>"""

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
        return True
    except ClientError as exc:
        print(f"[ses-error] email error={exc}")
        return False


# ── Route handlers ────────────────────────────────────────────────────────────

def handle_status(event_id):
    """GET /api/certificates/status — returns generation progress."""
    items = query_checked_in(event_id)
    total_checked_in = len(items)
    already_generated = sum(1 for i in items if i.get("cert_id"))
    pending = total_checked_in - already_generated
    return response(200, {
        "total_checked_in": total_checked_in,
        "already_generated": already_generated,
        "pending": pending,
    })


def handle_generate(event_id, body, dry_run=False):
    """
    POST /api/certificates/generate

    Body (optional):
      { "registration_ids": ["uuid1", "uuid2"] }  → generate only these
      {}                                           → generate all pending

    dry_run=True skips S3 upload + email (for testing).
    """
    target_ids = None
    if body:
        try:
            parsed = json.loads(body)
            target_ids = parsed.get("registration_ids")  # None = all pending
        except (json.JSONDecodeError, ValueError):
            return response(400, {"message": "Cuerpo inválido."})

    items = query_checked_in(event_id)

    # Filter to target set if provided
    if target_ids:
        items = [i for i in items if i.get("registration_id") in set(target_ids)]

    # Skip already-generated unless explicitly targeted
    if not target_ids:
        items = [i for i in items if not i.get("cert_id")]

    if not items:
        return response(200, {
            "ok": True,
            "generated": 0,
            "failed": 0,
            "message": "No hay certificados pendientes.",
        })

    generated, failed = 0, 0
    errors = []

    for item in items:
        registration_id = item["registration_id"]
        first_name = item.get("first_name", "")
        last_name  = item.get("last_name", "")
        email      = item.get("email", "")
        full_name  = f"{first_name} {last_name}".strip()
        cert_id    = str(uuid.uuid4()).upper()[:16]

        try:
            pdf_bytes = generate_certificate_pdf(full_name, cert_id)
        except Exception as exc:
            print(f"[pdf-error] registration_id={registration_id} error={exc}")
            failed += 1
            errors.append(registration_id)
            continue

        if dry_run:
            generated += 1
            continue

        cert_url = upload_certificate(pdf_bytes, registration_id, cert_id)
        if not cert_url:
            failed += 1
            errors.append(registration_id)
            continue

        save_certificate_meta(registration_id, cert_id, cert_url)
        send_certificate_email(email, first_name, cert_url, cert_id)
        generated += 1
        print(f"[cert-ok] registration_id={registration_id} cert_id={cert_id}")

    return response(200, {
        "ok": True,
        "generated": generated,
        "failed": failed,
        "errors": errors,
        "message": f"Certificados generados: {generated}. Fallidos: {failed}.",
    })


# ── Lambda entry point ────────────────────────────────────────────────────────

def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path   = event.get("requestContext", {}).get("http", {}).get("path", "")

    if method == "OPTIONS":
        return response(200, {"ok": True})

    # Auth check — admins only
    groups, who = get_groups(event)
    if "admins" not in groups:
        return response(403, {"message": "Requiere rol de administrador."})

    qs       = event.get("queryStringParameters") or {}
    event_id = qs.get("event", EVENT_ID)

    if path == "/api/certificates/status" and method == "GET":
        return handle_status(event_id)

    if path == "/api/certificates/generate" and method == "POST":
        body = event.get("body") or ""
        return handle_generate(event_id, body)

    return response(404, {"message": "Ruta no encontrada."})
