variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "network" {
  description = "Shared VPC network name from landing zone"
  type        = string
}

variable "subnetwork" {
  description = "Production subnet name from landing zone"
  type        = string
}