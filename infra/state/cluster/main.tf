terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
      StateLayer  = "cluster"
    }
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "order-fulfillment-tfstate-989346120260"
    key    = "network/terraform.tfstate"
    region = "eu-west-2"
  }
}

module "eks" {
  source      = "../../modules/eks"
  project     = "order-fulfillment"
  environment = "dev"

  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.network.outputs.public_subnet_ids

  cluster_version   = "1.33"
  node_min_size     = 2
  node_max_size     = 6
  node_desired_size = 3
}

module "ecr" {
  source      = "../../modules/ecr"
  project     = "order-fulfillment"
  environment = "dev"
}

module "storage" {
  source           = "../../modules/storage"
  cluster_name     = module.eks.cluster_name
  ebs_csi_role_arn = module.eks.ebs_csi_role_arn
}

