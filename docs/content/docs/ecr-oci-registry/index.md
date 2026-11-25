---
title: "AWS ECR as an OCI registry"
description: "Dual-publishing images and Helm charts to Artifactory and ECR, replication from Frankfurt, OIDC (STS) from GHES, 12h pull tokens for Gardener clusters, and cosign signing (verified by Flux and Sigstore policy-controller)."
date: 2026-11-25
draft: false
tags: ["aws", "ecr", "oci", "helm", "cosign", "gardener", "github-actions", "vault"]
toc: true
weight: 10
---

> **Status:** proposal (draft for review).
> **Goal:** ECR serves as a backup to Artifactory for 6 months. After that we cut over and ECR becomes the primary source of truth.

## TL;DR

| Topic | Decision |
|---|---|
| Primary ECR | `eu-central-1` (Frankfurt), single AWS account |
| Other regions | ECR **cross-region replication** from Frankfurt (prefixes `apps/`, `helm/`, `mirror/`) |
| Publishing | **Build once, sign once**: push and sign in Artifactory, then `regctl image copy --digest-tags` to ECR. Digest and signatures stay identical |
| Helm | OCI in both registries: `helm push` to Artifactory, then the same `regctl` copy to ECR as for images. Consumers: Flux (`HelmRepository type: oci`) and helm CLI |
| Auth CI → AWS | GHES OIDC (`https://github.tools.sap/_services/token`) → `AssumeRoleWithWebIdentity`, 1h session |
| Auth clusters → ECR | ESO `ECRAuthorizationToken` via the shoot's OIDC issuer (~30 shoots). Token valid for 12 h, refreshed every 6 h |
| Many repositories | One push role usable only from the reusable workflow (`job_workflow_ref` in `sub`), ECR repositories **created on first push** ([4.1](#41-rolling-out-to-4050-repositories-reusable-workflows)) |
| Pull-through | ECR **cannot** proxy Artifactory. 3rd-party images go through a curated mirror (`mirror/`) |
| Signatures | **cosign** with a key in **Vault Transit** (`hashivault://cosign`), no upload to the public Rekor |
| Verification | Charts: **Flux natively** (`verify.provider: cosign`). Images: **Sigstore policy-controller** (small admission webhook, cosign only) |

## 1. Architecture

```text
                     ┌──────── Vault (in-house) ───────┐
                     │ Artifactory token, Transit key   │
                     └────────────────▲─────────────────┘
                                      │ hashicorp/vault-action (JWT)
┌──────────── GHES – github.tools.sap (GitHub Actions) ──────────────────────┐
│ build:   buildx ──push──► Artifactory docker-local/<app>@sha256:…           │
│          helm push ──► Artifactory helm-oci-local/<chart>                   │
│ sign:    cosign sign (Vault Transit) ──► tags sha256-<digest>.sig           │
│ publish: regctl image copy --digest-tags ──► ECR eu-central-1               │
│          (image / chart + signatures, identical digest)                     │
└───────┬─────────────────────────────────────────────────────────────────────┘
        │ OIDC id_token (aud=sts.amazonaws.com) → STS → role gha-ecr-push (1h)
        ▼
┌──────────── ECR eu-central-1 (primary) ─────────────┐
│ apps/*  helm/*  mirror/*                             │── replication ──► other AWS regions
└──────────────────────────────────────────────────────┘                        │
                                                                                 │ nearest region
┌──────── Gardener shoot (AWS / Azure / GCP / Converged Cloud) ─────────┐        │
│ ESO → Secret ecr-pull (12h token, refresh 6h)                          │◄───────┘
│ Flux: HelmRepository (OCI) + cosign verification of charts             │
│ Sigstore policy-controller: cosign verification of images at admission │
└────────────────────────────────────────────────────────────────────────┘
```

## 2. Key constraints and decisions

1. **ECR pull-through cache does not support Artifactory as an upstream.** The only supported upstreams are Docker Hub, Quay, `registry.k8s.io`, ECR Public, ghcr.io, GitLab CR, Azure CR and ECR → ECR. Our own images therefore get **pushed to ECR by the pipeline**.
2. **The backup protects runtime, not builds.** When GHES is down we can't build anyway. ECR makes sure clusters can still pull when Artifactory is down.
3. **3rd-party images.** Artifactory caches them today, so they go down with Artifactory. The images clusters actually use (base images, sidecars, operators) are therefore mirrored to `mirror/` by a scheduled workflow. See [section 5.5](#55-mirroring-3rd-party-images).
4. **The 12 h lifetime belongs to the ECR token**, not to the STS session. `GetAuthorizationToken` returns a password valid for 12 h, so a 1h STS session is enough for CI. On clusters, ESO refreshes the token automatically; a static secret would stop working after 12 h.
5. **Replication vs. ECR → ECR pull-through:**

   | | Replication (recommended) | ECR→ECR pull-through |
   |---|---|---|
   | When content is copied | right after the push | on first pull |
   | Available when Frankfurt is down | yes, everything is already in the region | only what has been pulled before |
   | Cosign signatures (`sha256-*.sig` tags) | replicated like regular tags | only when someone pulls them |
   | Existing images | need a backfill (re-push) | automatic |

6. **Helm in ECR is OCI.** A chart `<chart>` under `oci://REG/helm` lives in the repository `helm/<chart>`, so Terraform creates it upfront. Flux reads it via a `HelmRepository` with `type: oci`; people use `helm pull oci://…`.
7. **Cosign is not a CNCF project.** It is Sigstore under OpenSSF (Linux Foundation). The CNCF alternative is the Notary Project (`notation`, on AWS via AWS Signer). We recommend cosign for its ecosystem (Flux, Sigstore policy-controller), Helm OCI support and external keys (Vault Transit, KMS).
8. **Keyless cosign (Fulcio) won't work with GHES.** The public Fulcio only accepts known OIDC issuers (github.com and similar), not `github.tools.sap`. We therefore sign with a **key in Vault Transit** and use `--tlog-upload=false`. Otherwise the names and digests of internal images would end up in the public Rekor log.

## 3. AWS infrastructure (Terraform)

Assumption: AWS provider `~> 6.0`, which supports the resource-level `region` argument. Older versions need provider aliases per region.

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "eu-central-1"
}

data "aws_caller_identity" "current" {}

locals {
  primary_region  = "eu-central-1"
  replica_regions = ["eu-west-1", "us-east-1", "ap-southeast-1"] # based on cluster locations
  account_id      = data.aws_caller_identity.current.account_id

  ghes_issuer = "github.tools.sap/_services/token"
  gh_org      = "my-org"

  apps          = ["app-a", "app-b"]                 # images and charts (chart name = repo name)
  repo_prefixes = ["apps", "helm", "mirror"]

  lifecycle = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "remove untagged after 14 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "keep last 500 images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 500 }
        action       = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# OIDC provider for GHES (GitHub Actions)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "ghes" {
  url            = "https://${local.ghes_issuer}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------------------------------------------------------------------------
# Repositories in the primary region
# IMMUTABLE tags + an exception for cosign tags (sha256-*.sig/.att/.sbom),
# which cosign overwrites when adding another signature.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  for_each             = toset(local.apps)
  name                 = "apps/${each.key}"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_repository" "chart" {
  for_each             = toset(local.apps)
  name                 = "helm/${each.key}"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy     = local.lifecycle
}

# ---------------------------------------------------------------------------
# Replication Frankfurt → other regions
# ---------------------------------------------------------------------------
resource "aws_ecr_replication_configuration" "this" {
  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = local.replica_regions
        content {
          region      = destination.value
          registry_id = local.account_id
        }
      }
      dynamic "repository_filter" {
        for_each = local.repo_prefixes
        content {
          filter      = "${repository_filter.value}/"
          filter_type = "PREFIX_MATCH"
        }
      }
    }
  }
}

# Repository creation templates must exist in the DESTINATION region.
# They configure the repositories that replication creates there.
resource "aws_ecr_repository_creation_template" "replica" {
  for_each = {
    for pair in setproduct(local.replica_regions, local.repo_prefixes) :
    "${pair[0]}/${pair[1]}" => { region = pair[0], prefix = pair[1] }
  }

  region               = each.value.region
  prefix               = each.value.prefix
  applied_for          = ["REPLICATION"]
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  encryption_configuration { encryption_type = "AES256" }
  lifecycle_policy = local.lifecycle
}

# ---------------------------------------------------------------------------
# CI role (GHES → STS)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gha_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.ghes.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.ghes_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # only main and release tags from our org
    condition {
      test     = "StringLike"
      variable = "${local.ghes_issuer}:sub"
      values = [
        "repo:${local.gh_org}/*:ref:refs/heads/main",
        "repo:${local.gh_org}/*:ref:refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "gha_push" {
  name                 = "gha-ecr-push"
  assume_role_policy   = data.aws_iam_policy_document.gha_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "gha_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

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
    ]
    # push to the primary region only – replication fills the rest
    resources = [
      for p in local.repo_prefixes :
      "arn:aws:ecr:${local.primary_region}:${local.account_id}:repository/${p}/*"
    ]
  }
}

resource "aws_iam_role_policy" "gha_push" {
  role   = aws_iam_role.gha_push.id
  policy = data.aws_iam_policy_document.gha_push.json
}

# ---------------------------------------------------------------------------
# Pull role for Gardener shoots (OIDC issuer of each shoot)
# ---------------------------------------------------------------------------
variable "shoot_issuers" {
  description = "Managed service account issuer URLs of the shoots, without https://"
  type        = list(string)
}

resource "aws_iam_openid_connect_provider" "shoot" {
  for_each       = toset(var.shoot_issuers)
  url            = "https://${each.key}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "k8s_trust" {
  dynamic "statement" {
    for_each = aws_iam_openid_connect_provider.shoot
    content {
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [statement.value.arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${statement.key}:aud"
        values   = ["sts.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "${statement.key}:sub"
        values   = ["system:serviceaccount:external-secrets:ecr-puller"]
      }
    }
  }
}

resource "aws_iam_role" "k8s_pull" {
  name               = "k8s-ecr-pull"
  assume_role_policy = data.aws_iam_policy_document.k8s_trust.json
  # the ECR token is valid for 12 h regardless of the session length
  max_session_duration = 3600
}

data "aws_iam_policy_document" "k8s_pull" {
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
    # all regions (primary + replicas)
    resources = [
      for p in local.repo_prefixes :
      "arn:aws:ecr:*:${local.account_id}:repository/${p}/*"
    ]
  }
}

resource "aws_iam_role_policy" "k8s_pull" {
  role   = aws_iam_role.k8s_pull.id
  policy = data.aws_iam_policy_document.k8s_pull.json
}

output "ecr_registry"   { value = "${local.account_id}.dkr.ecr.${local.primary_region}.amazonaws.com" }
```

Notes:

- **Backfill:** replication only carries new pushes. Once replication is on, existing tags need a one-time copy (`regctl image copy` in a loop, see [5.5](#55-mirroring-3rd-party-images)).
- **OIDC `sub` format:** GitHub can issue the `sub` claim with immutable IDs (`repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:...`) instead of `repo:<owner>/<repo>:ref:...`. The PoC on github.com hit exactly this. Check the real claim on GHES (print the decoded token claims in a test workflow) and put the matching pattern into the trust policy.
- **OIDC provider limit** is 100 per account. With ~30 shoots there is plenty of headroom.
- `IMMUTABLE_WITH_EXCLUSION` is a newer ECR feature. If your provider version doesn't support it yet, use `MUTABLE` and enforce immutability in the pipeline (signing by digest).

### 3.1 Where to keep the cosign key

The GHES issuer `https://github.tools.sap/_services/token` is reachable for AWS STS, so direct OIDC works (no Plan B via the Vault AWS secrets engine is needed). Options for the signing key:

| Option | Pros | Cons |
|---|---|---|
| **Vault Transit** (`hashivault://cosign`), **chosen** | The key stays in your Vault and is non-exportable. Auth via the existing `vault-action`. Independent of which registry is primary. Rotation via key versions | Signing depends on Vault availability. The key is protected only by Vault snapshots and backups |
| AWS KMS (`awskms:///alias/cosign-ci`) | Key in an HSM, audit in CloudTrail, 7–30 days protection against deletion | Signing depends on AWS. Extra IAM permissions for CI |
| **Key pair in Vault KV** (`cosign generate-key-pair`) | Simplest, no extra infrastructure | The encrypted private key lands on the runner on every run. Manual rotation |
| **Keyless with a private Sigstore** (own Fulcio + Rekor trusting the GHES issuer) | No keys, identity = workflow and repo | Running a full Sigstore stack. Too much for a 6-month backup |

In every option, verification (Flux, policy-controller) only needs the **public key**, which is stored in the cluster ([5.3](#53-signature-verification)).

Vault setup (one-time):

```bash
vault secrets enable transit
vault write -f transit/keys/cosign type=ecdsa-p256     # exportable=false is the default
```

```hcl
# policy cosign-sign – attach to the existing JWT role for GitHub Actions
path "transit/sign/cosign"    { capabilities = ["update"] }
path "transit/sign/cosign/*"  { capabilities = ["update"] }
path "transit/keys/cosign"    { capabilities = ["read"] }
```

The JWT role that gets `cosign-sign` should have `bound_claims` restricted to `main` and release tags, so arbitrary feature branches can't sign.

Export the public key for clusters once and store it in the GitOps repo (it is public, not a secret):

```bash
VAULT_ADDR=https://vault.example.com cosign public-key --key hashivault://cosign > cosign.pub
```

The Transit key must be covered by Vault backups (snapshots). If it is lost, new images can no longer be signed with the same key and you have to go through a rotation.

## 4. Pipeline (GitHub Actions on GHES)

These actions must be available on GHES (via GitHub Connect or an internal mirror): `hashicorp/vault-action`, `aws-actions/configure-aws-credentials`, `docker/*`, `sigstore/cosign-installer`, `regclient/actions/regctl-installer`, `azure/setup-helm`.

The pipeline assumes the Helm repo in Artifactory is OCI (`helm push`). If it stays a classic repo (`curl -T`), the chart is pushed to ECR directly with `helm push oci://…` and signed there.

`.github/workflows/build-publish.yml`:

```yaml
name: build-publish

on:
  push:
    branches: [main]
    tags: ["v*"]

permissions:
  contents: read
  id-token: write          # OIDC token for Vault (JWT) and AWS (STS)

env:
  AWS_REGION: eu-central-1
  AWS_ROLE_ARN: arn:aws:iam::123456789012:role/gha-ecr-push
  ECR_REG: 123456789012.dkr.ecr.eu-central-1.amazonaws.com
  ART_HOST: artifactory.example.com
  ART_IMG: artifactory.example.com/docker-local
  ART_HELM: artifactory.example.com/helm-oci-local
  COSIGN_KEY: hashivault://cosign       # VAULT_ADDR + VAULT_TOKEN are exported by vault-action
  IMAGE: app-a
  CHART: app-a

jobs:
  build-sign:
    runs-on: [self-hosted, linux]
    outputs:
      tag: ${{ steps.meta.outputs.tag }}
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@v4

      - id: meta
        run: |
          if [ "$GITHUB_REF_TYPE" = "tag" ]; then
            echo "tag=${GITHUB_REF_NAME}" >> "$GITHUB_OUTPUT"
          else
            echo "tag=${GITHUB_SHA::12}" >> "$GITHUB_OUTPUT"
          fi

      - uses: hashicorp/vault-action@v3
        with:
          url: https://vault.example.com
          method: jwt
          role: gha-ci
          exportToken: true    # VAULT_ADDR + VAULT_TOKEN for cosign
          secrets: |
            secret/data/ci/artifactory user  | ARTIFACTORY_USER ;
            secret/data/ci/artifactory token | ARTIFACTORY_TOKEN

      - uses: docker/login-action@v3
        with:
          registry: ${{ env.ART_HOST }}
          username: ${{ env.ARTIFACTORY_USER }}
          password: ${{ env.ARTIFACTORY_TOKEN }}

      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3

      - id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ env.ART_IMG }}/${{ env.IMAGE }}:${{ steps.meta.outputs.tag }}
          provenance: false

      - uses: sigstore/cosign-installer@v3
        with:
          cosign-release: "v2.5.0"    # pinned; cosign v3 changes the default signature format

      - name: Sign in Artifactory (once, by digest)
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
        run: |
          cosign sign --yes --tlog-upload=false --key "$COSIGN_KEY" \
            "$ART_IMG/$IMAGE@$DIGEST"

  publish-ecr:
    needs: build-sign
    runs-on: [self-hosted, linux]
    env:
      TAG: ${{ needs.build-sign.outputs.tag }}
      DIGEST: ${{ needs.build-sign.outputs.digest }}
    steps:
      - uses: hashicorp/vault-action@v3
        with:
          url: https://vault.example.com
          method: jwt
          role: gha-ci
          exportToken: true    # VAULT_ADDR + VAULT_TOKEN for cosign
          secrets: |
            secret/data/ci/artifactory user  | ARTIFACTORY_USER ;
            secret/data/ci/artifactory token | ARTIFACTORY_TOKEN

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.AWS_ROLE_ARN }}
          role-session-name: gha-${{ github.run_id }}-publish
          aws-region: ${{ env.AWS_REGION }}

      - uses: regclient/actions/regctl-installer@main
        # with: { release: "vX.Y.Z" }   # pin to a specific regclient release
      - uses: sigstore/cosign-installer@v3
        with:
          cosign-release: "v2.5.0"

      - name: Login
        run: |
          echo "$ARTIFACTORY_TOKEN" | regctl registry login "$ART_HOST" -u "$ARTIFACTORY_USER" --pass-stdin
          aws ecr get-login-password | regctl registry login "$ECR_REG" -u AWS --pass-stdin
          aws ecr get-login-password | cosign login "$ECR_REG" -u AWS --password-stdin

      - name: Copy image + signatures to ECR
        run: |
          regctl image copy --digest-tags --referrers \
            "$ART_IMG/$IMAGE@$DIGEST" "$ECR_REG/apps/$IMAGE:$TAG"
          test "$(regctl image digest "$ECR_REG/apps/$IMAGE:$TAG")" = "$DIGEST"

      - name: Verify signature in ECR
        run: |
          cosign public-key --key "$COSIGN_KEY" > cosign.pub
          cosign verify --key cosign.pub --insecure-ignore-tlog=true \
            "$ECR_REG/apps/$IMAGE@$DIGEST" > /dev/null

  helm:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: publish-ecr
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/vault-action@v3
        with:
          url: https://vault.example.com
          method: jwt
          role: gha-ci
          exportToken: true    # VAULT_ADDR + VAULT_TOKEN for cosign
          secrets: |
            secret/data/ci/artifactory user  | ARTIFACTORY_USER ;
            secret/data/ci/artifactory token | ARTIFACTORY_TOKEN

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.AWS_ROLE_ARN }}
          role-session-name: gha-${{ github.run_id }}-helm
          aws-region: ${{ env.AWS_REGION }}

      - uses: azure/setup-helm@v4
      - uses: regclient/actions/regctl-installer@main
      - uses: sigstore/cosign-installer@v3
        with:
          cosign-release: "v2.5.0"

      - name: Package + push to Artifactory (OCI)
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          echo "VERSION=$VERSION" >> "$GITHUB_ENV"
          helm package "charts/$CHART" --version "$VERSION" --app-version "$GITHUB_REF_NAME"
          echo "$ARTIFACTORY_TOKEN" | helm registry login "$ART_HOST" -u "$ARTIFACTORY_USER" --password-stdin
          helm push "$CHART-$VERSION.tgz" "oci://$ART_HELM" 2>&1 | tee push.log
          echo "CHART_DIGEST=$(grep -o 'sha256:[a-f0-9]\{64\}' push.log | head -1)" >> "$GITHUB_ENV"

      - name: Sign chart + copy to ECR
        run: |
          echo "$ARTIFACTORY_TOKEN" | cosign login "$ART_HOST" -u "$ARTIFACTORY_USER" --password-stdin
          cosign sign --yes --tlog-upload=false --key "$COSIGN_KEY" "$ART_HELM/$CHART@$CHART_DIGEST"

          echo "$ARTIFACTORY_TOKEN" | regctl registry login "$ART_HOST" -u "$ARTIFACTORY_USER" --pass-stdin
          aws ecr get-login-password | regctl registry login "$ECR_REG" -u AWS --pass-stdin
          regctl image copy --digest-tags \
            "$ART_HELM/$CHART@$CHART_DIGEST" "$ECR_REG/helm/$CHART:$VERSION"
          test "$(regctl image digest "$ECR_REG/helm/$CHART:$VERSION")" = "$CHART_DIGEST"
```

Pipeline notes:

- **Why `regctl`:**
  - `regctl image copy` copies the image and the multi-arch index without a rebuild, so the digest stays identical.
  - The `--digest-tags` flag also carries the cosign tags `sha256-<digest>.sig`. We sign **once** and the signature travels with the image. With `crane` we would have to sign twice or use `cosign copy`.
  - The `--referrers` flag also carries OCI 1.1 referrers (SBOMs, attestations) if you add them later.
- **A copied signature stays valid.** A cosign signature is bound to the digest, not to the registry name. The `Verify signature in ECR` step checks this on every run.
- **ECR replication** carries the signature tags to the other regions like regular tags. The `sha256-*` immutability exception in Terraform allows adding another signature later (e.g. during key rotation).
- For more applications, the jobs become a `matrix` or a reusable workflow (`workflow_call`) in a central repo.

### 4.1 Rolling out to 40–50 repositories (reusable workflows)

Image and chart builds already run in reusable workflows shared by 40–50 repositories in the GHES org. The goal is that **adding a new repository needs no change in AWS**.

**One push role for the whole org, usable only from the reusable workflow.**

- The GitHub OIDC token carries `job_workflow_ref`, e.g. `<org>/ci-workflows/.github/workflows/build-image.yml@refs/tags/v2`.
- AWS IAM can only evaluate `aud` and `sub` for this provider; custom claims are not supported. The **OIDC subject template** puts `job_workflow_ref` into `sub` instead:

  ```bash
  gh api --hostname github.tools.sap -X PUT orgs/<org>/actions/oidc/customization/sub -f 'include_claim_keys[]=repo' -f 'include_claim_keys[]=context' -f 'include_claim_keys[]=job_workflow_ref'
  ```

- The resulting `sub` looks like `repo:<org>/app-x:ref:refs/heads/main:job_workflow_ref:<org>/ci-workflows/.github/workflows/build-image.yml@refs/tags/v2` (verify the exact form by printing the claims once).
- Trust policy of the push role:

  ```hcl
  condition {
    test     = "StringLike"
    variable = "${local.ghes_issuer}:sub"
    values = [
      "repo:${local.gh_org}/*:*:job_workflow_ref:${local.gh_org}/ci-workflows/.github/workflows/build-image.yml@refs/tags/v*",
      "repo:${local.gh_org}/*:*:job_workflow_ref:${local.gh_org}/ci-workflows/.github/workflows/build-chart.yml@refs/tags/v*",
    ]
  }
  ```

- Effect: any repository of the org can push, but **only through the approved workflow at a release tag**. A copied or modified workflow in a PR does not get the role.

> **Caution:** an org-level subject template changes `sub` for **every** OIDC token in the org. Anything that matches on `sub` today (Vault JWT roles with `bound_subject`, other AWS roles) breaks. Audit first, or set the template per repository (`PUT repos/{owner}/{repo}/actions/oidc/customization/sub`, scriptable for 50 repos). New repositories may also get the ID-based format (`<org>@<id>/<repo>@<id>`); cover both in the trust policy until verified.

**Repositories created on first push.**

- ECR creates a repository on the first push when a repository creation template with `applied_for = CREATE_ON_PUSH` matches its prefix. Without a matching template nothing is created, so default settings never appear by accident.
- Templates for `apps` and `helm` carry immutability (with the `sha256-*` exception), encryption, lifecycle and the repository policy. Replication rules filter by prefix, so new repositories replicate automatically.
- The push role additionally needs `ecr:CreateRepository` on `apps/*` and `helm/*`.

```hcl
resource "aws_ecr_repository_creation_template" "create_on_push" {
  for_each             = toset(["apps", "helm"])
  prefix               = each.key
  applied_for          = ["CREATE_ON_PUSH"]
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  encryption_configuration { encryption_type = "AES256" }
  lifecycle_policy = local.lifecycle
}
```

**Naming and isolation.**

- The reusable workflow **derives** the ECR repository from `github.repository` (`apps/<repo>`, or `apps/<repo>/<image>` for several images; `helm/<chart>`). It must not be an input, otherwise repository A could push into `apps/B`.
- With one role, the isolation between repositories relies on the workflow code plus immutable tags. If hard isolation is required, generate **one role per repository** with a Terraform module (`for_each`), each with its own `sub` and `apps/<repo>`; the cost is an onboarding step per repository. Session tags, which would do this more elegantly, are not available from GitHub OIDC tokens.
- The pull side does not change: `k8s-ecr-pull` reads `apps/*` and `helm/*`.

**Changes in the workflows and the repositories.**

- Central repo: ECR steps behind an input `publish-ecr` (default `false` for a gradual rollout); role ARN, registry and region as **org-level variables**; callers reference the workflow by **tag** (`@v2`), which the trust policy matches.
- Each calling repository must grant the OIDC permission, because a reusable workflow cannot get more permissions than its caller:

  ```yaml
  permissions:
    contents: read
    id-token: write
  ```

  If repositories already read Vault via `vault-action` with JWT auth, this is already in place.

| Step | What |
|---|---|
| 1 | Terraform: push role with `job_workflow_ref` trust, `CREATE_ON_PUSH` templates, `ecr:CreateRepository` |
| 2 | Audit what in the org depends on the `sub` format; decide org-level or per-repository subject template |
| 3 | Reusable workflow `v2` with ECR steps behind `publish-ecr` |
| 4 | Pilot on 2–3 repositories: check `sub`, create-on-push and replication |
| 5 | Default `publish-ecr: true`, bulk bump of the workflow version (+ `id-token: write` where missing) |

> **PoC:** tested in `zkovac-devops/ecr-oci-poc` with a repository-level subject template, see the [PoC report](../ecr-oci-poc-report/).

## 5. Kubernetes (Gardener shoots)

### 5.1 Shoot OIDC issuer

Enable the **managed service account issuer** on every shoot. AWS STS needs publicly reachable discovery and JWKS endpoints.

```yaml
apiVersion: core.gardener.cloud/v1beta1
kind: Shoot
metadata:
  annotations:
    authentication.gardener.cloud/issuer: managed
```

Add the issuer URL (format `https://discovery.<landscape>/projects/<project>/shoots/<uid>/issuer`) to `var.shoot_issuers` in Terraform. This depends on your Gardener landscape supporting it (gardener-discovery-server).

### 5.2 ECR pull secret via External Secrets Operator

Each shoot pulls from the **nearest** ECR region (`region` in the generator + `image.registry` in the values).

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ecr-puller
  namespace: external-secrets
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/k8s-ecr-pull
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: ClusterGenerator
metadata:
  name: ecr
spec:
  kind: ECRAuthorizationToken
  generator:
    ecrAuthorizationTokenSpec:
      region: eu-west-1                 # replica nearest to the shoot
      auth:
        jwt:
          serviceAccountRef:
            name: ecr-puller
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: ecr-pull
spec:
  namespaceSelectors:
    - matchLabels:
        ecr-pull: "enabled"
  externalSecretSpec:
    refreshInterval: 6h                 # token valid for 12 h → 6 h buffer for outages
    target:
      name: ecr-pull
      template:
        type: kubernetes.io/dockerconfigjson
        data:
          .dockerconfigjson: |
            {"auths":{"{{ .proxy_endpoint | replace "https://" "" }}":{"auth":"{{ printf "%s:%s" .username .password | b64enc }}"}}}
    dataFrom:
      - sourceRef:
          generatorRef:
            apiVersion: generators.external-secrets.io/v1alpha1
            kind: ClusterGenerator
            name: ecr
```

During the backup phase, pods (or the namespace's default ServiceAccount) have **both** secrets:

```yaml
imagePullSecrets:
  - name: artifactory-pull
  - name: ecr-pull
```

**Failover** (Artifactory → ECR) means changing one value in GitOps:

```yaml
global:
  imageRegistry: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/apps   # previously artifactory.example.com/docker-local
```

> Check the exact `ClusterGenerator` and `jwt` auth syntax for your ESO version. Older versions use a namespaced `ECRAuthorizationToken` in each namespace.

### 5.3 Signature verification

Kyverno is too large a policy engine for this purpose. Alternatives with native cosign support:

| Tool | What it verifies | What you install | Note |
|---|---|---|---|
| **Flux** (source-controller) | Helm charts and OCI artifacts that Flux fetches | nothing, you already run Flux | Does not check images running in pods |
| **Sigstore policy-controller** | images at pod creation | one admission webhook | From the cosign authors. Opt-in per namespace, `warn` / `enforce` mode |
| Ratify + OPA Gatekeeper | images | Gatekeeper + Ratify | cosign and notation. Only makes sense if you already run Gatekeeper |
| Connaisseur | images | one admission webhook | cosign and Notary v1. Smaller community; check project activity before choosing |
| Kyverno | images + general policies | a full policy engine | Rejected as too large |
| CRI-O `policy.json` | signatures at pull time on the node | nothing (part of the runtime) | Gardener nodes run containerd, so not applicable |

**Recommendation:** Flux verifies charts natively ([5.4](#54-flux-and-helm-cli)) and **Sigstore policy-controller** verifies images.

Install policy-controller via the Helm chart `policy-controller` from `https://sigstore.github.io/helm-charts`. It only checks namespaces labelled `policy.sigstore.dev/include: "true"`, so the rollout can be gradual.

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: ecr-apps-signed
spec:
  mode: warn                     # after cutover: enforce
  images:
    - glob: "*.dkr.ecr.*.amazonaws.com/apps/**"
    - glob: "artifactory.example.com/docker-local/**"
  authorities:
    - name: ci-vault-transit
      key:
        hashAlgorithm: sha256
        data: |
          -----BEGIN PUBLIC KEY-----
          <contents of cosign.pub, see 3.1>
          -----END PUBLIC KEY-----
```

To fetch signatures, policy-controller uses the same `imagePullSecrets` as the pod (`ecr-pull`). The public key is static, so verification needs no access to AWS or Vault.

#### How verification works in the cluster

The cluster **never contacts Vault** or AWS for verification. It only uses the public key and the signature stored in the registry next to the image.

```text
CI (GHES)                         Registry (regional ECR replica)           Cluster
─────────                         ───────────────────────────────           ───────
cosign sign ──Vault Transit──►    app-a@sha256:abc   (image)
  signs digest sha256:abc         sha256-abc.sig     (signature, same digest)
                                          ▲
                                          │ 2. fetches image manifest + .sig (ecr-pull secret)
kubectl apply / Flux ──► API server ──► policy-controller webhook
                                          │ 1. tag → digest
                                          │ 3. verifies signature with the public key from ClusterImagePolicy
                                          ▼
                                   allow / deny (in warn mode: warning only)
```

1. When a pod is created, the API server calls the policy-controller webhook, which resolves the tag to a digest.
2. It fetches the signature `sha256-<digest>.sig` from the same repository. The signatures got there via `regctl --digest-tags` and ECR replication.
3. It verifies the signature with the public key from the `ClusterImagePolicy`. If it doesn't match, the pod is rejected in `enforce` mode and created with a warning in `warn` mode.

Flux does the same for charts: source-controller fetches the chart and its `.sig`, verifies them with the key from `Secret cosign-pub`, and does not update the chart on failure (`HelmChart` is not `Ready`, the verification error is in its status).

Result: verification also works in Azure, GCP and Converged Cloud shoots without access to Vault, without Rekor, and even during a Vault outage (only signing is blocked then).

**Key rotation** (`vault write -f transit/keys/cosign/rotate`):

1. cosign signs with the new key version from now on. Export the new public key with `cosign public-key`.
2. Add a second `authority` with the new key to the `ClusterImagePolicy`, and a second `*.pub` file to `Secret cosign-pub` (Flux uses all `.pub` keys in the secret). Existing images stay valid.
3. Once nothing in the registry is signed only with the old key (or after re-signing), remove the old key.

> **Signatures without Rekor:** signatures have no entry in the public Rekor (`--tlog-upload=false`). Both tools skip the transparency log for key-based verification: policy-controller when the `key` authority has no `ctlog` configured, Flux whenever a public key is used (checked in the sources of policy-controller and source-controller). Confirmed end-to-end in the PoC repo `zkovac-devops/ecr-oci-poc`: policy-controller admitted the signed image and rejected the unsigned one, Flux reported `SourceVerified=True`, and the signature tag replicated to `eu-west-1` in about 10 s.

### 5.4 Flux and helm CLI

Flux reads charts from the nearest ECR region and verifies their signatures natively:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: apps
  namespace: flux-system
spec:
  type: oci
  url: oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/helm
  interval: 10m
  secretRef:
    name: ecr-pull                 # ESO secret (namespace flux-system has label ecr-pull=enabled)
---
apiVersion: v1
kind: Secret
metadata:
  name: cosign-pub
  namespace: flux-system
stringData:
  cosign.pub: |
    -----BEGIN PUBLIC KEY-----
    <contents of cosign.pub, see 3.1>
    -----END PUBLIC KEY-----
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: app-a
  namespace: apps
spec:
  interval: 10m
  chart:
    spec:
      chart: app-a
      version: "1.4.x"
      sourceRef:
        kind: HelmRepository
        name: apps
        namespace: flux-system
      verify:
        provider: cosign
        secretRef:
          name: cosign-pub
```

**Chart failover:** change `spec.url` of the `HelmRepository` (Artifactory ↔ ECR, or another region) in the GitOps repo.

**helm CLI locally:** people need read-only AWS access (e.g. via IAM Identity Center):

```bash
aws ecr get-login-password --region eu-central-1 \
  | helm registry login 123456789012.dkr.ecr.eu-central-1.amazonaws.com -u AWS --password-stdin
```

```bash
helm pull oci://123456789012.dkr.ecr.eu-central-1.amazonaws.com/helm/app-a --version 1.4.2
```

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  123456789012.dkr.ecr.eu-central-1.amazonaws.com/helm/app-a:1.4.2
```

The helm CLI itself doesn't verify cosign signatures, so verification is a separate step.

### 5.5 Mirroring 3rd-party images

The recommended approach is a curated list of the images clusters actually use. A scheduled workflow copies them to `mirror/`, from where they replicate to all regions. They also get scanned.

```yaml
# .github/workflows/mirror.yml (excerpt)
on:
  schedule: [{ cron: "17 3 * * *" }]
  workflow_dispatch: {}
# ... vault + aws login + regctl registry login as above ...
      - name: Mirror
        run: |
          while read -r src dst; do
            regctl image copy --digest-tags "$src" "$ECR_REG/mirror/$dst"
          done < mirror-list.txt
```

```text
# mirror-list.txt  (source = Artifactory remote, destination = ECR mirror/)
artifactory.example.com/dockerhub-remote/library/nginx:1.27.3   nginx:1.27.3
artifactory.example.com/quay-remote/prometheus/node-exporter:v1.8.2   node-exporter:v1.8.2
```

The same workflow also handles the one-time **backfill** of your applications' existing tags. Optionally, you can also enable ECR pull-through rules (Docker Hub, Quay, `registry.k8s.io`, ghcr.io). Those are regional, so they must be set up in every region, and pull-through repositories are not replicated.

## 6. Rollout

| Phase | Duration | What |
|---|---|---|
| 0 – Infra | 1–2 weeks | Terraform (ECR, replication, IAM, OIDC). Vault Transit key and policy. First `AssumeRoleWithWebIdentity` from GHES |
| 1 – Dual-publish | 2–4 weeks | Workflow in all repos (reusable workflow). Backfill of existing tags. Signing. policy-controller in `warn` mode |
| 2 – Backup | ~6 months | ESO `ecr-pull` in all shoots. Quarterly **failover drill** (switch `global.imageRegistry` on a test cluster). 3rd-party mirror |
| 3 – Cutover | 1–2 weeks | ECR primary in values. policy-controller `enforce`. Flux `HelmRepository` switched to ECR |
| 4 – Decommission | as needed | Push to Artifactory optional or turned off. Artifactory stays as a remote cache or is retired |

## 7. Costs (rough)

- **Storage:** billed per GB in each region separately (a replica is another copy).
- **Cross-region replication:** data transfer between AWS regions.
- **Pulls from Azure / GCP / Converged Cloud:** AWS **internet egress**. With large images and frequent scale-ups this is the biggest item. The Gardener `registry-cache` extension (pull-through cache inside the shoot) reduces it.

## 8. Open items

| # | Item | Status |
|---|---|---|
| 1 | GHES OIDC issuer `https://github.tools.sap/_services/token` | confirmed. Validate with the first `AssumeRoleWithWebIdentity` in the PoC |
| 2 | Number of shoots | ~30, within the limit of 100 OIDC providers per account |
| 3 | List of AWS regions for replicas and mapping of Azure / GCP / CC clusters | to be provided |
| 4 | Is the Artifactory Helm repo OCI (`helm push`) or classic (`curl -T`)? | open. Pipeline assumes OCI |
| 5 | Location of the cosign key | Vault Transit ([3.1](#31-where-to-keep-the-cosign-key)), to be confirmed by the architect |
| 6 | Availability of actions on GHES (vault, aws, cosign, regctl, helm) | to be checked |
| 7 | AWS account | single for now |
| 8 | Human access to ECR for helm CLI (IAM Identity Center, read-only role) | open |
| 9 | PoC (`zkovac-devops/ecr-oci-poc`): policy-controller and Flux verify signatures without a Rekor entry. Replication carries `sha256-*.sig` tags | **passed** on 2026-11-25 (github.com + AWS test account, run 45613631712) |

## 9. References

PoC report with the AWS inventory and a step-by-step walkthrough: [ECR OCI PoC report](../ecr-oci-poc-report/).


**Signing and verification**

| Component | Links |
|---|---|
| cosign | [GitHub](https://github.com/sigstore/cosign) · [Key management (KMS, Vault)](https://docs.sigstore.dev/cosign/key_management/overview/) |
| Sigstore policy-controller | [GitHub](https://github.com/sigstore/policy-controller) · [Docs](https://docs.sigstore.dev/policy-controller/overview/) · [Helm charts](https://github.com/sigstore/helm-charts) |
| Flux | [HelmRepository (OCI)](https://fluxcd.io/flux/components/source/helmrepositories/) · [HelmChart (verification)](https://fluxcd.io/flux/components/source/helmcharts/) · [HelmRelease](https://fluxcd.io/flux/components/helm/helmreleases/) |
| HashiCorp Vault | [Transit secrets engine](https://developer.hashicorp.com/vault/docs/secrets/transit) · [vault-action](https://github.com/hashicorp/vault-action) |
| Alternatives considered | [Ratify](https://github.com/ratify-project/ratify) · [Connaisseur](https://github.com/sse-secure-systems/connaisseur) · [Notary Project](https://notaryproject.dev/) |

**Registry and copying**

| Component | Links |
|---|---|
| regclient / regctl | [GitHub](https://github.com/regclient/regclient) · [Docs](https://regclient.org/) · [`regctl image` (copy, digest-tags)](https://regclient.org/cli/regctl/image/) |
| Amazon ECR | [Replication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/replication.html) · [Repository creation templates](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html) · [Tag mutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html) · [Pull through cache](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html) · [OCI artifacts / Helm](https://docs.aws.amazon.com/AmazonECR/latest/userguide/push-oci-artifact.html) · [Registry authentication (12 h token)](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html) · [Basic scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning-basic.html) |

**Identity**

| Component | Links |
|---|---|
| AWS IAM | [OIDC identity providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html) · [Service control policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) |
| GitHub Actions OIDC | [Configuring OIDC in AWS](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services) · [OIDC reference (claims, `sub` format)](https://docs.github.com/en/actions/reference/security/oidc) · [configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials) |

**Kubernetes / Gardener**

| Component | Links |
|---|---|
| External Secrets Operator | [ECR authorization token generator](https://external-secrets.io/latest/api/generator/ecr/) |
| Gardener | [Shoot service accounts (managed issuer)](https://github.com/gardener/gardener/blob/master/docs/usage/security/shoot_serviceaccounts.md) · [Discovery server](https://github.com/gardener/gardener-discovery-server) · [Registry cache extension](https://github.com/gardener/gardener-extension-registry-cache) |
