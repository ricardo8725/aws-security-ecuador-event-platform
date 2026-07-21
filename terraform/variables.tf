variable "aws_region" {
  description = "AWS region for primary resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for local development (leave empty in CI/CD)"
  type        = string
  default     = "servicescloudsec-admin"
}

variable "project_name" {
  description = "Project identifier used for resource naming"
  type        = string
  default     = "awssecurity-ecuador"
}

variable "domain_name" {
  description = "Custom domain for the CloudFront distribution"
  type        = string
  default     = "www.awssecurityecuador.com"
}

variable "hosted_zone_name" {
  description = "Route53 hosted zone name (must already exist)"
  type        = string
  default     = "awssecurityecuador.com"
}

variable "github_org" {
  description = "GitHub organization or username that owns the repo"
  type        = string
  default     = "ricardo8725"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "awssecurityecuador"
}

variable "checkin_secret" {
  description = "Secret token for staff check-in portal authentication (stored in SSM, no default)"
  type        = string
  sensitive   = true
}

variable "turnstile_secret" {
  description = "Cloudflare Turnstile secret key for CAPTCHA validation"
  type        = string
  sensitive   = true
}
