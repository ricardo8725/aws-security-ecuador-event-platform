# AWS Security Ecuador — Event Platform

A complete, serverless event platform built for **AWS GenAI Security Day 2026**
(organized by the AWS User Group Security Ecuador). It covers everything an
in-person tech event needs: a marketing microsite, online registration with
email + QR confirmation, staff QR check-in, a sponsors funnel, an admin
dashboard with metrics and exports, and automated certificate generation.

This repository is published as a **reference implementation** — feel free to
reuse it for your own community event. It was **built with [Kiro](https://kiro.dev)**,
an AI-powered IDE, using a spec-driven workflow. The `.kiro/` folder is included
on purpose so you can see the steering docs, specs, and agent hooks that guided
the build.

> Built by the community, for the community — to help democratize cloud &
> security knowledge in Ecuador. 🇪🇨

## What's inside

Five independently deployed static sites + a serverless backend, all managed
from a single Terraform state:

| Site | Purpose |
|------|---------|
| **Main** (`index.html`) | Community landing page |
| **aisecurity/** | Event microsite (agenda, speakers, activities) |
| **register/** | Registration form + QR-based staff check-in |
| **sponsors/** | Sponsor inquiry funnel |
| **admin/** | Auth-protected dashboard (metrics, exports, check-in, certificates) |

### Backend (AWS Lambda, Python 3.12)

- **register** — validates input, writes to DynamoDB, generates a QR, uploads it
  to a private S3 bucket, and emails a confirmation via SES.
- **checkin** — staff-secret authenticated; validates a QR/code and marks
  attendance.
- **sponsors** — routes sponsor inquiries to email via SES.
- **admin** — JWT-authorized (Cognito) API for metrics, registration lists,
  CSV exports (with an audit trail), and manual check-in.
- **certificates** — generates attendance/participation PDFs (ReportLab) and
  emails them.

## Architecture

```
Route53 → CloudFront (per site) → S3 (static, OAC-only)
                     └─ /api/*  → API Gateway (HTTP API) → Lambda → DynamoDB / SES / S3
Cognito (admin auth) · SSM Parameter Store (secrets) · CloudFront Functions (edge)
```

- **Frontend**: static HTML, Tailwind via CDN, vanilla JS — zero build step.
- **Data**: DynamoDB single-table design.
- **Email**: Amazon SES (transactional confirmations, certificates, notices).
- **Auth**: Amazon Cognito (admin dashboard), staff shared-secret (check-in).
- **Bot protection**: Cloudflare Turnstile on the registration form.
- **Security**: private S3 buckets (CloudFront OAC only), secrets in SSM (never
  in code), geo-restrictions, security headers, fail-closed input validation,
  PII masking in logs.

## Built with Kiro (spec-driven)

The `.kiro/` directory shows how this was built with an AI IDE:

- **`steering/`** — always-on project context (product, tech stack, structure)
  that keeps the AI aligned with conventions.
- **`specs/`** — a full requirements → design spec for the admin dashboard
  feature (spec-driven development).
- **`hooks/`** — agent hooks that automate quality gates (e.g. run security
  scans before `git push`).

## Deploy it yourself

Prerequisites: an AWS account, a Route53 hosted zone for your domain, Terraform
`>= 1.5`, and (for CI/CD) a GitHub repo with OIDC configured.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan
terraform apply
```

Local preview of the static sites:

```bash
python3 -m http.server 8000   # then open http://localhost:8000
```

### Configuration

Secrets are **never** committed. Provide them at apply time (or via CI secrets):

- `checkin_secret` — staff check-in portal token (stored in SSM).
- `turnstile_secret` — Cloudflare Turnstile secret key.

Project-specific values (domain, hosted zone, GitHub org, AWS profile) are
Terraform variables — see `terraform/terraform.tfvars.example`.

## Security & privacy notes

- No secrets, credentials, account IDs, or personal data are stored in this
  repository. Attendee data lived only in DynamoDB and was handled per Ecuador's
  data-protection law (LOPDP).
- If you reuse this, review the geo-restrictions, email addresses, and
  compliance/consent copy for your own jurisdiction.

## License

MIT — see [LICENSE](LICENSE). Reuse freely; attribution appreciated.
