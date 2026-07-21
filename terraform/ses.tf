# ============================================================================
# SES — Email sending for registration confirmations
# ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Domain identity — verify awssecurityecuador.com
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sesv2_email_identity" "domain" {
  email_identity = "awssecurityecuador.com"
}

# DKIM verification records — required for sending
resource "aws_route53_record" "ses_dkim" {
  count   = 3
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.awssecurityecuador.com"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# SPF record — authorize SES and iCloud Mail to send on behalf of the domain
resource "aws_route53_record" "ses_spf" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "awssecurityecuador.com"
  type    = "TXT"
  ttl     = 600
  records = [
    "v=spf1 include:amazonses.com include:icloud.com ~all",
    "apple-domain=HxFyYO4OFKaPRW4h"
  ]

  allow_overwrite = true
}

# DMARC record — authentication policy
resource "aws_route53_record" "ses_dmarc" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "_dmarc.awssecurityecuador.com"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=quarantine; rua=mailto:dmarc@awssecurityecuador.com"]
}

# ─────────────────────────────────────────────────────────────────────────────
# Mail-from domain (improves deliverability — uses awssecurityecuador.com instead of amazonses.com)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  email_identity         = aws_sesv2_email_identity.domain.email_identity
  mail_from_domain       = "mail.awssecurityecuador.com"
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

# MX record for mail-from domain
resource "aws_route53_record" "ses_mail_from_mx" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "mail.awssecurityecuador.com"
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.us-east-1.amazonses.com"]
}

# SPF record for mail-from domain
resource "aws_route53_record" "ses_mail_from_spf" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "mail.awssecurityecuador.com"
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com ~all"]
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda permissions — allow SES SendEmail
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role_policy" "register_lambda_ses" {
  name = "ses-send-email"
  role = aws_iam_role.register_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ]
      Resource = "*"
      Condition = {
        StringEquals = {
          "ses:FromAddress" = "noreply@awssecurityecuador.com"
        }
      }
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────

output "ses_domain_verified" {
  description = "SES domain identity for sending emails"
  value       = aws_sesv2_email_identity.domain.email_identity
}

output "ses_from_address" {
  description = "Sender email address for confirmations"
  value       = "noreply@awssecurityecuador.com"
}

# ─────────────────────────────────────────────────────────────────────────────
# iCloud Mail — Custom domain email (receive mail via iCloud)
# ─────────────────────────────────────────────────────────────────────────────

# MX records — route incoming mail to iCloud
resource "aws_route53_record" "icloud_mx" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "awssecurityecuador.com"
  type    = "MX"
  ttl     = 600
  records = [
    "10 mx01.mail.icloud.com.",
    "10 mx02.mail.icloud.com."
  ]
}

# DKIM CNAME — iCloud mail signing
resource "aws_route53_record" "icloud_dkim" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "sig1._domainkey.awssecurityecuador.com"
  type    = "CNAME"
  ttl     = 600
  records = ["sig1.dkim.awssecurityecuador.com.at.icloudmailadmin.com."]
}
