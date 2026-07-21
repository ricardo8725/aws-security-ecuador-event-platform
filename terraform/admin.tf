# ============================================================================
# ADMIN DASHBOARD — admin.awssecurityecuador.com
# Cognito (auth) + API Gateway + Lambda + DynamoDB audit + S3/CloudFront
# ============================================================================

locals {
  admin_domain = "admin.awssecurityecuador.com"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cognito — User Pool (manual user creation only, no self sign-up)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cognito_user_pool" "admin" {
  name = "${var.project_name}-admin"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  mfa_configuration = "ON"
  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.admin.id
  description  = "Full access to registrations, metrics, export, check-in"
}

resource "aws_cognito_user_group" "recruiters" {
  name         = "recruiters"
  user_pool_id = aws_cognito_user_pool.admin.id
  description  = "Access to the consented candidate pool only"
}

resource "aws_cognito_user_pool_domain" "admin" {
  domain       = "ugsec-ecuador-admin-${local.suffix}"
  user_pool_id = aws_cognito_user_pool.admin.id
}

resource "aws_cognito_user_pool_client" "admin" {
  name         = "${var.project_name}-admin-spa"
  user_pool_id = aws_cognito_user_pool.admin.id

  generate_secret = false

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["https://${local.admin_domain}/"]
  logout_urls   = ["https://${local.admin_domain}/"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 1
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

# ─────────────────────────────────────────────────────────────────────────────
# DynamoDB — export audit log (LOPDP traceability)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "export_audit" {
  name         = "${var.project_name}-export-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "export_id"

  attribute {
    name = "export_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = { Component = "admin-dashboard" }
}

# ─────────────────────────────────────────────────────────────────────────────
# DynamoDB — budget items (income/expenses tracker)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "budget" {
  name         = "${var.project_name}-budget"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "item_id"

  attribute {
    name = "item_id"
    type = "S"
  }

  attribute {
    name = "type"
    type = "S"
  }

  global_secondary_index {
    name            = "type-index"
    hash_key        = "type"
    projection_type = "ALL"
  }

  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }

  tags = { Component = "admin-budget" }
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda — admin API handler
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "admin_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/admin"
  output_path = "${path.module}/../lambda/admin.zip"
}

resource "aws_iam_role" "admin_lambda" {
  name = "${var.project_name}-admin-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "admin_lambda_basic" {
  role       = aws_iam_role.admin_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "admin_lambda_dynamo" {
  name = "dynamodb-access"
  role = aws_iam_role.admin_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = [aws_dynamodb_table.registrations.arn, "${aws_dynamodb_table.registrations.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.export_audit.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [aws_dynamodb_table.budget.arn, "${aws_dynamodb_table.budget.arn}/index/*"]
      }
    ]
  })
}

resource "aws_lambda_function" "admin" {
  function_name    = "${var.project_name}-admin"
  role             = aws_iam_role.admin_lambda.arn
  filename         = data.archive_file.admin_lambda.output_path
  source_code_hash = data.archive_file.admin_lambda.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 15
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.registrations.name
      AUDIT_TABLE_NAME  = aws_dynamodb_table.export_audit.name
      BUDGET_TABLE_NAME = aws_dynamodb_table.budget.name
      ALLOWED_ORIGIN    = "https://${local.admin_domain}"
      EVENT_ID          = "aws-gen-ai-security-day-2026"
    }
  }
}

resource "aws_cloudwatch_log_group" "admin_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.admin.function_name}"
  retention_in_days = 30
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway (HTTP API) with Cognito JWT authorizer
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "admin" {
  name          = "${var.project_name}-admin-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://${local.admin_domain}"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_authorizer" "admin_jwt" {
  api_id           = aws_apigatewayv2_api.admin.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.admin.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.admin.id}"
  }
}

resource "aws_apigatewayv2_integration" "admin" {
  api_id                 = aws_apigatewayv2_api.admin.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.admin.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "admin_routes" {
  for_each = toset([
    "GET /api/registrations",
    "GET /api/metrics",
    "GET /api/export",
    "GET /api/pool",
    "GET /api/pool/export",
    "GET /api/sponsors/export",
    "POST /api/checkin",
    "GET /api/budget",
    "POST /api/budget",
    "PUT /api/budget",
    "DELETE /api/budget",
  ])
  api_id             = aws_apigatewayv2_api.admin.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.admin.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.admin_jwt.id
}

resource "aws_apigatewayv2_stage" "admin" {
  api_id      = aws_apigatewayv2_api.admin.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "admin_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.admin.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.admin.execution_arn}/*/*"
}

# ─────────────────────────────────────────────────────────────────────────────
# Static site — S3 (private) + CloudFront
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "admin" {
  bucket = "${var.project_name}-admin-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "admin" {
  bucket                  = aws_s3_bucket.admin.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "admin" {
  bucket = aws_s3_bucket.admin.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "admin" {
  bucket     = aws_s3_bucket.admin.id
  depends_on = [aws_cloudfront_distribution.admin]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.admin.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.admin.arn }
      }
    }]
  })
}

# ── ACM certificate (us-east-1 for CloudFront) ───────────────────────────────
resource "aws_acm_certificate" "admin" {
  provider          = aws.us_east_1
  domain_name       = local.admin_domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "admin_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.admin.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "admin" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.admin.arn
  validation_record_fqdns = [for r in aws_route53_record.admin_cert_validation : r.fqdn]
}

# ── CloudFront ───────────────────────────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "admin" {
  name                              = "${var.project_name}-admin-oac"
  description                       = "OAC for ${local.admin_domain}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Admin-specific security headers — CSP allows the Cognito Hosted UI / token
# endpoint in connect-src (the SPA does a fetch to /oauth2/token).
resource "aws_cloudfront_response_headers_policy" "admin_security" {
  name = "${var.project_name}-admin-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    content_security_policy {
      content_security_policy = "default-src 'self'; script-src 'self' https://cdn.tailwindcss.com 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: blob: https:; connect-src 'self' https://cognito-idp.${var.aws_region}.amazonaws.com https://${aws_cognito_user_pool_domain.admin.domain}.auth.${var.aws_region}.amazoncognito.com; base-uri 'self'; object-src 'none'; frame-ancestors 'self';"
      override                = true
    }
  }
}

resource "aws_cloudfront_distribution" "admin" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Admin dashboard — ${local.admin_domain}"
  default_root_object = "index.html"
  aliases             = [local.admin_domain]
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  # S3 origin (static site)
  origin {
    domain_name              = aws_s3_bucket.admin.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.admin.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.admin.id
  }

  # API Gateway origin
  origin {
    domain_name = replace(aws_apigatewayv2_api.admin.api_endpoint, "https://", "")
    origin_id   = "API-${aws_apigatewayv2_api.admin.id}"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "S3-${aws_s3_bucket.admin.id}"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # CORS-S3Origin
    response_headers_policy_id = aws_cloudfront_response_headers_policy.admin_security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.block_dotfiles.arn
    }
  }

  # API behavior — route /api/* to API Gateway
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "API-${aws_apigatewayv2_api.admin.id}"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    viewer_protocol_policy   = "https-only"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
  }

  # No 403 custom error response: keeps geo-restriction enforced.
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["EC"]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.admin.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.admin]
}

# ── Route53 ──────────────────────────────────────────────────────────────────
resource "aws_route53_record" "admin_a" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.admin_domain
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.admin.domain_name
    zone_id                = aws_cloudfront_distribution.admin.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "admin_aaaa" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.admin_domain
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.admin.domain_name
    zone_id                = aws_cloudfront_distribution.admin.hosted_zone_id
    evaluate_target_health = false
  }
}

# ── Deploy role permissions (S3 sync + CloudFront invalidation) ──────────────
resource "aws_iam_role_policy" "deploy_admin_s3" {
  name = "s3-admin-rw"
  role = aws_iam_role.github_actions_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource = [aws_s3_bucket.admin.arn, "${aws_s3_bucket.admin.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "deploy_admin_cf" {
  name = "cloudfront-invalidate-admin"
  role = aws_iam_role.github_actions_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
      Resource = aws_cloudfront_distribution.admin.arn
    }]
  })
}
