data "aws_caller_identity" "current" {}

# ── Custom security response headers policy (includes CSP) ───────────────────
# Replaces AWS managed SecurityHeadersPolicy (67f7725c…) which lacks CSP.
# script-src/style-src require 'unsafe-inline' because Tailwind CDN injects
# inline styles and requires an inline config block. Revisit when migrating
# to a build step (remove CDN + add nonce-based CSP).

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${var.project_name}-security-headers"

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
      frame_option = "SAMEORIGIN"
      override     = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    content_security_policy {
      # Tailwind Play CDN requires 'unsafe-eval' (uses new Function() for JIT compilation)
      # and 'unsafe-inline' (injects <style> tags). To remove these, migrate to a
      # build step that generates a static tailwind.min.css and serves it from /css/.
      content_security_policy = "default-src 'self'; script-src 'self' https://cdn.tailwindcss.com https://challenges.cloudflare.com 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: blob: https:; connect-src 'self' https://challenges.cloudflare.com; form-action 'self'; base-uri 'self'; object-src 'none'; frame-src https://challenges.cloudflare.com; frame-ancestors 'self';"
      override                = true
    }
  }
}

# ── Origin Access Control (OAC) — modern replacement for OAI ─────────────────

resource "aws_cloudfront_origin_access_control" "website" {
  name                              = "${var.project_name}-oac"
  description                       = "OAC for ${var.domain_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront Function — block dotfiles (defense in depth) ──────────────────
# Returns 403 for any path segment starting with a dot (e.g. /.gitignore,
# /.env, /.git/config, /foo/.bar). Prevents serving sensitive dotfiles even
# if one accidentally ends up in the S3 bucket. Viewer-request, ~0ms, free.

resource "aws_cloudfront_function" "block_dotfiles" {
  name    = "${var.project_name}-block-dotfiles"
  runtime = "cloudfront-js-2.0"
  comment = "Return 403 for any path segment starting with a dot"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var uri = event.request.uri;
      if (/(^|\/)\.[^\/]/.test(uri)) {
        return {
          statusCode: 403,
          statusDescription: 'Forbidden',
          headers: { 'cache-control': { value: 'no-store' } }
        };
      }
      return event.request;
    }
  EOT
}

# ── CloudFront distribution ───────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "AWS UG Security Ecuador — ${var.domain_name}"
  default_root_object = "index.html"
  aliases             = [var.domain_name]
  price_class         = "PriceClass_100" # US, Canada, Europe (cheapest)
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.website.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.website.id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # AWS managed: CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    # AWS managed: CORS-S3Origin
    origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"

    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.block_dotfiles.arn
    }
  }

  # 404 fallback — serve index.html for missing routes.
  # Note: no 403 fallback, so CloudFront geo-restriction (which returns 403)
  # actually blocks disallowed countries instead of serving index.html.
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
    acm_certificate_arn      = aws_acm_certificate_validation.website.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.website]
}
