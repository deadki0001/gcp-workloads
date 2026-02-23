# ============================================================================
# ROOT VARIABLES
# ============================================================================

# The GCP project where all workload resources will be deployed.
# This is the prod-workloads-lz-001 project created by the landing zone
# project factory, sitting inside the Production folder.
variable "project_id" {
  description = "GCP project ID for workload deployment"
  type        = string
  default     = "prod-workloads-lz-001"
}

# Region must match the org policy restriction set in the landing zone.
# The org policy blocks deployment outside europe-locations.
variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "europe-west1"
}

# Billing account passed in via GitHub secret.
# Required to enable APIs on the workloads project.
variable "billing_account" {
  description = "GCP Billing Account ID"
  type        = string
  default     = "01A0CA-FB334A-076A53"
}

# Database root password passed in via GitHub secret.
# Never hardcoded - always injected at runtime.
variable "db_password" {
  description = "MySQL root password for Cloud SQL instance"
  type        = string
  sensitive   = true
}