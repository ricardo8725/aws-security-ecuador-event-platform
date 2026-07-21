data "aws_route53_zone" "main" {
  name         = var.hosted_zone_name
  private_zone = false
}

# Alias A (IPv4) → CloudFront: free DNS resolution, no CNAME lookup cost.
# CloudFront hosted zone ID is always Z2FDTNDATAQYW2 for all distributions.
resource "aws_route53_record" "website_a" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}

# Alias AAAA (IPv6) → CloudFront: required because is_ipv6_enabled = true
resource "aws_route53_record" "website_aaaa" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}
