"""
Admin dashboard API for AWS GenAI Security Day.
Authenticated via Cognito (API Gateway JWT authorizer). Role from cognito:groups.

Roles:
  - admins:     full access (list, metrics, export-all, pool, checkin)
  - recruiters: consented candidate pool only (read + export), field-minimized

Reads the existing registrations table (read-only) and writes an export audit
record for LOPDP traceability.
"""
import json
import os
import csv
import io
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

TABLE_NAME = os.environ["TABLE_NAME"]
AUDIT_TABLE_NAME = os.environ["AUDIT_TABLE_NAME"]
BUDGET_TABLE_NAME = os.environ.get("BUDGET_TABLE_NAME", "")
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "")
DEFAULT_EVENT = os.environ.get("EVENT_ID", "aws-gen-ai-security-day-2026")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
audit_table = dynamodb.Table(AUDIT_TABLE_NAME)

# Fields a recruiter may see (subset covered by recruiter consent).
RECRUITER_FIELDS = [
    "first_name", "last_name", "email", "employment_status",
    "experience", "ai_experience", "company", "role",
]
# Fields shared with sponsors (sponsor-pool export). Contact data only.
SPONSOR_FIELDS = [
    "first_name", "last_name", "email", "phone", "company", "role", "city",
]
# Fields an admin may see in listings/exports.
ADMIN_FIELDS = RECRUITER_FIELDS + [
    "phone", "city", "registered_at", "checked_in", "checked_in_at",
    "registration_code", "consent_recruiters", "consent_sponsors",
]


def response(status_code, body, content_type="application/json", extra_headers=None):
    headers = {
        "Content-Type": content_type,
        "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
    }
    if extra_headers:
        headers.update(extra_headers)
    return {
        "statusCode": status_code,
        "headers": headers,
        "body": body if isinstance(body, str) else json.dumps(body),
    }


def get_groups(event):
    """Extract Cognito groups from the verified JWT claims."""
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    raw = claims.get("cognito:groups", "")
    # Claim may arrive as "[admins recruiters]" or "admins,recruiters" or list
    if isinstance(raw, list):
        groups = raw
    else:
        groups = raw.strip("[]").replace(",", " ").split()
    return set(groups), claims.get("email", claims.get("sub", "unknown"))


def is_lock(item):
    return item.get("lock_type") is not None or str(item.get("registration_id", "")).startswith("EMAIL_LOCK#")


def query_registrations(event_id, consent_field=None):
    """Query all real registrations for an event (paginated), excluding locks.

    If consent_field is provided (e.g. 'consent_recruiters' or
    'consent_sponsors'), only records where that flag is truthy are returned.
    """
    items = []
    kwargs = {
        "IndexName": "event-index",
        "KeyConditionExpression": Key("event").eq(event_id),
    }
    while True:
        result = table.query(**kwargs)
        for it in result.get("Items", []):
            if is_lock(it):
                continue
            if consent_field and not it.get(consent_field):
                continue
            items.append(it)
        last = result.get("LastEvaluatedKey")
        if not last:
            break
        kwargs["ExclusiveStartKey"] = last
    return items


def project(item, fields):
    return {k: item.get(k) for k in fields}


def write_audit(exported_by, role, export_type, filt, count):
    try:
        audit_table.put_item(Item={
            "export_id": str(uuid.uuid4()),
            "exported_by": exported_by,
            "exported_at": datetime.now(timezone.utc).isoformat(),
            "export_type": export_type,
            "filter": json.dumps(filt or {}),
            "record_count": count,
            "role": role,
        })
    except ClientError as exc:
        print(f"[audit-error] {exc}")


def to_csv(rows, fields):
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    for r in rows:
        writer.writerow({k: ("" if r.get(k) is None else r.get(k)) for k in fields})
    return buf.getvalue()


def _normalize_role(raw):
    """Map free-text role to a canonical category for analytics."""
    if not raw:
        return "No especificado"
    r = raw.lower()
    if any(k in r for k in ["developer", "desarrollador", "dev ", "dev$", "backend", "frontend", "fullstack", "full stack", "full-stack", "jefe de desarrollo", "semi senior", "senior "]):
        return "Developer"
    if any(k in r for k in ["student", "estudiante", "academic", "académico", "universitario", "pasante", "intern"]):
        return "Estudiante / Académico"
    if any(k in r for k in ["ceo", "director", "gerente", "founder", "co-founder", "cofundador", "co fundador", "cto", "coo", "vp ", "vice"]):
        return "CEO / Director / C-Level"
    if any(k in r for k in ["data scientist", "cientifico", "científico de datos", "ml ", "machine learning"]):
        return "Data Scientist / ML"
    if any(k in r for k in ["software engineer", "swe", "ingeniero de software", "software dev"]):
        return "Software Engineer"
    if any(k in r for k in ["analyst", "analista", "business analyst", "ba "]):
        return "Analista"
    if any(k in r for k in ["tech lead", "líder técnico", "lider tecnico", "technical lead"]):
        return "Tech Lead"
    if any(k in r for k in ["project manager", "pm ", "product manager", "scrum master", "agile"]):
        return "Project / Product Manager"
    if any(k in r for k in ["architect", "arquitecto", "solutions architect", "arquitecta"]):
        return "Arquitecto"
    if any(k in r for k in ["soporte", "support", "helpdesk", "it support", "técnico ti", "tecnico ti", "asistente ti", "asistente de sistemas", "encargado ti", "especialista ti", "especialista de ti", "administrador del centro", "administrador ti", "mantenimiento"]):
        return "Soporte Técnico / TI"
    if any(k in r for k in ["ux", "ui ", "diseñador", "diseniador", "designer", "design"]):
        return "UX / UI / Diseño"
    if any(k in r for k in ["cloud engineer", "cloud ingeniero", "devops", "sre ", "site reliability", "platform"]):
        return "Cloud Engineer / DevOps"
    if any(k in r for k in ["data engineer", "ingeniero de datos", "etl", "pipeline"]):
        return "Data Engineer"
    if any(k in r for k in ["security", "seguridad", "ciso", "pentest", "ethical hack"]):
        return "Security Engineer"
    if any(k in r for k in ["audit", "auditor", "dpd", "riesgos", "compliance", "continuidad"]):
        return "Auditor / Compliance / Riesgos"
    if any(k in r for k in ["investigador", "researcher", "investigacion"]):
        return "Investigador"
    if any(k in r for k in ["network", "redes", "networking", "infraestructura"]):
        return "Infraestructura / Redes"
    if any(k in r for k in ["consultant", "consultor", "advisor", "asesor"]):
        return "Consultor / Asesor"
    if any(k in r for k in ["teacher", "profesor", "docente", "instructor"]):
        return "Docente / Instructor"
    if raw in ("n/a", "ninguno", "none", "na", "miembro", "staff", "asistente", "oficial"):
        return "No especificado"
    return "Otro"


def apply_filters(items, qs):
    """Optional employment_status / city filters (admin scope only)."""
    emp = (qs or {}).get("employment_status")
    city = (qs or {}).get("city")
    out = items
    if emp:
        out = [i for i in out if i.get("employment_status") == emp]
    if city:
        out = [i for i in out if i.get("city") == city]
    return out


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path = event.get("requestContext", {}).get("http", {}).get("path", "")
    if method == "OPTIONS":
        return response(200, {"ok": True})

    groups, who = get_groups(event)
    is_admin = "admins" in groups
    is_recruiter = "recruiters" in groups
    if not (is_admin or is_recruiter):
        return response(403, {"message": "No autorizado."})

    qs = event.get("queryStringParameters") or {}
    event_id = qs.get("event", DEFAULT_EVENT)

    # ---- Recruiter-accessible: consented pool ----
    if path == "/api/pool" and method == "GET":
        items = query_registrations(event_id, consent_field="consent_recruiters")
        rows = [project(i, RECRUITER_FIELDS) for i in items]
        return response(200, {"total": len(rows), "attendees": rows})

    if path == "/api/pool/export" and method == "GET":
        items = query_registrations(event_id, consent_field="consent_recruiters")
        rows = [project(i, RECRUITER_FIELDS) for i in items]
        csv_data = to_csv(rows, RECRUITER_FIELDS)
        write_audit(who, "recruiters" if is_recruiter and not is_admin else "admins",
                    "pool", {}, len(rows))
        return response(200, csv_data, content_type="text/csv",
                        extra_headers={"Content-Disposition": "attachment; filename=candidate-pool.csv"})

    # ---- Admin-only beyond this point ----
    if not is_admin:
        return response(403, {"message": "Requiere rol de administrador."})

    # Sponsor base export — only records that consented to sponsor sharing
    if path == "/api/sponsors/export" and method == "GET":
        items = query_registrations(event_id, consent_field="consent_sponsors")
        rows = [project(i, SPONSOR_FIELDS) for i in items]
        csv_data = to_csv(rows, SPONSOR_FIELDS)
        write_audit(who, "admins", "sponsors", {}, len(rows))
        return response(200, csv_data, content_type="text/csv",
                        extra_headers={"Content-Disposition": "attachment; filename=sponsors-base.csv"})

    if path == "/api/registrations" and method == "GET":
        items = apply_filters(query_registrations(event_id), qs)
        search = (qs.get("q") or "").lower().strip()
        if search:
            items = [
                i for i in items
                if search in f"{i.get('first_name','')} {i.get('last_name','')}".lower()
                or search in str(i.get("email", "")).lower()
            ]
        rows = [project(i, ADMIN_FIELDS) for i in items]
        rows.sort(key=lambda r: r.get("registered_at") or "")
        return response(200, {"total": len(rows), "attendees": rows})

    if path == "/api/metrics" and method == "GET":
        items = query_registrations(event_id)
        total = len(items)
        checked_in = sum(1 for i in items if i.get("checked_in"))
        pool = sum(1 for i in items if i.get("consent_recruiters"))
        sponsor_pool = sum(1 for i in items if i.get("consent_sponsors"))

        # Personal domains for email-type heuristic
        personal_domains = {
            "gmail.com", "hotmail.com", "outlook.com", "yahoo.com", "icloud.com",
            "live.com", "msn.com", "protonmail.com", "me.com", "mac.com",
            "yahoo.es", "hotmail.es", "gmx.com"
        }

        by_city, by_exp, by_emp = {}, {}, {}
        by_role_raw = {}
        email_personal, email_corporate = 0, 0
        has_company, no_company = 0, 0

        for i in items:
            by_city[i.get("city", "?")] = by_city.get(i.get("city", "?"), 0) + 1
            by_exp[i.get("experience", "?")] = by_exp.get(i.get("experience", "?"), 0) + 1
            emp = i.get("employment_status") or "not_specified"
            by_emp[emp] = by_emp.get(emp, 0) + 1
            email = str(i.get("email", "")).lower()
            domain = email.split("@")[-1] if "@" in email else ""
            if domain in personal_domains:
                email_personal += 1
            else:
                email_corporate += 1
            if i.get("company") and str(i.get("company", "")).strip():
                has_company += 1
            else:
                no_company += 1
            # Normalize role
            raw_role = str(i.get("role", "")).strip().lower()
            normalized = _normalize_role(raw_role)
            by_role_raw[normalized] = by_role_raw.get(normalized, 0) + 1

        return response(200, {
            "total": total,
            "checked_in": checked_in,
            "not_checked_in": total - checked_in,
            "capacity": 400,
            "remaining": max(0, 400 - total),
            "recruiter_pool": pool,
            "sponsor_pool": sponsor_pool,
            "by_city": by_city,
            "by_experience": by_exp,
            "by_employment": by_emp,
            "email_personal": email_personal,
            "email_corporate": email_corporate,
            "has_company": has_company,
            "no_company": no_company,
            "by_role": dict(sorted(by_role_raw.items(), key=lambda x: x[1], reverse=True)),
        })

    if path == "/api/export" and method == "GET":
        items = apply_filters(query_registrations(event_id), qs)
        rows = [project(i, ADMIN_FIELDS) for i in items]
        csv_data = to_csv(rows, ADMIN_FIELDS)
        export_type = "filtered" if (qs.get("employment_status") or qs.get("city")) else "all"
        write_audit(who, "admins", export_type,
                    {"employment_status": qs.get("employment_status"), "city": qs.get("city")},
                    len(rows))
        return response(200, csv_data, content_type="text/csv",
                        extra_headers={"Content-Disposition": "attachment; filename=registrations.csv"})

    if path == "/api/checkin" and method == "POST":
        try:
            data = json.loads(event.get("body") or "{}")
        except (json.JSONDecodeError, ValueError):
            return response(400, {"message": "Cuerpo invalido."})
        code = (data.get("code") or "").strip().upper()
        if not code:
            return response(400, {"message": "Codigo requerido."})
        matches = [i for i in query_registrations(event_id) if i.get("registration_code") == code]
        if not matches:
            return response(404, {"valid": False, "message": "Registro no encontrado."})
        item = matches[0]
        if item.get("checked_in"):
            return response(200, {"valid": True, "already_checked_in": True,
                                  "message": f"Ya registrado a las {item.get('checked_in_at', 'N/A')}",
                                  "attendee": project(item, ["first_name", "last_name", "email", "company"])})
        now_iso = datetime.now(timezone.utc).isoformat()
        try:
            table.update_item(
                Key={"registration_id": item["registration_id"]},
                UpdateExpression="SET checked_in = :c, checked_in_at = :a",
                ExpressionAttributeValues={":c": True, ":a": now_iso},
            )
        except ClientError as exc:
            print(f"[checkin-error] {exc}")
            return response(500, {"message": "Error al registrar check-in."})
        return response(200, {"valid": True, "already_checked_in": False, "message": "Check-in exitoso!",
                              "attendee": project(item, ["first_name", "last_name", "email", "company"])})

    # ---- Budget CRUD ----
    if path.startswith("/api/budget") and BUDGET_TABLE_NAME:
        btable = dynamodb.Table(BUDGET_TABLE_NAME)

        if method == "GET":
            result = btable.scan()
            items = result.get("Items", [])
            items.sort(key=lambda x: x.get("created_at", ""))
            income = [i for i in items if i.get("type") == "income"]
            expense = [i for i in items if i.get("type") == "expense"]
            total_in = sum(float(i.get("amount", 0)) for i in income)
            total_out = sum(float(i.get("amount", 0)) for i in expense)
            return response(200, {
                "items": items,
                "total_income": round(total_in, 2),
                "total_expense": round(total_out, 2),
                "balance": round(total_in - total_out, 2),
            })

        if method == "POST":
            try:
                data = json.loads(event.get("body") or "{}")
            except (json.JSONDecodeError, ValueError):
                return response(400, {"message": "Cuerpo inválido."})
            required = ["type", "description", "amount", "status"]
            if not all(data.get(f) for f in required):
                return response(400, {"message": "type, description, amount y status son requeridos."})
            if data["type"] not in ("income", "expense"):
                return response(400, {"message": "type debe ser 'income' o 'expense'."})
            now = datetime.now(timezone.utc).isoformat()
            item_id = str(uuid.uuid4())
            item = {
                "item_id": item_id,
                "type": data["type"],
                "category": str(data.get("category", "other"))[:50],
                "description": str(data.get("description", ""))[:200],
                "amount": str(round(float(data["amount"]), 2)),
                "status": str(data.get("status", "estimated"))[:30],
                "sponsor_name": str(data.get("sponsor_name", ""))[:100],
                "notes": str(data.get("notes", ""))[:500],
                "created_at": now,
                "updated_at": now,
            }
            btable.put_item(Item=item)
            return response(201, {"ok": True, "item_id": item_id})

        if method == "PUT":
            try:
                data = json.loads(event.get("body") or "{}")
            except (json.JSONDecodeError, ValueError):
                return response(400, {"message": "Cuerpo inválido."})
            item_id = qs.get("id") or data.get("item_id")
            if not item_id:
                return response(400, {"message": "id requerido."})
            updatable = ["description", "amount", "status", "category", "sponsor_name", "notes"]
            expr_parts, expr_vals = [], {}
            for f in updatable:
                if f in data:
                    val = str(round(float(data[f]), 2)) if f == "amount" else str(data[f])
                    expr_parts.append(f"{f} = :{f}")
                    expr_vals[f":{f}"] = val
            if not expr_parts:
                return response(400, {"message": "Sin campos a actualizar."})
            expr_parts.append("updated_at = :ua")
            expr_vals[":ua"] = datetime.now(timezone.utc).isoformat()
            try:
                btable.update_item(
                    Key={"item_id": item_id},
                    UpdateExpression="SET " + ", ".join(expr_parts),
                    ExpressionAttributeValues=expr_vals,
                    ConditionExpression="attribute_exists(item_id)",
                )
            except ClientError as exc:
                if "ConditionalCheckFailed" in str(exc):
                    return response(404, {"message": "Item no encontrado."})
                raise
            return response(200, {"ok": True})

        if method == "DELETE":
            item_id = qs.get("id")
            if not item_id:
                return response(400, {"message": "id requerido."})
            try:
                btable.delete_item(
                    Key={"item_id": item_id},
                    ConditionExpression="attribute_exists(item_id)",
                )
            except ClientError as exc:
                if "ConditionalCheckFailed" in str(exc):
                    return response(404, {"message": "Item no encontrado."})
                raise
            return response(200, {"ok": True})

    return response(404, {"message": "Ruta no encontrada."})
