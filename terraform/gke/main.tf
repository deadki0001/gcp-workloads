# ============================================================================
# GKE MODULE — GOOGLE KUBERNETES ENGINE CLUSTER
# ============================================================================
# Creates a private GKE cluster in the shared VPC prod-subnet.
# Private means worker nodes have no public IP addresses.
# The control plane (API server) is managed by Google.
#
# Key features enabled:
# - Workload Identity: pods authenticate to GCP APIs without service account keys
# - Private nodes: worker nodes sit entirely within the private VPC
# - Shielded nodes: hardware-level security for node VMs
#
# AWS equivalent: EKS private cluster with managed node group,
# IRSA for pod IAM, and VPC CNI plugin.

# ============================================================================
# GKE SERVICE ACCOUNT
# ============================================================================
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes-sa"
  display_name = "GKE Node Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "gke_nodes_artifact_registry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ============================================================================
# CLOUD SQL AUTH PROXY SERVICE ACCOUNT
# ============================================================================
resource "google_service_account" "cloudsql_proxy" {
  account_id   = "cloudsql-proxy-sa"
  display_name = "Cloud SQL Auth Proxy Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "cloudsql_proxy_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloudsql_proxy.email}"
}

# ============================================================================
# WORKLOAD IDENTITY BINDING
# ============================================================================
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.cloudsql_proxy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/k8s-cloudsql-proxy]"

  depends_on = [google_container_cluster.primary]
}

# ============================================================================
# SECRET MANAGER ACCESS FOR API PODS
# ============================================================================
resource "google_secret_manager_secret_iam_member" "api_secret_access" {
  project   = var.project_id
  secret_id = "db-password"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudsql_proxy.email}"
}

# ============================================================================
# GKE CLUSTER
# ============================================================================
resource "google_container_cluster" "primary" {
  name     = "workloads-gke-001"
  location = var.region
  project  = var.project_id

  # Set to false for learning environment so destroy and recreate works cleanly
  # In production this should be true to prevent accidental deletion
  deletion_protection = false

  network    = "projects/networking-host-lz-001/global/networks/shared-vpc"
  subnetwork = "projects/networking-host-lz-001/regions/${var.region}/subnetworks/prod-subnet"

  remove_default_node_pool = true
  initial_node_count       = 1

  # ========================================================================
  # IP ALLOCATION — REQUIRED FOR SHARED VPC
  # ========================================================================
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # ========================================================================
  # NETWORKING
  # ========================================================================
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # ========================================================================
  # WORKLOAD IDENTITY
  # ========================================================================
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # ========================================================================
  # SECURITY
  # ========================================================================
  enable_shielded_nodes = true

  # ========================================================================
  # ADDONS
  # ========================================================================
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  # ========================================================================
  # LOGGING AND MONITORING
  # ========================================================================
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"
}

# ============================================================================
# NODE POOL
# ============================================================================
# Using free-tier friendly settings:
# - e2-micro: smallest machine type, free tier eligible
# - pd-standard: standard HDD avoids SSD quota limits
# - 10GB disk: minimum size, keeps standard disk quota usage minimal
# - max 1 node: prevents unexpected scaling costs
resource "google_container_node_pool" "primary_nodes" {
  name     = "primary-node-pool"
  location = var.region
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 1
  }

  node_config {
    machine_type = "e2-micro"
    disk_type    = "pd-standard"
    disk_size_gb = 10

    service_account = google_service_account.gke_nodes.email

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    tags = ["gke-node"]

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE cluster name — used in kubectl get-credentials command"
}

output "cluster_endpoint" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE control plane endpoint — used by kubectl and CI/CD"
  sensitive   = true
}

output "cloudsql_proxy_sa_email" {
  value       = google_service_account.cloudsql_proxy.email
  description = "Cloud SQL proxy service account — annotated on k8s-cloudsql-proxy service account"
}