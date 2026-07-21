# Design Document

## Overview

The Admin Dashboard is an authenticated, organizer-facing web application at
`admin.awssecurityecuador.com` for viewing event registrations, monitoring
check-in, computing metrics, and exporting consent-aware attendee lists. It
follows the project's established serverless pattern (private S3 + CloudFront
with OAC, API Gateway HTTP API, Lambda, DynamoDB) and adds Amazon Cognito for
user authentication and role-based authorization.

It reads the existing `awssecurity-ecuador-registrations` DynamoDB table (no
schema migration required) and introduces a new audit log for exports.

### Goals

- Secure, user-based access (Cognito) replacing the shared check-in secret.
- Role separation: `admins` (full access) vs `recruiters` (consented pool only).
- LOPDP-compliant export with consent filtering and audit logging.
- Consistent IaC + CI/CD with the rest of the project.

### Non-Goals

- No changes to the public registration flow or its data schema.
- No analytics warehouse / BI tool; metrics are computed on demand.
- No write access to attendee PII beyond check-in status updates.

## Architecture

```
                 admin.awssecurityecuador.com
                          │
                          ▼
                     CloudFront  ── viewer-request ──► block-dotfiles fn
                     (geo: EC)        security-headers policy
                       │   │
        default ◄──────┘   └──────► /api/*
          │                            │
          ▼                            ▼
   S3 (admin site, private)      API Gateway (HTTP API)
   OAC, no public access           JWT authorizer (Cognito User Pool)
                                       │
                                       ▼
                                  Lambda (admin handler, Python 3.12)
                                       │
                         ┌─────────────┼───────────────┐
                         ▼             ▼               ▼
                   DynamoDB        DynamoDB         CloudWatch Logs
                (registrations)  (export-audit)    (structured logs)
```

### Authentication & Authorization flow

1. Browser loads the static SPA from CloudFront.
2. If no valid session, SPA redirects to the Cognito Hosted UI (OAuth2
   authorization-code + PKCE).
3. Cognito authenticates the user (optionally MFA) and redirects back with a
   code; the SPA exchanges it for ID/access tokens.
4. SPA calls `/api/*` with the access token in `Authorization: Bearer <jwt>`.
5. API Gateway's JWT authorizer validates the token against the Cognito User
   Pool (issuer + audience).
6. The Lambda reads the `cognito:groups` claim to enforce role logic.

Roles are derived only from the JWT group claim, never from request body/query.

## Components and Interfaces

### Frontend (static SPA)

- Plain HTML + vanilla JS + Tailwind CDN, consistent with existing sites.
- Uses Cognito Hosted UI for login (no custom login form).
- Stores tokens in memory / sessionStorage; refreshes via refresh token.
- Views: Login redirect, Dashboard (metrics + table), Export panel, Check-in.

### API (API Gateway HTTP API + Lambda)

Single Lambda (`lambda/admin/handler.py`) routing by method + path. Endpoints:

| Method | Path | Role | Purpose |
|--------|------|------|---------|
| GET | `/api/registrations` | admins | Paginated list (search, filters) |
| GET | `/api/metrics` | admins | Aggregate counts |
| GET | `/api/export` | admins | CSV export (filters incl. consent) |
| GET | `/api/pool` | admins, recruiters | Consented candidate pool (minimized fields) |
| GET | `/api/pool/export` | admins, recruiters | CSV of consented pool only |
| POST | `/api/checkin` | admins | Mark attendee checked-in |

All endpoints require a valid Cognito JWT (authorizer). The Lambda additionally
enforces group-based authorization and field minimization.

### Cognito User Pool

- User Pool with email sign-in, admin-created users only
  (`AdminCreateUser`, self sign-up disabled).
- App client (no secret, PKCE) configured for the Hosted UI with the
  dashboard callback/logout URLs.
- Groups: `admins`, `recruiters`.
- Optional: MFA (TOTP) set to optional/required per organizer preference.
- Hosted UI domain: `auth-admin.awssecurityecuador.com` or a Cognito-prefixed domain.

## Data Models

### Existing: registrations table (read-only here)

Reused as-is. Relevant attributes consumed: `registration_id`, `event`,
`email`, `first_name`, `last_name`, `city`, `experience`, `ai_experience`,
`employment_status`, `company`, `role`, `consent_recruiters`,
`registered_at`, `checked_in`, `checked_in_at`. The `event-index` GSI is used
to query by event; `EMAIL_LOCK#` items are always filtered out
(`attribute_not_exists(lock_type)`).

### New: export audit table

`awssecurity-ecuador-export-audit` (PAY_PER_REQUEST):

```
export_id        : <uuid>            # partition key
exported_by      : <cognito email/sub>
exported_at      : ISO8601
export_type      : all | pool | filtered
filter           : JSON string of applied filters
record_count     : number
role             : admins | recruiters
```

Written on every export for LOPDP traceability.

## Data access & queries

- **List/metrics**: `Query` on `event-index` with `event = :eid` and
  `FilterExpression = attribute_not_exists(lock_type)`, paginated via
  `LastEvaluatedKey`. Metrics aggregate in the Lambda.
- **Pool**: same query plus `consent_recruiters = :true` filter.
- **Search**: applied in-Lambda over the queried page(s) (dataset is small, <= 400).
- **Check-in**: `UpdateItem` on `registration_id` setting `checked_in` and
  `checked_in_at` (reuses existing check-in logic).

## Field minimization (recruiter role)

The `recruiters` role only ever receives consented records, and only these
fields: `first_name`, `last_name`, `email`, `employment_status`, `experience`,
`ai_experience`, `company`, `role`. Fields like `phone`, `expectations`,
consent flags, and internal attributes are stripped server-side before response.

## Export design

- CSV generated in-Lambda; returned as a downloadable response
  (`Content-Type: text/csv`, `Content-Disposition: attachment`).
- `admins` may export `all` or `filtered` (by employment status, city) or `pool`.
- `recruiters` may export only `pool` (consented), filters cannot widen scope.
- Every export writes an audit record (Requirement 5.5).

## Infrastructure (Terraform)

New file `terraform/admin.tf` defining:

- `aws_cognito_user_pool`, `aws_cognito_user_pool_client`,
  `aws_cognito_user_pool_domain`, `aws_cognito_user_group` (admins, recruiters).
- `aws_dynamodb_table.export_audit`.
- `aws_lambda_function.admin` + IAM role (DynamoDB read on registrations +
  read/write on export-audit + check-in UpdateItem).
- `aws_apigatewayv2_api` + JWT authorizer (Cognito) + routes + integration +
  `aws_lambda_permission`.
- `aws_s3_bucket.admin` (private) + OAC + bucket policy.
- `aws_cloudfront_distribution.admin` with: `block-dotfiles` function
  association, security-headers policy, geo-restriction `["EC"]`, NO 403
  custom error response, ACM cert, alias `admin.awssecurityecuador.com`.
- `aws_acm_certificate` (us-east-1) + validation + `aws_route53_record` (A/AAAA).
- Outputs for bucket name and distribution id (for the deploy workflow sync).

Deploy workflow gains a sync step for `./admin` and a CloudFront invalidation
for the admin distribution.

## Security

- Buckets private; CloudFront OAC only; HTTPS only.
- JWT authorizer at API Gateway; group-based authz + field minimization in Lambda.
- IAM least-privilege: admin Lambda role limited to the two tables and required actions.
- Geo-restriction `EC` only; no 403→200 fallback (so geo + authz actually block).
- Export audit log for accountability (LOPDP).
- No secrets in code; Cognito handles credentials/MFA.
- `block-dotfiles` function prevents serving dotfiles.

## Error Handling

- 401 when JWT missing/invalid (API Gateway authorizer).
- 403 when role lacks permission (Lambda).
- 400 for malformed requests; 404 for unknown check-in codes.
- 5xx are logged with structured context (no PII values, emails masked).
- Fail-closed: on data-access errors, return error rather than partial/unfiltered data.

## Correctness Properties

### Property 1: Recruiter results are always consented
A `recruiters` response NEVER contains a record with `consent_recruiters != true`.

**Validates: Requirements 2.2, 5.4, 8.3**

### Property 2: No internal items leak
No API response ever contains an `EMAIL_LOCK#` item or internal attributes
(`lock_type`; raw consent flags for the recruiter role).

**Validates: Requirements 3.2, 8.2**

### Property 3: Role comes from the verified token
Role is always derived from the verified JWT `cognito:groups` claim; any
client-supplied role hint is ignored.

**Validates: Requirements 2.4**

### Property 4: Exports are always audited
Every successful export produces exactly one audit record whose `record_count`
matches the number of rows exported (including zero when empty).

**Validates: Requirements 5.5**

### Property 5: No unauthenticated data access
A request without a valid Cognito JWT can never reach DynamoDB; it is blocked at
the API Gateway authorizer.

**Validates: Requirements 1.3, 8.1**

### Property 6: Counts exclude lock items
Capacity and metrics counts equal the number of real registrations
(`EMAIL_LOCK#` items excluded).

**Validates: Requirements 3.2, 4.4**

### Property 7: Pool export field minimization
The recruiter pool export field set is a strict subset of the fields covered by
the recruiter consent.

**Validates: Requirements 5.6, 8.3**

## Testing Strategy

- Unit tests (Lambda): role enforcement (admin vs recruiter), `EMAIL_LOCK#`
  exclusion, field minimization for recruiters, consent filtering for pool,
  export audit write, check-in transitions.
- Auth tests: requests without/with invalid/expired JWT → 401; recruiter to
  admin endpoint → 403.
- IaC validation: `terraform validate`, `checkov`, and Snyk IaC scan.
- Manual: Cognito Hosted UI login end-to-end; CSV export contents verified to
  contain only consented records for the pool export.

## Open Questions / Decisions

- Hosted UI domain: Cognito-prefixed vs custom `auth-admin.` subdomain (custom
  needs an extra ACM cert). Default: Cognito-prefixed to keep it simple.
- MFA: optional vs required for admins. Recommend required for `admins`.
- Whether to fully migrate the existing `checkin.html` to this dashboard or keep
  both during the event. Recommend keeping the current check-in page until the
  dashboard is validated, then deprecate the shared secret.
