# ============================================================================
# PROVIDER CONFIGURATION
# ============================================================================
# user_project_override and billing_project ensure API calls are billed
# to the correct project, avoiding the quota project errors we experienced
# during landing zone deployment.
provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

# Beta provider required for some GKE features like Workload Identity
# and private cluster configuration
provider "google-beta" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

# ============================================================================
# ENABLE REQUIRED APIS ON WORKLOADS PROJECT
# ============================================================================
# APIs must be enabled on the project where resources will be created,
# not just on the bootstrap project. Think of these as feature switches.

# GKE API - required to create Kubernetes clusters
resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

# Cloud SQL API - required to create managed MySQL instances
resource "google_project_service" "sqladmin" {
  project            = var.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

# Service Networking API - required for Cloud SQL private IP connectivity
# Allows Cloud SQL to sit on your VPC without a public IP
resource "google_project_service" "service_networking" {
  project            = var.project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

# Secret Manager API - required to store database credentials securely
resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# Artifact Registry API - required for GKE nodes to pull container images
resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# ============================================================================
# MODULE CALLS
# ============================================================================
# Each module is a separate concern deployed in dependency order.
# Networking must exist before GKE or Cloud SQL can be created.

module "networking" {
  source     = "./networking"
  project_id = var.project_id
  region     = var.region
}

module "database" {
  source      = "./database"
  project_id  = var.project_id
  region      = var.region
  db_password = var.db_password
  network_id  = module.networking.network_id

  depends_on = [
    google_project_service.sqladmin,
    google_project_service.secretmanager,
    google_project_service.service_networking,
    module.networking
  ]
}

module "gke" {
  source     = "./gke"
  project_id = var.project_id
  region     = var.region
  network    = module.networking.network_name
  subnetwork = module.networking.subnetwork_name

  depends_on = [
    google_project_service.artifactregistry,
    google_project_service.container,
    google_project_service.secretmanager,
    module.database,
    module.networking
  ]
}