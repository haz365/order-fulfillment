variable "project"     { type = string }
variable "environment" { type = string }

variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids"  { type = list(string) }

variable "cluster_version" {
  type    = string
  default = "1.33"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium", "t3.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 6
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "cluster_endpoint_private_access_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/8"]
}