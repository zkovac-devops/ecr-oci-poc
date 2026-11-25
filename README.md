# ecr-oci-poc

End-to-end test of the **AWS ECR as an OCI registry** design on github.com, before rolling it out on GHES.

| Production | In this PoC |
|---|---|
| GHES OIDC (`github.tools.sap/_services/token`) | GitHub OIDC (`token.actions.githubusercontent.com`) |
| Artifactory | `ghcr.io/zkovac-devops/ecr-oci-poc/...` |
| In-house Vault, Transit engine | Vault dev server as a service container (key lives only for one run) |
| Gardener shoot + ESO | kind cluster, pull secret created from `aws ecr get-login-password` |

## What the pipeline proves

`.github/workflows/publish-and-verify.yml`, job **publish**:

1. Builds a multi-arch image (amd64 + arm64) and pushes it to ghcr.
2. Signs it **once** with cosign via **Vault Transit** (`hashivault://cosign`), using a token limited to the `cosign-sign` policy from the design. No upload to the public Rekor (`--tlog-upload=false`).
3. Logs in to AWS via **OIDC → STS** (no static keys).
4. Copies image + signature to ECR with **`regctl image copy --digest-tags`**, checks the digest is identical and runs `cosign verify` against ECR.
5. Copies the same image **without** the signature to `poc/apps/poc-unsigned` and checks it does **not** verify.
6. Packages the Helm chart, pushes it to ghcr (OCI), signs it, copies it to ECR `poc/helm/poc-app`, verifies.
7. Waits until **ECR replication** has carried the signature tag to the replica region and verifies the signature there.

Job **e2e** (kind cluster):

8. Installs **Sigstore policy-controller** with a `ClusterImagePolicy` (public key only, `mode: enforce`).
9. A pod with the **signed** image from ECR is admitted and starts (pull secret works).
10. A pod with the **unsigned** image is **rejected** at admission.
11. Installs **Flux**, which pulls the chart from ECR (`HelmRepository type: oci`), **verifies its cosign signature** (`SourceVerified=True`) and deploys it. The deployment's pod passes policy-controller too.

## Setup

### 1. AWS (test account)

You need AWS credentials in a test account that can create IAM roles, an IAM OIDC provider and ECR resources (e.g. an admin role in a sandbox account).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Two things to check in `terraform.tfvars` before applying:

- `create_github_oidc_provider`: set to `false` if the account already has an IAM OIDC provider for `token.actions.githubusercontent.com` (only one per account is allowed). Check with:

  ```bash
  aws iam list-open-id-connect-providers
  ```

- `manage_replication`: the ECR replication configuration is **one resource per account**. Applying it **replaces existing replication rules**. Set to `false` if the account already uses ECR replication (the replica check is then skipped).

  ```bash
  aws ecr describe-registry --region eu-central-1
  ```

```bash
terraform init
```

```bash
terraform apply
```

It creates: the GitHub OIDC provider, 3 ECR repositories under `poc/`, replication `eu-central-1 → eu-west-1` for `poc/`, a repository creation template in the replica region, and the IAM role `gha-ecr-oci-poc` (trust limited to this repository).

### 2. Repository variables (no secrets needed)

`terraform output -raw github_variables` prints the commands:

```bash
terraform output -raw github_variables
```

They set `AWS_ROLE_ARN`, `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_REPLICA_REGION`, `ECR_PREFIX`. You can also set them in **Settings → Secrets and variables → Actions → Variables**.

### 3. Run

Push to `main` or run the workflow manually (**Actions → publish-and-verify → Run workflow**).

```bash
gh workflow run publish-and-verify --repo zkovac-devops/ecr-oci-poc
```

## Cleanup

```bash
cd terraform && terraform destroy
```

Repositories created by replication in the replica region are not managed by Terraform:

```bash
for r in poc/apps/poc-app poc/apps/poc-unsigned poc/helm/poc-app; do aws ecr delete-repository --region eu-west-1 --repository-name "$r" --force; done
```

Packages in ghcr: **Profile/Org → Packages → ecr-oci-poc/...** → delete.

## Differences from production to keep in mind

- The Vault Transit key is ephemeral here, so the signature can only be verified within the same run (the e2e job gets the public key as an artifact).
- The IAM trust allows any ref of this repo. Production restricts it to `main` and release tags.
- ESO and the Gardener managed issuer are not tested (kind has no public OIDC issuer). Test them in the Gardener PoC.
