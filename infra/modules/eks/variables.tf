variable "project"     { type = string }
variable "environment" { type = string }

variable "vpc_id" { type = string }

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "cluster_version" {
  type    = string
  default = "1.33"
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 8
}

variable "node_desired_size" {
  type    = number
  default = 4
}