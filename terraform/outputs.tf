output "role_arn" {
  value = aws_iam_role.ci.arn
}

output "ecr_registry" {
  value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "github_variables" {
  description = "Run these to configure the repository variables"
  value       = <<-EOT
    gh variable set AWS_ROLE_ARN       --repo ${var.github_repo} --body "${aws_iam_role.ci.arn}"
    gh variable set AWS_ACCOUNT_ID     --repo ${var.github_repo} --body "${local.account_id}"
    gh variable set AWS_REGION         --repo ${var.github_repo} --body "${var.region}"
    gh variable set AWS_REPLICA_REGION --repo ${var.github_repo} --body "${local.replicate ? var.replica_region : ""}"
    gh variable set ECR_PREFIX         --repo ${var.github_repo} --body "${var.prefix}"
  EOT
}
