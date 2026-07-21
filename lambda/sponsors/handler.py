"""
Sponsor inquiry handler — sends notification email to info@awssecurityecuador.com
"""
import json
import os
import re
import html
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "")
SES_FROM_ADDRESS = os.environ.get("SES_FROM_ADDRESS", "noreply@awssecurityecuador.com")
NOTIFY_EMAIL = os.environ.get("NOTIFY_EMAIL", "info@awssecurityecuador.com")

ses = boto3.client("sesv2", region_name="us-east-1")
EMAIL_RE = re.compile(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")

TIER_LABELS = {
    "oro": "🥇 Oro — $1,000",
    "plata": "🥈 Plata — $500",
    "bronce": "🥉 Bronce — $300",
    "supporter": "⭐ Supporter — $100",
    "otra": "💬 Otra manera",
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


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    if method == "OPTIONS":
        return response(200, {"ok": True})

    try:
        raw_body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            import base64
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        data = json.loads(raw_body)
    except (json.JSONDecodeError, ValueError):
        return response(400, {"message": "Solicitud invalida."})

    # Validate required fields
    nombre = data.get("nombre", "").strip()[:80]
    apellido = data.get("apellido", "").strip()[:80]
    empresa = data.get("empresa", "").strip()[:120]
    email = data.get("email", "").strip().lower()[:120]
    telefono = data.get("telefono", "").strip()[:20]
    tier = data.get("tier", "").strip()[:20]
    mensaje = data.get("mensaje", "").strip()[:500]

    if not all([nombre, apellido, empresa, email, tier]):
        return response(400, {"message": "Todos los campos obligatorios deben estar completos."})

    if not EMAIL_RE.match(email):
        return response(400, {"message": "Email no valido."})

    if tier not in TIER_LABELS:
        return response(400, {"message": "Tier no valido."})

    # Build notification email
    tier_label = TIER_LABELS[tier]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    subject = f"🤝 Nueva solicitud de sponsor: {empresa} ({tier_label})"

    text_body = f"""Nueva solicitud de sponsorship recibida:

Nombre: {nombre} {apellido}
Empresa: {empresa}
Email: {email}
Teléfono: {telefono or 'No proporcionado'}
Tier: {tier_label}
Mensaje: {mensaje or 'Sin mensaje adicional'}

Fecha: {now}
"""

    safe_nombre = html.escape(nombre)
    safe_apellido = html.escape(apellido)
    safe_empresa = html.escape(empresa)
    safe_email = html.escape(email)
    safe_mensaje = html.escape(mensaje) if mensaje else "<em>Sin mensaje adicional</em>"

    html_body = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;background:#f5f5f5;padding:20px;">
<div style="max-width:600px;margin:0 auto;background:white;border-radius:8px;overflow:hidden;box-shadow:0 2px 10px rgba(0,0,0,0.1);">
  <div style="background:linear-gradient(135deg,#0a73ff,#00ff88);padding:24px;text-align:center;">
    <h1 style="margin:0;color:white;font-size:20px;">🤝 Nueva Solicitud de Sponsor</h1>
    <p style="margin:8px 0 0;color:rgba(255,255,255,0.8);font-size:14px;">AWS GenAI Security Day 2026</p>
  </div>
  <div style="padding:24px;">
    <table style="width:100%;border-collapse:collapse;">
      <tr><td style="padding:8px 0;color:#666;font-size:13px;width:120px;">Nombre:</td><td style="padding:8px 0;font-weight:bold;">{safe_nombre} {safe_apellido}</td></tr>
      <tr><td style="padding:8px 0;color:#666;font-size:13px;">Empresa:</td><td style="padding:8px 0;font-weight:bold;">{safe_empresa}</td></tr>
      <tr><td style="padding:8px 0;color:#666;font-size:13px;">Email:</td><td style="padding:8px 0;"><a href="mailto:{safe_email}">{safe_email}</a></td></tr>
      <tr><td style="padding:8px 0;color:#666;font-size:13px;">Teléfono:</td><td style="padding:8px 0;">{html.escape(telefono) if telefono else 'No proporcionado'}</td></tr>
      <tr><td style="padding:8px 0;color:#666;font-size:13px;">Tier:</td><td style="padding:8px 0;font-weight:bold;font-size:16px;">{tier_label}</td></tr>
      <tr><td style="padding:8px 0;color:#666;font-size:13px;vertical-align:top;">Mensaje:</td><td style="padding:8px 0;">{safe_mensaje}</td></tr>
    </table>
  </div>
  <div style="background:#f9f9f9;padding:16px;text-align:center;font-size:12px;color:#999;">
    Recibido: {now} · sponsors.awssecurityecuador.com
  </div>
</div>
</body></html>"""

    # Send email
    try:
        ses.send_email(
            FromEmailAddress=SES_FROM_ADDRESS,
            Destination={"ToAddresses": [NOTIFY_EMAIL]},
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
        print(f"[sponsor-ok] empresa={empresa} tier={tier}")
    except ClientError as exc:
        print(f"[sponsor-error] {exc}")
        return response(500, {"message": "Error al enviar la solicitud. Intenta nuevamente."})

    return response(200, {"ok": True, "message": "Solicitud enviada correctamente."})
