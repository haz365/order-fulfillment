terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
  default_tags {
    tags = {
      Project     = "order-fulfillment"
      Environment = "dev"
      ManagedBy   = "terraform"
      StateLayer  = "network"
    }
  }
}

module "vpc" {
  source       = "../../modules/vpc"
  project      = "order-fulfillment"
  environment  = "dev"
  vpc_cidr     = "10.0.0.0/16"
  cluster_name = "order-fulfillment-dev"
}

output "vpc_id"             { value = module.vpc.vpc_id }
output "public_subnet_ids"  { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "vpc_cidr"           { value = module.vpc.vpc_cidr }