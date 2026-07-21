"""
Check-in handler for AWS GenAI Security Day 2026.
Validates QR codes scanned at the event entrance and marks attendees as checked-in.
"""
import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# Config
TABLE_NAME = os.environ["TABLE_NAME"]
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "")
CHECKIN_SECRET_SSM_ARN = os.environ.get("CHECKIN_SECRET_SSM_ARN", "")

# AWS clients
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
ssm = boto3.client("ssm")

# Cache the secret in memory (Lambda container reuse)
_cached_secret = None


def get_checkin_secret():
    """Retrieve the check-in secret from SSM Parameter Store (cached per container)."""
    global _cached_secret
    if _cached_secret is not None:
        return _cached_secret
    if not CHECKIN_SECRET_SSM_ARN:
        return ""
    try:
        result = ssm.get_parameter(Name=CHECKIN_SECRET_SSM_ARN, WithDecryption=True)
        _cached_secret = result["Parameter"]["Value"]
        return _cached_secret
    except ClientError as exc:
        print(f"[ssm-error] Failed to retrieve checkin secret: {exc}")
        return ""

# AWS clients
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, X-Checkin-Secret",
        },
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path = event.get("requestContext", {}).get("http", {}).get("path", "")

    if method == "OPTIONS":
        return response(200, {"ok": True})

    # Validate staff secret (read from SSM at runtime)
    headers = event.get("headers", {})
    provided_secret = headers.get("x-checkin-secret", "")
    checkin_secret = get_checkin_secret()
    if not checkin_secret or provided_secret != checkin_secret:
        return response(401, {"message": "No autorizado. Credenciales de staff invalidas."})

    # Route: GET /api/attendees — list all registrations
    if path == "/api/attendees" and method == "GET":
        return handle_list_attendees(event)

    # Route: POST /api/checkin — check-in a single attendee
    return handle_checkin(event)


def handle_list_attendees(event):
    """List all attendees for the event with check-in status."""
    try:
        # Query by event using GSI
        event_id = event.get("queryStringParameters", {}).get("event", "aws-gen-ai-security-day-2026") if event.get("queryStringParameters") else "aws-gen-ai-security-day-2026"

        result = table.query(
            IndexName="event-index",
            KeyConditionExpression="event = :eid",
            ExpressionAttributeValues={":eid": event_id},
        )
        items = result.get("Items", [])

        attendees = []
        checked_in_count = 0
        for item in items:
            # Skip email lock items (used for duplicate prevention)
            if item.get("registration_id", "").startswith("EMAIL_LOCK#"):
                continue
            is_checked = bool(item.get("checked_in"))
            if is_checked:
                checked_in_count += 1
            attendees.append({
                "name": f"{item.get('first_name', '')} {item.get('last_name', '')}",
                "email": item.get("email", ""),
                "company": item.get("company", ""),
                "code": item.get("registration_code", ""),
                "checked_in": is_checked,
                "checked_in_at": item.get("checked_in_at", None),
                "registered_at": item.get("registered_at", ""),
            })

        # Sort: checked-in first, then by registration date
        attendees.sort(key=lambda x: (not x["checked_in"], x["registered_at"]))

        return response(200, {
            "total": len(attendees),
            "checked_in": checked_in_count,
            "not_checked_in": len(attendees) - checked_in_count,
            "attendees": attendees,
        })

    except ClientError as exc:
        print(f"[attendees-error] {exc}")
        return response(500, {"message": "Error al obtener la lista de asistentes."})


def handle_checkin(event):
    try:
        raw_body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            import base64
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        data = json.loads(raw_body)
    except (json.JSONDecodeError, ValueError):
        return response(400, {"message": "Cuerpo de la solicitud invalido."})

    # Extract QR data
    registration_code = data.get("code", "").strip().upper()
    registration_id = data.get("id", "").strip()

    if not registration_code and not registration_id:
        return response(400, {"message": "Debe proporcionar un codigo de registro o ID."})

    # Look up registration
    try:
        if registration_id:
            # Direct lookup by ID
            result = table.get_item(Key={"registration_id": registration_id})
            item = result.get("Item")
        else:
            # Scan by registration_code (less efficient but works for code-only lookups)
            result = table.scan(
                FilterExpression="registration_code = :code",
                ExpressionAttributeValues={":code": registration_code},
                Limit=1
            )
            items = result.get("Items", [])
            item = items[0] if items else None

    except ClientError as exc:
        print(f"[checkin-error] lookup failed: {exc}")
        return response(500, {"message": "Error al buscar el registro."})

    if not item:
        return response(404, {
            "valid": False,
            "message": "Registro no encontrado. Verifica el codigo QR."
        })

    # Validate code matches if both provided
    if registration_code and item.get("registration_code") != registration_code:
        return response(404, {
            "valid": False,
            "message": "Codigo de registro no coincide."
        })

    # Check if already checked in
    if item.get("checked_in"):
        return response(200, {
            "valid": True,
            "already_checked_in": True,
            "message": f"Ya registrado previamente a las {item.get('checked_in_at', 'N/A')}",
            "attendee": {
                "name": f"{item.get('first_name', '')} {item.get('last_name', '')}",
                "email": item.get("email", ""),
                "company": item.get("company", ""),
                "code": item.get("registration_code", ""),
            }
        })

    # Mark as checked in
    now_iso = datetime.now(timezone.utc).isoformat()
    try:
        table.update_item(
            Key={"registration_id": item["registration_id"]},
            UpdateExpression="SET checked_in = :ci, checked_in_at = :at",
            ExpressionAttributeValues={
                ":ci": True,
                ":at": now_iso,
            }
        )
    except ClientError as exc:
        print(f"[checkin-error] update failed: {exc}")
        return response(500, {"message": "Error al registrar el check-in."})

    print(f"[checkin-ok] code={item.get('registration_code')} id={item['registration_id']}")

    return response(200, {
        "valid": True,
        "already_checked_in": False,
        "message": "Check-in exitoso!",
        "attendee": {
            "name": f"{item.get('first_name', '')} {item.get('last_name', '')}",
            "email": item.get("email", ""),
            "company": item.get("company", ""),
            "code": item.get("registration_code", ""),
        }
    })
