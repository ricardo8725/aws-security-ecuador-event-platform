# ============================================================================
# REGISTER — Registration site + API + DynamoDB (register.awssecurityecuador.com)
# ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# DynamoDB — registration records
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "registrations" {
  name         = "${var.project_name}-registrations"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "registration_id"

  attribute {
    name = "registration_id"
    type = "S"
  }

  attribute {
    name = "email"
    type = "S"
  }

  attribute {
    name = "event"
    type = "S"
  }

  global_secondary_index {
    name            = "email-index"
    hash_key        = "email"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "event-index"
    hash_key        = "event"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Component = "registration-api"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda — registration handler
# ─────────────────────────────────────────────────────────────────────────────

# Build Lambda zip from source
data "archive_file" "register_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/register"
  output_path = "${path.module}/../lambda/register.zip"
}

# Lambda execution role
resource "aws_iam_role" "register_lambda" {
  name = "${var.project_name}-register-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "register_lambda_basic" {
  role       = aws_iam_role.register_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "register_lambda_dynamo" {
  name = "dynamodb-write"
  role = aws_iam_role.register_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:Query",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:Scan"
      ]
      Resource = [
        aws_dynamodb_table.registrations.arn,
        "${aws_dynamodb_table.registrations.arn}/index/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "checkin_lambda_ssm" {
  name = "ssm-read-checkin-secret"
  role = aws_iam_role.register_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter"
      ]
      Resource = [aws_ssm_parameter.checkin_secret.arn]
    }]
  })
}

resource "aws_lambda_function" "register" {
  function_name    = "${var.project_name}-register"
  role             = aws_iam_role.register_lambda.arn
  filename         = data.archive_file.register_lambda.output_path
  source_code_hash = data.archive_file.register_lambda.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.registrations.name
      ALLOWED_ORIGIN    = "https://register.awssecurityecuador.com"
      SES_FROM_ADDRESS  = "AWS UG Security Ecuador <noreply@awssecurityecuador.com>"
      EVENT_NAME        = "AWS GenAI Security Day 2026"
      EVENT_DATE        = "18 de Julio, 2026"
      EVENT_TIME        = "08h30 - 16h00 ECT"
      EVENT_VENUE       = "Universidad Ecotec — Av. Juan Tanca Marengo Km. 2, Guayaquil"
      EVENT_URL         = "https://aisecurity.awssecurityecuador.com"
      MAX_REGISTRATIONS = "400"
      TURNSTILE_SECRET  = var.turnstile_secret
      QR_BUCKET         = aws_s3_bucket.qr_codes.id
      QR_CDN_DOMAIN     = aws_cloudfront_distribution.qr_codes.domain_name
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 — QR code storage (private, presigned URLs for email delivery)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "qr_codes" {
  bucket = "${var.project_name}-qrcodes-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "qr_codes" {
  bucket                  = aws_s3_bucket.qr_codes.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "qr_codes" {
  bucket = aws_s3_bucket.qr_codes.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "qr_codes" {
  bucket = aws_s3_bucket.qr_codes.id

  rule {
    id     = "expire-after-event"
    status = "Enabled"
    expiration {
      days = 90
    }
  }
}

# CloudFront OAC for QR bucket
resource "aws_cloudfront_origin_access_control" "qr_codes" {
  name                              = "${var.project_name}-qr-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "qr_codes" {
  enabled         = true
  comment         = "QR codes for event registrations"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    domain_name              = aws_s3_bucket.qr_codes.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.qr_codes.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.qr_codes.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.qr_codes.id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  restrictions {
    # Email image proxies (Gmail, Outlook, Yahoo) fetch from US-based servers.
    # Whitelisting the proxy regions lets QR images load in email clients.
    # Note: "none" cannot be applied in-place to an existing distribution
    # (provider/AWS InvalidGeoRestrictionParameter bug on whitelist->none),
    # so we use a broad whitelist covering major email proxy locations.
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["EC", "US", "IE", "NL", "GB", "DE", "BR", "CL", "CO", "MX", "PE"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Bucket policy — allow CloudFront OAC access
resource "aws_s3_bucket_policy" "qr_codes" {
  bucket     = aws_s3_bucket.qr_codes.id
  depends_on = [aws_cloudfront_distribution.qr_codes]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.qr_codes.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.qr_codes.arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "register_lambda_s3_qr" {
  name = "s3-qr-codes"
  role = aws_iam_role.register_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject"
      ]
      Resource = "${aws_s3_bucket.qr_codes.arn}/*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "register_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.register.function_name}"
  retention_in_days = 30
}

# ─────────────────────────────────────────────────────────────────────────────
# SSM Parameter — check-in staff secret (SecureString)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "checkin_secret" {
  name        = "/ugsec-ecuador/checkin/staff-secret"
  description = "Staff authentication secret for check-in portal"
  type        = "SecureString"
  value       = var.checkin_secret

  tags = {
    Component = "checkin-api"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda — check-in handler (event day QR validation)
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "checkin_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/checkin"
  output_path = "${path.module}/../lambda/checkin.zip"
}

resource "aws_lambda_function" "checkin" {
  function_name    = "${var.project_name}-checkin"
  role             = aws_iam_role.register_lambda.arn
  filename         = data.archive_file.checkin_lambda.output_path
  source_code_hash = data.archive_file.checkin_lambda.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME             = aws_dynamodb_table.registrations.name
      ALLOWED_ORIGIN         = "https://register.awssecurityecuador.com"
      CHECKIN_SECRET_SSM_ARN = aws_ssm_parameter.checkin_secret.name
    }
  }
}

resource "aws_cloudwatch_log_group" "checkin_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.checkin.function_name}"
  retention_in_days = 30
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway (HTTP API v2)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "register" {
  name          = "${var.project_name}-register-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://register.awssecurityecuador.com"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type", "x-checkin-secret"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "register" {
  api_id                 = aws_apigatewayv2_api.register.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.register.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "register" {
  api_id    = aws_apigatewayv2_api.register.id
  route_key = "POST /api/register"
  target    = "integrations/${aws_apigatewayv2_integration.register.id}"
}

resource "aws_apigatewayv2_integration" "checkin" {
  api_id                 = aws_apigatewayv2_api.register.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.checkin.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "checkin" {
  api_id    = aws_apigatewayv2_api.register.id
  route_key = "POST /api/checkin"
  target    = "integrations/${aws_apigatewayv2_integration.checkin.id}"
}

resource "aws_apigatewayv2_route" "attendees" {
  api_id    = aws_apigatewayv2_api.register.id
  route_key = "GET /api/attendees"
  target    = "integrations/${aws_apigatewayv2_integration.checkin.id}"
}

resource "aws_apigatewayv2_stage" "register" {
  api_id      = aws_apigatewayv2_api.register.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 20
  }
}

resource "aws_lambda_permission" "register_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.register.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.register.execution_arn}/*/*"
}

resource "aws_lambda_permission" "checkin_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.checkin.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.register.execution_arn}/*/*"
}

# ─────────────────────────────────────────────────────────────────────────────
# Static site — register.awssecurityecuador.com
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "register" {
  bucket = "${var.project_name}-register-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "register" {
  bucket                  = aws_s3_bucket.register.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "register" {
  bucket = aws_s3_bucket.register.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "register" {
  bucket = aws_s3_bucket.register.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "register" {
  bucket     = aws_s3_bucket.register.id
  depends_on = [aws_cloudfront_distribution.register]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.register.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.register.arn }
      }
    }]
  })
}

# ── ACM certificate ──────────────────────────────────────────────────────────
resource "aws_acm_certificate" "register" {
  provider          = aws.us_east_1
  domain_name       = "register.awssecurityecuador.com"
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "register_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.register.domain_validation_options :
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

resource "aws_acm_certificate_validation" "register" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.register.arn
  validation_record_fqdns = [for r in aws_route53_record.register_cert_validation : r.fqdn]
}

# ── CloudFront with API origin + S3 origin ───────────────────────────────────
resource "aws_cloudfront_origin_access_control" "register" {
  name                              = "${var.project_name}-register-oac"
  description                       = "OAC for register.awssecurityecuador.com"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "register" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Registration form — register.awssecurityecuador.com"
  default_root_object = "index.html"
  aliases             = ["register.awssecurityecuador.com"]
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  # S3 origin (static site)
  origin {
    domain_name              = aws_s3_bucket.register.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.register.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.register.id
  }

  # API Gateway origin (registration endpoint)
  origin {
    domain_name = replace(aws_apigatewayv2_api.register.api_endpoint, "https://", "")
    origin_id   = "API-${aws_apigatewayv2_api.register.id}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default behavior — serve from S3
  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "S3-${aws_s3_bucket.register.id}"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # CORS-S3Origin
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.block_dotfiles.arn
    }
  }

  # API behavior — route /api/* to API Gateway
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "API-${aws_apigatewayv2_api.register.id}"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    viewer_protocol_policy   = "https-only"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
  }

  # NOTE: Do NOT add a custom_error_response for 404 -> /index.html here.
  # It is distribution-wide and intercepts the check-in/register API's
  # legitimate 404 JSON responses (e.g. "Registro no encontrado"), replacing
  # them with the HTML index page (200). That breaks res.json() in the
  # check-in frontend and surfaces a misleading "Error de conexión".
  # Missing static objects return 403 (private S3 + OAC), not 404, so the
  # static site does not need this fallback.

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["EC", "US", "PE", "CO", "CL", "AR", "UY"]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.register.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.register]
}

# ── Route53 records ──────────────────────────────────────────────────────────
resource "aws_route53_record" "register_a" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "register.awssecurityecuador.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.register.domain_name
    zone_id                = aws_cloudfront_distribution.register.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "register_aaaa" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "register.awssecurityecuador.com"
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.register.domain_name
    zone_id                = aws_cloudfront_distribution.register.hosted_zone_id
    evaluate_target_health = false
  }
}

# ── IAM permissions for deploy role ──────────────────────────────────────────
resource "aws_iam_role_policy" "deploy_register_s3" {
  name = "s3-register-rw"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource = [aws_s3_bucket.register.arn, "${aws_s3_bucket.register.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "deploy_register_cf" {
  name = "cloudfront-invalidate-register"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
      Resource = aws_cloudfront_distribution.register.arn
    }]
  })
}
