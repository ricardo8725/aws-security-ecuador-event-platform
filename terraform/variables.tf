variable "aws_region" {
  description = "AWS region for primary resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for local development (leave empty in CI/CD)"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project identifier used for resource naming"
  type        = string
  # Set in terraform.tfvars, e.g. "mysecurity-event"
}

variable "domain_name" {
  description = "Custom domain for the CloudFront distribution"
  type        = string
  # Set in terraform.tfvars, e.g. "www.example.com"
}

variable "hosted_zone_name" {
  description = "Route53 hosted zone name (must already exist)"
  type        = string
  # Set in terraform.tfvars, e.g. "example.com"
}

variable "github_org" {
  description = "GitHub organization or username that owns the repo"
  type        = string
  # Set in terraform.tfvars, e.g. "your-github-username"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  # Set in terraform.tfvars, e.g. "your-repo-name"
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
