# Project Structure

```
.
├── index.html                  # Main community landing page
├── css/
│   └── style.css               # Global styles (CSS custom properties, dark theme)
├── js/
│   └── main.js                 # Vanilla JS (navbar, modals, scroll effects)
├── assets/                     # Images for the main site
│   ├── communities/            # Community partner logos
│   ├── logos/                  # Brand logos
│   └── evento-*.{webp,jpeg,png}  # Event flyers/photos
│
├── aisecurity/                 # Sub-site: AI Security Day event
│   ├── index.html
│   └── assets/
│
├── register/                   # Sub-site: Event registration + check-in
│   ├── index.html              # Registration form
│   ├── checkin.html            # Staff check-in scanner
│   ├── html5-qrcode.min.js    # QR scanner library
│   └── assets/
│
├── sponsors/                   # Sub-site: Sponsors page
│   └── index.html
│
├── lambda/                     # AWS Lambda functions (Python)
│   ├── register/
│   │   ├── handler.py          # Registration API (DynamoDB + SES + QR upload to S3)
│   │   ├── PIL/                # Bundled Pillow library
│   │   └── qrcode/             # Bundled qrcode library
│   ├── checkin/
│   │   └── handler.py          # Check-in API (QR validation, filters EMAIL_LOCK# items)
│   └── sponsors/
│       └── handler.py          # Sponsor inquiry → SES notification
│
├── terraform/                  # Infrastructure as Code
│   ├── providers.tf            # AWS provider + S3 backend config
│   ├── variables.tf            # Input variables (incl. checkin_secret, turnstile_secret)
│   ├── outputs.tf              # Terraform outputs
│   ├── locals.tf               # Local values (suffix = "ec2026")
│   ├── s3.tf                   # S3 bucket (main site)
│   ├── cloudfront.tf           # CloudFront distribution + security headers policy (main site)
│   ├── route53.tf              # DNS records (main + IPv6 alias)
│   ├── acm.tf                  # TLS certificates
│   ├── iam.tf                  # GitHub Actions deploy role + policies
│   ├── ses.tf                  # SES domain identity, DKIM, DMARC, SPF, iCloud MX/DKIM
│   ├── aisecurity.tf           # AI Security sub-site infra
│   ├── register.tf             # Registration sub-site + Lambda + DynamoDB + API Gateway
│   │                           #   + QR codes private S3 bucket + CloudFront
│   └── sponsors.tf             # Sponsors sub-site infra + Lambda
│
├── .github/workflows/
│   └── deploy.yml              # CI/CD pipeline (Terraform + S3 sync + CF invalidation)
│
├── .kiro/
│   ├── steering/               # AI assistant guidance (product, tech, structure)
│   └── hooks/                  # Agent hooks (deploy-to-main, checkov-before-push)
│
└── sources/                    # Design resources / raw assets
```

## Architecture Pattern

Each sub-site (`aisecurity`, `register`, `sponsors`) is independently deployed to its own S3 bucket with a dedicated CloudFront distribution. The Terraform config manages all of them from a single state file.

The QR code storage uses an additional private S3 bucket fronted by its own CloudFront distribution (public access blocked, OAC-only). QR codes are uploaded by the register Lambda and served via unguessable UUID URLs in confirmation emails.

## Key Conventions

- Each sub-site is self-contained (own `index.html`, assets) — no shared build artifacts
- Lambda dependencies are bundled directly in the function directory (no layer, no package manager)
- Terraform files are split by AWS service/concern, not by environment
- No `node_modules` or package.json — frontend has zero build dependencies
- Static assets are committed to the repo (no external asset pipeline)
- DynamoDB single-table pattern: registrations and `EMAIL_LOCK#` items share the table

## Agent Hooks

- **Deploy to Main** (manual trigger): runs `terraform fmt`, stages changes, commits with user-provided message, pushes to `main`, monitors GitHub Actions deploy
- **Checkov Security Scan** (preToolUse on shell): runs `checkov -d terraform/` before any `git push` to catch HIGH/CRITICAL findings

## Currently Excluded from Git (.gitignore)

- Terraform state and plan files
- Lambda zip artifacts (`lambda/*.zip`)
- PDF files (`*.pdf`)
- `.kiro/` directory (kept locally, not pushed)
