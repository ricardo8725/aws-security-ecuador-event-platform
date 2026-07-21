# ============================================================================
# AISECURITY — Static event website (aisecurity.awssecurityecuador.com)
# ============================================================================

# ── S3 bucket ─────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "aisecurity" {
  bucket = "${var.project_name}-aisecurity-${local.suffix}"
}

resource "aws_s3_bucket_public_access_block" "aisecurity" {
  bucket                  = aws_s3_bucket.aisecurity.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "aisecurity" {
  bucket = aws_s3_bucket.aisecurity.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "aisecurity" {
  bucket = aws_s3_bucket.aisecurity.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "aisecurity" {
  bucket     = aws_s3_bucket.aisecurity.id
  depends_on = [aws_cloudfront_distribution.aisecurity]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.aisecurity.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.aisecurity.arn }
      }
    }]
  })
}

# ── ACM certificate ───────────────────────────────────────────────────────────
resource "aws_acm_certificate" "aisecurity" {
  provider          = aws.us_east_1
  domain_name       = "aisecurity.awssecurityecuador.com"
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "aisecurity_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.aisecurity.domain_validation_options :
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

resource "aws_acm_certificate_validation" "aisecurity" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.aisecurity.arn
  validation_record_fqdns = [for r in aws_route53_record.aisecurity_cert_validation : r.fqdn]
}

# ── CloudFront ────────────────────────────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "aisecurity" {
  name                              = "${var.project_name}-aisecurity-oac"
  description                       = "OAC for aisecurity.awssecurityecuador.com"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "aisecurity" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "AWS GenAI Security Day — aisecurity.awssecurityecuador.com"
  default_root_object = "index.html"
  aliases             = ["aisecurity.awssecurityecuador.com"]
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.aisecurity.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.aisecurity.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.aisecurity.id
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "S3-${aws_s3_bucket.aisecurity.id}"
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

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["EC", "US", "PE", "CO", "CL", "AR", "UY"]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.aisecurity.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.aisecurity]
}

# ── Route53 records ───────────────────────────────────────────────────────────
resource "aws_route53_record" "aisecurity_a" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "aisecurity.awssecurityecuador.com"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.aisecurity.domain_name
    zone_id                = aws_cloudfront_distribution.aisecurity.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "aisecurity_aaaa" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "aisecurity.awssecurityecuador.com"
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.aisecurity.domain_name
    zone_id                = aws_cloudfront_distribution.aisecurity.hosted_zone_id
    evaluate_target_health = false
  }
}

# ── IAM permissions for deploy role ───────────────────────────────────────────
resource "aws_iam_role_policy" "deploy_aisecurity_s3" {
  name = "s3-aisecurity-rw"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource = [aws_s3_bucket.aisecurity.arn, "${aws_s3_bucket.aisecurity.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "deploy_aisecurity_cf" {
  name = "cloudfront-invalidate-aisecurity"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
      Resource = aws_cloudfront_distribution.aisecurity.arn
    }]
  })
}
