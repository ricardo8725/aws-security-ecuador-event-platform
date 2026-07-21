# ── GitHub Actions OIDC Provider (reusing existing) ──────────────────────────

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

# ── Deploy Role (S3 sync + CloudFront invalidation) ───────────────────────────
# Used by GitHub Actions to sync website files and invalidate CloudFront cache

resource "aws_iam_role" "github_actions_deploy" {
  name        = "${var.project_name}-github-deploy"
  description = "GitHub Actions deploy role for ${var.github_org}/${var.github_repo}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy_s3" {
  name = "s3-website-rw"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource = [aws_s3_bucket.website.arn, "${aws_s3_bucket.website.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "deploy_cloudfront" {
  name = "cloudfront-invalidate"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
      Resource = aws_cloudfront_distribution.website.arn
    }]
  })
}

resource "aws_iam_role_policy" "deploy_ssm" {
  name = "ssm-manage-secrets"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:PutParameter",
        "ssm:GetParameter",
        "ssm:DeleteParameter",
        "ssm:DescribeParameters",
        "ssm:GetParametersByPath",
        "ssm:AddTagsToResource",
        "ssm:ListTagsForResource"
      ]
      Resource = "arn:aws:ssm:us-east-1:*:parameter/ugsec-ecuador/*"
    }]
  })
}
