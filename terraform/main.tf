data "aws_caller_identity" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  github_issuer   = "token.actions.githubusercontent.com"
  replicate       = var.manage_replication && var.replica_region != ""
  oidc_arn        = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  repo_arn_prefix = "arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.prefix}"

  # Application image repositories are NOT listed here: they are created on first push
  # from the CREATE_ON_PUSH template below (poc/apps/<github repo name>).
  repositories = {
    unsigned = "${var.prefix}/apps/poc-unsigned" # same digest, no signature -> must be rejected
    chart    = "${var.prefix}/helm/poc-app"      # OCI Helm chart
  }

  # Both sub formats GitHub may issue: plain owner/repo and owner@id/repo@id.
  repo_sub_prefixes = compact([
    "repo:${var.github_repo}",
    var.github_repo_with_ids != "" ? "repo:${var.github_repo_with_ids}" : "",
  ])

  # Push role: only jobs running the reusable publish workflow.
  # Requires the repo (or org) OIDC sub template: ["repo", "context", "job_workflow_ref"].
  push_sub_patterns = [
    for p in local.repo_sub_prefixes :
    "${p}:*:job_workflow_ref:*/.github/workflows/${var.publish_workflow_file}@*"
  ]

  # Pull role: any job of the repository (read-only).
  pull_sub_patterns = [for p in local.repo_sub_prefixes : "${p}:*"]

  ecr_settings_lifecycle = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "remove untagged after 14 days"
      selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# GitHub OIDC provider (one per account – reuse it if it already exists)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.github_issuer}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://${local.github_issuer}"
}

# ---------------------------------------------------------------------------
# ECR repositories managed by Terraform (test fixtures only)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  for_each             = local.repositories
  name                 = each.value
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"
  force_delete         = true # PoC: allow terraform destroy with images inside

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

# ---------------------------------------------------------------------------
# Create-on-push: any push to poc/... creates the repository with these settings.
# No per-application Terraform change is needed.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository_creation_template" "create_on_push" {
  prefix               = var.prefix
  applied_for          = ["CREATE_ON_PUSH"]
  description          = "ECR OCI PoC – repositories created on first push"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  encryption_configuration { encryption_type = "AES256" }
  lifecycle_policy = local.ecr_settings_lifecycle
}

# ---------------------------------------------------------------------------
# Replication primary -> replica (only the PoC prefix)
# ---------------------------------------------------------------------------
resource "aws_ecr_replication_configuration" "this" {
  count = local.replicate ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.replica_region
        registry_id = local.account_id
      }
      repository_filter {
        filter      = "${var.prefix}/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

resource "aws_ecr_repository_creation_template" "replica" {
  count = local.replicate ? 1 : 0

  region               = var.replica_region
  prefix               = var.prefix
  applied_for          = ["REPLICATION"]
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  encryption_configuration { encryption_type = "AES256" }
}

# ---------------------------------------------------------------------------
# Push role – only the reusable publish workflow can assume it
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust_push" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.github_issuer}:sub"
      values   = local.push_sub_patterns
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = "gha-ecr-oci-poc"
  assume_role_policy   = data.aws_iam_policy_document.trust_push.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ci" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # push + pull + create-on-push in the primary region
  statement {
    actions = [
      "ecr:CreateRepository",
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = ["${local.repo_arn_prefix}/*"]
  }

  # read-only in the replica region (replication check)
  statement {
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = ["arn:aws:ecr:*:${local.account_id}:repository/${var.prefix}/*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}

# ---------------------------------------------------------------------------
# Pull role – read-only, any job of the repository (stands in for k8s-ecr-pull)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust_pull" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.github_issuer}:sub"
      values   = local.pull_sub_patterns
    }
  }
}

resource "aws_iam_role" "pull" {
  name                 = "gha-ecr-oci-poc-pull"
  assume_role_policy   = data.aws_iam_policy_document.trust_pull.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "pull" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = ["arn:aws:ecr:*:${local.account_id}:repository/${var.prefix}/*"]
  }
}

resource "aws_iam_role_policy" "pull" {
  role   = aws_iam_role.pull.id
  policy = data.aws_iam_policy_document.pull.json
}
