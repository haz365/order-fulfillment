terraform {
  backend "s3" {
    bucket         = "order-fulfillment-tfstate-989346120260"
    key            = "addons/terraform.tfstate"
    region         = "eu-west-2"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:eu-west-2:989346120260:key/9215e38f-01a6-4590-86c1-29b6ba893c9f"
    dynamodb_table = "order-fulfillment-tfstate-lock"
  }
}