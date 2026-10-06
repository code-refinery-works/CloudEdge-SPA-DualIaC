variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "Project identifier (used as resource name prefix)"
  type        = string
  default     = "myapp"
}

variable "env" {
  description = "Deployment environment (dev / prod)"
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod."
  }
}

variable "domain_name" {
  description = "Apex domain name for the SPA (e.g. example.com)"
  type        = string
}

variable "hosted_zone_name" {
  description = "Route 53 hosted zone name (e.g. example.com)"
  type        = string
}