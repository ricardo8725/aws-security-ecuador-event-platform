# ============================================================================
# CERTIFICATES — PDF certificate storage and delivery
# Private S3 bucket + OAC + CloudFront (separate from qr-codes, zero impact)
# Triggered manually from admin dashboard after event.
# ============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# S3 — certificate PDF storage (private, OAC-only access)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "certificates" {
  bucket = "${var.project_name}-certificates-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "certificates" {
  bucket                  = aws_s3_bucket.certificates.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "certificates" {
  bucket = aws_s3_bucket.certificates.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "certificates" {
  bucket = aws_s3_bucket.certificates.id

  rule {
    id     = "expire-certificates"
    status = "Enabled"
    # Keep certificates for 2 years after the event
    expiration { days = 730 }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudFront OAC — signs requests from CF to the private S3 bucket
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "certificates" {
  name                              = "${var.project_name}-certificates-oac"
  description                       = "OAC for certificates PDF bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudFront distribution — serves PDFs via unguessable UUID paths
# Geo whitelist mirrors qr-codes: EC + countries where email proxies fetch
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "certificates" {
  enabled         = true
  comment         = "Certificate PDFs — AWS GenAI Security Day 2026"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    domain_name              = aws_s3_bucket.certificates.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.certificates.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.certificates.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.certificates.id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    # Cache PDFs for 1 day — they don't change after generation
    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 86400
  }

  restrictions {
    # Broad whitelist so email link clicks work from any country
    # (attendees may open their email from abroad)
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["EC", "US", "IE", "NL", "GB", "DE", "BR", "CL", "CO", "MX", "PE", "AR", "UY"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 bucket policy — only CloudFront OAC can read objects
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket_policy" "certificates" {
  bucket     = aws_s3_bucket.certificates.id
  depends_on = [aws_cloudfront_distribution.certificates]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.certificates.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.certificates.arn }
      }
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda — certificates generator
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "certificates_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/certificates"
  output_path = "${path.module}/../lambda/certificates.zip"
}

resource "aws_iam_role" "certificates_lambda" {
  name = "${var.project_name}-certificates-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "certificates_lambda_basic" {
  role       = aws_iam_role.certificates_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "certificates_lambda_dynamo" {
  name = "dynamodb-certificates"
  role = aws_iam_role.certificates_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:Query",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
      ]
      Resource = [
        aws_dynamodb_table.registrations.arn,
        "${aws_dynamodb_table.registrations.arn}/index/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "certificates_lambda_s3" {
  name = "s3-certificates-put"
  role = aws_iam_role.certificates_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:HeadObject"]
      Resource = "${aws_s3_bucket.certificates.arn}/*"
    }]
  })
}

resource "aws_iam_role_policy" "certificates_lambda_ses" {
  name = "ses-send-certificate"
  role = aws_iam_role.certificates_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
      Condition = {
        StringEquals = { "ses:FromAddress" = "noreply@awssecurityecuador.com" }
      }
    }]
  })
}

resource "aws_lambda_function" "certificates" {
  function_name    = "${var.project_name}-certificates"
  role             = aws_iam_role.certificates_lambda.arn
  filename         = data.archive_file.certificates_lambda.output_path
  source_code_hash = data.archive_file.certificates_lambda.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  # PDF generation takes longer than a typical API call; allow up to 5 min
  # for generating all 400 certificates in a single batch invocation.
  timeout     = 300
  memory_size = 512

  environment {
    variables = {
      TABLE_NAME       = aws_dynamodb_table.registrations.name
      CERT_BUCKET      = aws_s3_bucket.certificates.id
      CERT_CDN_DOMAIN  = aws_cloudfront_distribution.certificates.domain_name
      SES_FROM_ADDRESS = "AWS UG Security Ecuador <noreply@awssecurityecuador.com>"
      EVENT_NAME       = "AWS GenAI Security Day 2026"
      EVENT_DATE       = "Guayaquil, Ecuador  ·  18 de Julio de 2026"
      EVENT_ID         = "aws-gen-ai-security-day-2026"
      ALLOWED_ORIGIN   = "https://admin.awssecurityecuador.com"
    }
  }
}

resource "aws_cloudwatch_log_group" "certificates_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.certificates.function_name}"
  retention_in_days = 30
}

# ─────────────────────────────────────────────────────────────────────────────
# API Gateway — reuse admin API gateway to invoke certificates Lambda
# Route: POST /api/certificates/generate  (JWT-protected, admins only)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_integration" "certificates" {
  api_id                 = aws_apigatewayv2_api.admin.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.certificates.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "certificates_generate" {
  api_id             = aws_apigatewayv2_api.admin.id
  route_key          = "POST /api/certificates/generate"
  target             = "integrations/${aws_apigatewayv2_integration.certificates.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.admin_jwt.id
}

resource "aws_apigatewayv2_route" "certificates_status" {
  api_id             = aws_apigatewayv2_api.admin.id
  route_key          = "GET /api/certificates/status"
  target             = "integrations/${aws_apigatewayv2_integration.certificates.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.admin_jwt.id
}

resource "aws_lambda_permission" "certificates_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.certificates.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.admin.execution_arn}/*/*"
}
