output "website_bucket_name" {
  description = "Main website S3 bucket"
  value       = aws_s3_bucket.website.id
}

output "cloudfront_distribution_id" {
  description = "Main CloudFront distribution ID"
  value       = aws_cloudfront_distribution.website.id
}

output "cloudfront_domain_name" {
  description = "Main CloudFront domain name"
  value       = aws_cloudfront_distribution.website.domain_name
}

output "website_url" {
  description = "Live website URL"
  value       = "https://${var.domain_name}"
}

output "github_deploy_role_arn" {
  description = "Deploy role ARN"
  value       = aws_iam_role.github_actions_deploy.arn
}

# ── aisecurity subdomain ─────────────────────────────────────────────────────

output "aisecurity_bucket_name" {
  description = "aisecurity S3 bucket"
  value       = aws_s3_bucket.aisecurity.id
}

output "aisecurity_distribution_id" {
  description = "aisecurity CloudFront distribution ID"
  value       = aws_cloudfront_distribution.aisecurity.id
}

output "aisecurity_url" {
  description = "Event site URL"
  value       = "https://aisecurity.awssecurityecuador.com"
}

# ── register subdomain ───────────────────────────────────────────────────────

output "register_bucket_name" {
  description = "register S3 bucket"
  value       = aws_s3_bucket.register.id
}

output "register_distribution_id" {
  description = "register CloudFront distribution ID"
  value       = aws_cloudfront_distribution.register.id
}

output "register_url" {
  description = "Registration site URL"
  value       = "https://register.awssecurityecuador.com"
}

output "register_api_endpoint" {
  description = "API Gateway endpoint for registration"
  value       = aws_apigatewayv2_api.register.api_endpoint
}

output "registrations_table_name" {
  description = "DynamoDB table for registrations"
  value       = aws_dynamodb_table.registrations.name
}

# ── Sponsors ─────────────────────────────────────────────────────────────────

output "sponsors_bucket_name" {
  description = "S3 bucket for sponsors site"
  value       = aws_s3_bucket.sponsors.id
}

output "sponsors_distribution_id" {
  description = "CloudFront distribution ID for sponsors site"
  value       = aws_cloudfront_distribution.sponsors.id
}

# ── Admin dashboard ──────────────────────────────────────────────────────────

output "admin_bucket_name" {
  description = "Admin dashboard S3 bucket"
  value       = aws_s3_bucket.admin.id
}

output "admin_distribution_id" {
  description = "Admin dashboard CloudFront distribution ID"
  value       = aws_cloudfront_distribution.admin.id
}

output "admin_cognito_domain" {
  description = "Cognito Hosted UI domain for the admin dashboard"
  value       = "https://${aws_cognito_user_pool_domain.admin.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "admin_cognito_client_id" {
  description = "Cognito app client ID for the admin SPA"
  value       = aws_cognito_user_pool_client.admin.id
}

output "admin_cognito_user_pool_id" {
  description = "Cognito user pool ID for the admin dashboard"
  value       = aws_cognito_user_pool.admin.id
}

output "budget_table_name" {
  description = "DynamoDB table for event budget tracking"
  value       = aws_dynamodb_table.budget.name
}

# ── Certificates ─────────────────────────────────────────────────────────────

output "certificates_bucket_name" {
  description = "Private S3 bucket for certificate PDFs"
  value       = aws_s3_bucket.certificates.id
}

output "certificates_distribution_id" {
  description = "CloudFront distribution ID for certificate PDFs"
  value       = aws_cloudfront_distribution.certificates.id
}

output "certificates_cdn_domain" {
  description = "CloudFront domain for certificate PDF delivery"
  value       = aws_cloudfront_distribution.certificates.domain_name
}
