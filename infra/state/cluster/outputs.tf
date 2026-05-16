output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_oidc_issuer" {
  value = module.eks.cluster_oidc_issuer
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_issuer_host" {
  value = module.eks.oidc_issuer_host
}

output "node_role_arn" {
  value = module.eks.node_role_arn
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "ecr_registry" {
  value = module.ecr.registry
}

output "kms_key_arn" {
  value = module.eks.kms_key_arn
}

output "ebs_kms_key_arn" {
  value = module.storage.ebs_kms_key_arn
}

output "ebs_kms_key_id" {
  value = module.storage.ebs_kms_key_id
}