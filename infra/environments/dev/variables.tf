variable "mongodb_password" {
  description = "MongoDB admin password"
  type        = string
  sensitive   = true
}

variable "use_existing_vpc" {
  description = "Whether to use an existing VPC instead of creating a new one"
  type        = bool
  default     = false
}

variable "existing_vpc_name" {
  description = "Name of existing VPC to use when use_existing_vpc is true"
  type        = string
  default     = ""
}