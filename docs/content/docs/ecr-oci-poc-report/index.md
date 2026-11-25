---
title: "ECR OCI PoC report"
description: "End-to-end proof of concept of the ECR OCI registry design: what was created in AWS, how each pipeline step works, how it compares with the design, and links to all components."
date: 2026-11-25
draft: false
tags: ["aws", "ecr", "oci", "cosign", "vault", "policy-controller", "flux", "poc"]
toc: true
weight: 20
---

> **Result:** passed on 2026-11-25. Base run [45613631712](https://github.com/zkovac-devops/ecr-oci-poc/actions/runs/45613631712); reusable workflow + create-on-push run [45688988329](https://github.com/zkovac-devops/ecr-oci-poc/actions/runs/45688988329). Repository [zkovac-devops/ecr-oci-poc](https://github.com/zkovac-devops/ecr-oci-poc).
> **Design:** [AWS ECR as an OCI registry](../ecr-oci-registry/).

## Summary

| What was tested | Result |
|---|---|
| CI logs in to AWS via OIDC → STS, no static keys | passed |
| cosign signs via **Vault Transit** with a token limited to the `cosign-sign` policy | passed |
| `regctl image copy --digest-tags` carries image **and** signature to ECR, identical digest | passed |
| The same image copied **without** the signature does not verify | passed (rejected as expected) |
| Helm chart (OCI) signed and copied to ECR | passed |
| ECR replication carries the signature tag to `eu-west-1` | passed, ~10 s after push, verifies in the replica |
| policy-controller admits the signed image from ECR | passed, pod pulled from ECR |
| policy-controller rejects the unsigned image | passed |
| Flux verifies the chart signature and deploys it | passed, `SourceVerified=True` |
| Push role usable **only** from the reusable workflow (`job_workflow_ref` in `sub`) | passed |
| A job outside the reusable workflow is denied the push role | passed (`Not authorized to perform sts:AssumeRoleWithWebIdentity`) |
| ECR repository `poc/apps/ecr-oci-poc` **created on first push** with the template settings | passed (`IMMUTABLE_WITH_EXCLUSION`, AES256) |
| e2e uses a separate read-only pull role | passed |

How the production components were replaced in the PoC:

| Production | PoC |
|---|---|
| GHES (`github.tools.sap`) | github.com |
| Artifactory | ghcr.io |
| In-house Vault, Transit engine | Vault 1.18.1 dev server as a GitHub Actions service container |
| Gardener shoot + External Secrets Operator | kind cluster, pull secret created from `aws ecr get-login-password` |
| Dedicated AWS account | management account of a fresh AWS organization |

## 1. What was created in AWS

All resources are in account **`724875924481`**.

### 1.1 Managed by Terraform

State after the reusable-workflow test (the first run used `poc/apps/poc-app` from Terraform; it was removed when create-on-push was introduced).

| # | Resource | Region | Key settings |
|---|---|---|---|
| 1 | IAM OIDC provider `token.actions.githubusercontent.com` | global | audience `sts.amazonaws.com` |
| 2 | IAM role `gha-ecr-oci-poc` (push) | global | trusts only this OIDC provider; `aud = sts.amazonaws.com`; `sub` must match `<repo prefix>:*:job_workflow_ref:*/.github/workflows/reusable-publish.yml@*` for both `repo:zkovac-devops/ecr-oci-poc` and `repo:zkovac-devops@17102879/ecr-oci-poc@1471640445`; max session 1 h |
| 3 | Inline policy of the push role (`terraform-…`) | – | `ecr:GetAuthorizationToken`; `ecr:CreateRepository` + push + pull on `poc/*` in eu-central-1; read on `poc/*` in all regions |
| 3a | IAM role `gha-ecr-oci-poc-pull` + inline policy | global | any job of the repository (`<repo prefix>:*`); read-only on `poc/*` in all regions. Stand-in for `k8s-ecr-pull` |
| 3b | Repository creation template, prefix `poc`, `applied_for = CREATE_ON_PUSH` | eu-central-1 | `IMMUTABLE_WITH_EXCLUSION` (`sha256-*`), AES256, lifecycle: untagged expire after 14 days |
| 5 | ECR repository `poc/apps/poc-unsigned` | eu-central-1 | same image without signature (negative test only) |
| 6 | ECR repository `poc/helm/poc-app` | eu-central-1 | Helm chart (OCI) |
| 7 | Replication configuration (one per registry) | eu-central-1 | rule: prefix `poc/` → `eu-west-1`, same account |
| 8 | Repository creation template, prefix `poc` | eu-west-1 | `applied_for = REPLICATION`, same settings as the primary repos |

Repositories 4–6 share these settings: `IMMUTABLE_WITH_EXCLUSION` with exclusion `sha256-*` (cosign signature tags), scan on push, AES256 encryption, `force_delete` (PoC only, so they can be deleted with content).

### 1.2 Created outside Terraform

| What | Where | Why |
|---|---|---|
| Repository `poc/apps/ecr-oci-poc` | eu-central-1 | **created on first push** from the CREATE_ON_PUSH template (name derived from the GitHub repository) |
| Repository `poc/apps/poc-app` | eu-west-1 | replica from the first run; its primary was removed from Terraform. Delete during cleanup |
| 3 repositories `poc/...` | **eu-west-1** | created by replication from the creation template. Not in Terraform state, `terraform destroy` does not remove them |
| Image index + 2 manifests (amd64, arm64), tag `<git sha 12>` | `poc/apps/poc-app` (+ replica) | one set per successful run |
| Signature tag `sha256-<digest>.sig` | `poc/apps/poc-app`, `poc/helm/poc-app` (+ replicas) | cosign signature copied with `regctl --digest-tags` |
| Same images without `.sig` | `poc/apps/poc-unsigned` (+ replica) | negative test |
| Chart `0.1.<run number>` + `.sig` | `poc/helm/poc-app` (+ replica) | one per successful run |
| Basic scan findings | ECR | scan on push |
| CloudTrail event history | eu-central-1 | `AssumeRoleWithWebIdentity`, `PutImage`, … useful to see who pushed what |
| Terraform state | CloudShell `~/ecr-oci-poc/terraform/terraform.tfstate` | needed for `terraform destroy` |

Outside AWS: packages in ghcr.io and five repository variables in GitHub (`AWS_ROLE_ARN`, `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_REPLICA_REGION`, `ECR_PREFIX`). No secrets are stored in GitHub.

## 2. How to verify

**Console:**

- IAM → Identity providers
- IAM → Roles → `gha-ecr-oci-poc` → *Trust relationships* and *Permissions*
- ECR → Private registry → Repositories (switch between eu-central-1 and eu-west-1)
- ECR → Private registry → Settings → *Replication* and *Repository creation templates* (template is in eu-west-1)

**CLI (CloudShell):**

```bash
aws iam list-open-id-connect-providers
```

```bash
aws iam get-role --role-name gha-ecr-oci-poc --query 'Role.[AssumeRolePolicyDocument,MaxSessionDuration]'
```

```bash
aws iam get-role-policy --role-name gha-ecr-oci-poc --policy-name "$(aws iam list-role-policies --role-name gha-ecr-oci-poc --query 'PolicyNames[0]' --output text)"
```

```bash
aws ecr describe-repositories --region eu-central-1 --query 'repositories[].[repositoryName,imageTagMutability]' --output table
```

```bash
aws ecr describe-repositories --region eu-west-1 --query 'repositories[].[repositoryName,imageTagMutability]' --output table
```

```bash
aws ecr describe-registry --region eu-central-1 --query replicationConfiguration
```

```bash
aws ecr describe-repository-creation-templates --region eu-west-1
```

```bash
aws ecr list-images --region eu-west-1 --repository-name poc/apps/poc-app --query 'imageIds[].imageTag' --output table
```

```bash
cd ~/ecr-oci-poc/terraform && terraform state list
```

## 3. Comparison with the design

**Matches the design:**

- OIDC → STS with a 1 h session, no static keys in CI.
- Push only to the primary region; other regions are filled by ECR replication filtered by prefix.
- Repository creation templates live in the **destination** region.
- Immutable tags with the `sha256-*` exception for cosign; scan on push.
- `apps/` and `helm/` split.
- Signing key in Vault Transit, non-exportable, CI token limited to `cosign-sign`.
- Build once, sign once, copy with `regctl --digest-tags`.
- Verification in the cluster only with the public key: policy-controller for images, Flux for charts, no Rekor.

**Deviations:**

| PoC | Design / production | Reason |
|---|---|---|
| Management account of the organization | Dedicated account (or prod / non-prod) | A Free plan project account blocks ECR with an AWS-managed SCP |
| Prefix `poc/` | `apps/`, `helm/`, `mirror/` without prefix | Isolation of the test |
| Trust allows any ref of the repo | Only `main` and release tags | Simpler testing |
| `sub` in two formats (plain and with IDs) | Check the real format on GHES | github.com issued `sub` with owner and repo IDs |
| github.com, ghcr.io, Vault dev | GHES, Artifactory, in-house Vault | Stand-ins |
| No lifecycle policy | Untagged 14 days, keep 500 | Short-lived PoC |
| `force_delete = true` | Not set | Easy cleanup |
| One replica (`eu-west-1`) | Regions near the clusters | Test |
| `poc-unsigned` repo, read access in replica | Not present | Negative test and replication check |
| **No `k8s-ecr-pull` role, no shoot OIDC providers** | Present | kind has no public OIDC issuer; the e2e pull secret was created with the CI role's credentials |
| No ESO, no `mirror/` workflow | Present | Not covered by this PoC |

## 4. Pipeline walkthrough

Workflow: [`.github/workflows/publish-and-verify.yml`](https://github.com/zkovac-devops/ecr-oci-poc/blob/main/.github/workflows/publish-and-verify.yml).

### 4.1 Job `publish`

1. **Check repository variables.** Fails fast if `AWS_ROLE_ARN`, `AWS_ACCOUNT_ID` or `AWS_REGION` is missing.
2. **Install tools.** Pinned `regctl v0.11.7` and `cosign v2.5.0`.
3. **Vault Transit key + signing token.**
   - The Vault dev server runs as a service container. The step enables the transit engine and creates the non-exportable key `cosign` (`ecdsa-p256`).
   - It writes the `cosign-sign` policy (`update` on `transit/sign/cosign`, `read` on `transit/keys/cosign`) and issues a **token with only that policy**. cosign never sees the root token, so the exact policy from the design is exercised.
4. **Build.** `docker buildx` for amd64 and arm64 pushes an image index with two manifests to ghcr.io (Artifactory stand-in). The output is the index digest.
5. **Sign once.** `cosign sign --tlog-upload=false --key hashivault://cosign <ghcr>@<digest>`.
   - cosign sends the digest to the Vault sign API; the private key never leaves Vault.
   - The signature is stored as tag `sha256-<digest>.sig` next to the image. Nothing goes to the public Rekor log.
   - The public key is exported to `cosign.pub` and handed to the e2e job as an artifact.
6. **Show OIDC token claims.** Diagnostic step that prints `iss`, `aud`, `sub` (never the token). It revealed the ID-based `sub` format.
7. **configure-aws-credentials.** GitHub issues an OIDC token with `aud=sts.amazonaws.com`. STS validates its signature against the issuer's JWKS and the trust policy conditions, then returns 1 h credentials for `gha-ecr-oci-poc`.
8. **Registry logins.** regctl to ghcr.io with `GITHUB_TOKEN`; regctl and cosign to ECR with `aws ecr get-login-password` (this ECR token is valid for 12 h).
9. **Copy image + signature to ECR.**
   - `regctl image copy --digest-tags --referrers` copies the index, both manifests, the layers and the `.sig` tag.
   - The step checks the digest in ECR is **identical** and runs `cosign verify` against ECR. This proves that signing once is enough.
10. **Negative test.** The same image is copied without `--digest-tags` to `poc-unsigned`. `cosign verify` must fail there, because signatures are stored per repository.
11. **Helm chart.** `helm package` (version `0.1.<run>`), `helm push` to ghcr.io, digest taken from the push output, signed via Vault, copied with `regctl` to `poc/helm/poc-app:<version>`, digest and signature verified.
12. **Replication.** Polls `eu-west-1` every 10 s (max 10 minutes) for `sha256-<digest>.sig`, then runs `cosign verify` against the replica. The tag arrived after ~10 s.

### 4.2 Job `e2e` (kind as a stand-in for a Gardener shoot)

1. **Setup.** AWS credentials, kind cluster, helm and flux CLI.
2. **Namespaces + ECR pull secret.**
   - `ecr-pull` (dockerconfigjson) in `poc` and `flux-system` from `get-login-password`. In production ESO creates it and refreshes it every 6 h.
   - Namespace `poc` gets label `policy.sigstore.dev/include=true` (opt-in for policy-controller); its default ServiceAccount gets `imagePullSecrets`.
3. **policy-controller.** Installed from the Sigstore Helm chart. `ClusterImagePolicy` in `mode: enforce` for `<ECR>/poc/apps/**` with one authority: the public key from Vault, no `ctlog`, so no Rekor lookup.
4. **Signed image is admitted.** `kubectl run` with the tag. The webhook resolves the tag to a digest, fetches `.sig` from ECR using `ecr-pull`, verifies it with the key. The pod starts and kubelet pulls the image from ECR, pinned to `@sha256:…`.
5. **Unsigned image is rejected.** For `poc-unsigned` there is no `.sig`, so the webhook denies the pod.
6. **Flux.**
   - Installs `source-controller` and `helm-controller`, creates secret `cosign-pub`.
   - `HelmRepository` (type `oci`) points to `oci://<ECR>/poc/helm` and authenticates with `ecr-pull`. `HelmRelease` has `verify.provider: cosign`.
   - Flux pulled the chart, verified its signature (`SourceVerified=True`) and deployed the Deployment to `poc`. Its pod also passed policy-controller.
7. **Diagnostics.** Runs only on failure: pods, events, policy-controller and Flux logs.

## 5. Findings

1. **Reusable workflow trust works.** With the repository OIDC subject template `["repo","context","job_workflow_ref"]`, `sub` was `repo:zkovac-devops@17102879/ecr-oci-poc@1471640445:ref:refs/heads/main:job_workflow_ref:zkovac-devops/ecr-oci-poc/.github/workflows/reusable-publish.yml@refs/heads/main`. The API `GET …/actions/oidc/customization/sub` also returns `use_immutable_subject` and the exact `sub_claim_prefix`, which is the quickest way to learn the format before writing a trust policy.

2. **GitHub OIDC `sub` can contain immutable IDs.** github.com issued `repo:zkovac-devops@17102879/ecr-oci-poc@1471640445:ref:refs/heads/main` instead of `repo:zkovac-devops/ecr-oci-poc:ref:refs/heads/main`. The trust policy must match the real format. **Action:** print the claims once on GHES before writing the production trust policy.
3. **AWS Free plan project accounts cannot use ECR.** An AWS-managed SCP denies `ecr:*`. Upgrading and activating advanced features is irreversible; the PoC then ran in the organization's management account, where SCPs do not apply.
4. **Signatures without Rekor work.** policy-controller skips the transparency log when a `key` authority has no `ctlog`; Flux skips it whenever a public key is used. Confirmed in the sources and end to end.
5. **Signature tags replicate like any other tag.** ~10 s from Frankfurt to Ireland; the signature verifies in the replica.
6. **Signatures are per repository.** The same digest in another repository without `.sig` does not verify, so `--digest-tags` (or re-signing) is required for every copy.
7. **Flux creates the `HelmChart` asynchronously.** Automation must wait for the object to exist before waiting for readiness.
8. **policy-controller webhook needs a moment after `helm install --wait`.** Applying a `ClusterImagePolicy` immediately can fail with `failed calling webhook`; retry until it succeeds.

## 6. Not covered, to test on Gardener

- External Secrets Operator `ECRAuthorizationToken` with the shoot's managed service account issuer.
- `k8s-ecr-pull` role with one OIDC provider per shoot.
- Pulling from Azure / GCP / Converged Cloud shoots (egress, latency).
- `mirror/` workflow for 3rd-party images and backfill of existing tags.
- GHES specifics: `sub` format, availability of actions, Artifactory Helm repo type (OCI or classic).

## 7. Cleanup

In CloudShell of account `724875924481`:

```bash
cd ~/ecr-oci-poc/terraform && terraform destroy
```

`poc/apps/ecr-oci-poc` in eu-central-1 was created on push and is not in Terraform state:

```bash
aws ecr delete-repository --region eu-central-1 --repository-name poc/apps/ecr-oci-poc --force
```

```bash
for r in poc/apps/poc-app poc/apps/ecr-oci-poc poc/apps/poc-unsigned poc/helm/poc-app; do aws ecr delete-repository --region eu-west-1 --repository-name "$r" --force; done
```

Packages in ghcr.io: GitHub profile → Packages → delete `ecr-oci-poc/*`.

## 8. References

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
