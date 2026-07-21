terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # S3 backend with DynamoDB locking
  # Bucket and DynamoDB table created manually before first deployment
  backend "s3" {
    bucket         = "awssecurity-ecuador-tfstate-ec2026"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "awssecurity-ecuador-tflock"
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project    = var.project_name
      ManagedBy  = "terraform"
      Repository = "github.com/${var.github_org}/${var.github_repo}"
    }
  }
}

# US East 1 — required for ACM certificates used with CloudFront
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
