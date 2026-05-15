variable "project"           { type = string }
variable "environment"       { type = string }
variable "cluster_name"      { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_issuer_host"  { type = string }
variable "sqs_queue_arn"     { type = string }
variable "sqs_queue_url"     { type = string }