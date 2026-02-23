# ============================================================================
# DATABASE MODULE VARIABLES
# ============================================================================

variable "project_id" {
  description = "GCP project ID where Cloud SQL instance will be created"
  type        = string
}

variable "region" {
  description = "GCP region for Cloud SQL instance"
  type        = string
}

variable "db_password" {
  description = "MySQL password for the application database user"
  type        = string
  sensitive   = true
}

variable "network_id" {
  description = "VPC network ID where Cloud SQL will be placed on private IP"
  type        = string
}
