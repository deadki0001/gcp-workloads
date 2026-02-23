# ============================================================================
# NETWORKING MODULE VARIABLES
# ============================================================================

variable "project_id" {
  description = "GCP project ID where networking resources will be created"
  type        = string
}

variable "region" {
  description = "GCP region for networking resources"
  type        = string
}
