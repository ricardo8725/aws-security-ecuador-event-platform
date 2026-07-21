# ============================================================================
# SPONSORS — Sponsor inquiry page (sponsors.awssecurityecuador.com)
# ============================================================================

# ── Lambda ───────────────────────────────────────────────────────────────────

data "archive_file" "sponsors_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/sponsors"
  output_path = "${path.module}/../lambda/sponsors.zip"
}

resource "aws_iam_role" "sponsors_lambda" {
  name = "${var.project_name}-sponsors-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sponsors_lambda_basic" {
  role       = aws_iam_role.sponsors_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "sponsors_lambda_ses" {
  name = "ses-send"
  role = aws_iam_role.sponsors_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "ses:FromAddress" = "noreply@awssecurityecuador.com"
        }
      }
    }]
  })
}

resource "aws_lambda_function" "sponsors" {
  function_name    = "${var.project_name}-sponsors"
  role             = aws_iam_role.sponsors_lambda.arn
  filename         = data.archive_file.sponsors_lambda.output_path
  source_code_hash = data.archive_file.sponsors_lambda.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      ALLOWED_ORIGIN   = "https://sponsors.awssecurityecuador.com"
      SES_FROM_ADDRESS = "AWS UG Security Ecuador <noreply@awssecurityecuador.com>"
      NOTIFY_EMAIL     = "sponsors@awssecurityecuador.com"
    }
  }
}

resource "aws_cloudwatch_log_group" "sponsors_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.sponsors.function_name}"
  retention_in_days = 30
}

# ── API Gateway ──────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "sponsors" {
  name          = "${var.project_name}-sponsors-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://sponsors.awssecurityecuador.com"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "sponsors" {
  api_id                 = aws_apigatewayv2_api.sponsors.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.sponsors.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "sponsors" {
  api_id    = aws_apigatewayv2_api.sponsors.id
  route_key = "POST /api/sponsor"
  target    = "integrations/${aws_apigatewayv2_integration.sponsors.id}"
}

resource "aws_apigatewayv2_stage" "sponsors" {
  api_id      = aws_apigatewayv2_api.sponsors.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

resource "aws_lambda_permission" "sponsors_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sponsors.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.sponsors.execution_arn}/*/*"
}

# ── S3 bucket ────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "sponsors" {
  bucket = "${var.project_name}-sponsors-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "sponsors" {
  bucket                  = aws_s3_bucket.sponsors.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sponsors" {
  bucket = aws_s3_bucket.sponsors.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "sponsors" {
  bucket     = aws_s3_bucket.sponsors.id
  depends_on = [aws_cloudfront_distribution.sponsors]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.sponsors.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.sponsors.arn } }
    }]
  })
}

# ── ACM certificate ──────────────────────────────────────────────────────────

resource "aws_acm_certificate" "sponsors" {
  provider          = aws.us_east_1
  domain_name       = "sponsors.awssecurityecuador.com"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "sponsors_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.sponsors.domain_validation_options :
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

resource "aws_acm_certificate_validation" "sponsors" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.sponsors.arn
  validation_record_fqdns = [for r in aws_route53_record.sponsors_cert_validation : r.fqdn]
}

# ── CloudFront ───────────────────────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "sponsors" {
  name                              = "${var.project_name}-sponsors-oac"
  description                       = "OAC for sponsors.awssecurityecuador.com"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "sponsors" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Sponsors page — sponsors.awssecurityecuador.com"
  default_root_object = "index.html"
  aliases             = ["sponsors.awssecurityecuador.com"]
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.sponsors.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.sponsors.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.sponsors.id
  }

  origin {
    domain_name = replace(aws_apigatewayv2_api.sponsors.api_endpoint, "https://", "")
    origin_id   = "API-sponsors"
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
    target_origin_id           = "S3-${aws_s3_bucket.sponsors.id}"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.block_dotfiles.arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "API-sponsors"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    viewer_protocol_policy   = "https-only"
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["EC", "US", "PE", "CO", "CL", "AR", "UY"]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.sponsors.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.sponsors]
}

# ── Route53 ──────────────────────────────────────────────────────────────────

resource "aws_route53_record" "sponsors_a" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "sponsors.awssecurityecuador.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.sponsors.domain_name
    zone_id                = aws_cloudfront_distribution.sponsors.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "sponsors_aaaa" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "sponsors.awssecurityecuador.com"
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.sponsors.domain_name
    zone_id                = aws_cloudfront_distribution.sponsors.hosted_zone_id
    evaluate_target_health = false
  }
}

# ── Deploy permissions ───────────────────────────────────────────────────────

resource "aws_iam_role_policy" "deploy_sponsors_s3" {
  name = "s3-sponsors-rw"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource = [aws_s3_bucket.sponsors.arn, "${aws_s3_bucket.sponsors.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "deploy_sponsors_cf" {
  name = "cloudfront-invalidate-sponsors"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
      Resource = aws_cloudfront_distribution.sponsors.arn
    }]
  })
}
