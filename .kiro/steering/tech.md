# Tech Stack

## Frontend

- Static HTML sites (no build step, no bundler)
- Tailwind CSS via CDN (`cdn.tailwindcss.com`) with inline config
- Custom CSS in `css/style.css` using CSS custom properties
- Vanilla JavaScript (ES6+, no frameworks)
- Fonts: Inter (body), JetBrains Mono (monospace/code aesthetic)
- Dark theme with GitHub-inspired color palette (`#0d1117` background, `#0a73ff` blue, `#00ff88` green)
- Emoji-based favicons (inline SVG, no extra files): 🛡️ main, 🤖 aisecurity, 🎫 register, ✅ checkin, 🤝 sponsors

## Backend

- AWS Lambda (Python 3.12) for serverless functions
- DynamoDB for data storage (table: `awssecurity-ecuador-registrations`)
- SES for transactional email (out of sandbox, 50k/day quota, 14/sec rate)
- SSM Parameter Store for secrets at runtime
- Cloudflare Turnstile for CAPTCHA/bot protection
- S3 + CloudFront serves QR codes (private bucket, OAC-only access, UUID paths)

## Infrastructure

- Terraform >= 1.5.0 with AWS provider ~> 5.0
- S3 backend with DynamoDB state locking
- Region: us-east-1
- S3 + CloudFront for static site hosting
- Route53 for DNS, ACM for TLS certificates
- AWS profile (local): `servicescloudsec-admin`

## CI/CD

- GitHub Actions (`.github/workflows/deploy.yml`)
- Triggered on push to `main` or manual dispatch
- Pipeline: checkout → AWS OIDC auth → Terraform init/plan/apply → S3 sync → CloudFront invalidation
- Uses OIDC role assumption (no static credentials)
- Required GitHub secrets: `AWS_ROLE_ARN`, `CHECKIN_SECRET`, `TURNSTILE_SECRET`

## Common Commands

```bash
# Local development — serve the main site
python3 -m http.server 8000

# Terraform (from ./terraform directory)
terraform init
terraform plan -var="aws_profile=servicescloudsec-admin" -var="checkin_secret=<secret>" -var="turnstile_secret=<secret>"
terraform apply

# Format and lint Terraform recursively
terraform fmt -recursive

# Run security scan locally before push
checkov -d terraform/ --quiet --compact

# Manually trigger deploy workflow
gh workflow run deploy.yml

# Monitor latest run
gh run list --limit 1
gh run watch <run-id>
```

## Email Authentication (DNS)

- SPF: `v=spf1 include:amazonses.com include:icloud.com ~all`
- DKIM: 3 SES CNAMEs (`*._domainkey`) + iCloud `sig1._domainkey`
- DMARC: `v=DMARC1; p=quarantine; rua=mailto:dmarc@awssecurityecuador.com`
- Inbound: iCloud MX records (mx01/mx02.mail.icloud.com)

## Key Libraries (Lambda)

- `boto3` — AWS SDK
- `qrcode` — QR code generation (registration handler)
- `Pillow (PIL)` — image processing for QR codes (bundled in `lambda/register/PIL/`)
- Standard library only for checkin handler

## Conventions

- Lambda handlers follow the pattern: `lambda/<function-name>/handler.py` with a `lambda_handler(event, context)` entry point
- All Lambda responses use a shared `response(status_code, body)` helper with CORS headers
- Input validation is fail-closed (reject on error)
- Sensitive data is masked in logs (e.g., `mask_email()`)
- Environment variables for all configuration (no hardcoded secrets)
- Anti-duplicate registration uses `EMAIL_LOCK#<email>#<event>` items in same DynamoDB table; check-in handler must filter these out
- QR codes delivered via CloudFront URL (not base64) for Gmail/Outlook deliverability

## Geo-restrictions (CloudFront)

- Main site, aisecurity, sponsors, register: whitelist `["EC"]`
- QR codes distribution: broad whitelist `["EC", "US", "IE", "NL", "GB", "DE", "BR", "CL", "CO", "MX", "PE"]` because email image proxies (Gmail, Outlook, Yahoo) fetch from US/EU servers
- Note: changing geo from `whitelist` to `none` in-place fails with `InvalidGeoRestrictionParameter` on existing distributions; use a broad whitelist instead
