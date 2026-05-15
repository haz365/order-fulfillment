output "repository_urls" {
  value = { for k, v in aws_ecr_repository.service : k => v.repository_url }
}

output "repository_arns" {
  value = { for k, v in aws_ecr_repository.service : k => v.arn }
}

output "registry" {
  value = split("/", values(aws_ecr_repository.service)[0].repository_url)[0]
}