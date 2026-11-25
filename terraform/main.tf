data "aws_caller_identity" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  github_issuer   = "token.actions.githubusercontent.com"
  replicate       = var.manage_replication && var.replica_region != ""
  oidc_arn        = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  repo_arn_prefix = "arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.prefix}"

  repositories = {
    app      = "${var.prefix}/apps/poc-app"      # signed image
    unsigned = "${var.prefix}/apps/poc-unsigned" # same digest, no signature -> must be rejected
    chart    = "${var.prefix}/helm/poc-app"      # OCI Helm chart
  }
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
# ECR repositories (same settings as the design: immutable tags except cosign tags)
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
# CI role for GitHub Actions
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
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

    # PoC: any ref of this repo. Production restricts to main + release tags.
    # GitHub may issue the sub claim with immutable IDs
    # (repo:<owner>@<owner_id>/<repo>@<repo_id>:...), so both formats are accepted.
    condition {
      test     = "StringLike"
      variable = "${local.github_issuer}:sub"
      values = compact([
        "repo:${var.github_repo}:*",
        var.github_repo_with_ids != "" ? "repo:${var.github_repo_with_ids}:*" : "",
      ])
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = "gha-ecr-oci-poc"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ci" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # push + pull in the primary region
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
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
      "ecr:ListImages",
    ]
    resources = ["arn:aws:ecr:*:${local.account_id}:repository/${var.prefix}/*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}
