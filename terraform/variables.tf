variable "region" {
  description = "Primary ECR region"
  type        = string
  default     = "eu-central-1"
}

variable "replica_region" {
  description = "Replica region for the replication test. Empty string disables replication."
  type        = string
  default     = "eu-west-1"
}

variable "github_repo" {
  description = "owner/repo allowed to assume the CI role"
  type        = string
  default     = "zkovac-devops/ecr-oci-poc"
}

variable "prefix" {
  description = "Prefix for all ECR repositories of this PoC"
  type        = string
  default     = "poc"
}

variable "create_github_oidc_provider" {
  description = "false if the account already has an OIDC provider for token.actions.githubusercontent.com"
  type        = bool
  default     = true
}

variable "manage_replication" {
  description = <<-EOT
    The ECR replication configuration is ONE resource per account and region.
    Applying it REPLACES any existing replication rules in the account.
    Set to false if the account already uses ECR replication.
  EOT
  type        = bool
  default     = true
}
