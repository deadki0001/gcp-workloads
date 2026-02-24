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
# Dedicated service account for GKE nodes.
# Nodes run as this identity, not the default compute service account.
# Follows least-privilege — only has permissions nodes actually need.
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes-sa"
  display_name = "GKE Node Service Account"
  project      = var.project_id
}

# Allow GKE nodes to pull container images from Artifact Registry
resource "google_project_iam_member" "gke_nodes_artifact_registry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Allow GKE nodes to write logs to Cloud Logging
resource "google_project_iam_member" "gke_nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Allow GKE nodes to write metrics to Cloud Monitoring
resource "google_project_iam_member" "gke_nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ============================================================================
# CLOUD SQL AUTH PROXY SERVICE ACCOUNT
# ============================================================================
# Separate service account used by the Cloud SQL Auth Proxy sidecar.
# The proxy authenticates to Cloud SQL using this identity instead of
# a database password passed over the network.
# AWS equivalent: IRSA role bound to a specific Kubernetes service account.
resource "google_service_account" "cloudsql_proxy" {
  account_id   = "cloudsql-proxy-sa"
  display_name = "Cloud SQL Auth Proxy Service Account"
  project      = var.project_id
}

# Allow the proxy service account to connect to Cloud SQL instances
resource "google_project_iam_member" "cloudsql_proxy_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloudsql_proxy.email}"
}

# ============================================================================
# WORKLOAD IDENTITY BINDING
# ============================================================================
# Binds the Kubernetes service account (k8s-cloudsql-proxy) in the
# default namespace to the GCP service account (cloudsql-proxy-sa).
# When the proxy pod runs, it automatically gets GCP credentials
# without needing any keys or secrets.
#
# AWS equivalent: Annotating a Kubernetes service account with
# eks.amazonaws.com/role-arn to enable IRSA pod-level IAM.
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.cloudsql_proxy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/k8s-cloudsql-proxy]"

  depends_on = [google_container_cluster.primary]
}

# ============================================================================
# SECRET MANAGER ACCESS FOR API PODS
# ============================================================================
# Allow the API pods to read the database password from Secret Manager
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

  network    = "projects/networking-host-lz-001/global/networks/shared-vpc"
  subnetwork = "projects/networking-host-lz-001/regions/${var.region}/subnetworks/prod-subnet"


  # Remove the default node pool immediately after cluster creation
  # We define our own node pool below with specific configuration
  # This is the recommended pattern for production GKE clusters
  remove_default_node_pool = true
  initial_node_count       = 1

  # ========================================================================
  # NETWORKING
  # ========================================================================
  # Place the cluster in the shared VPC prod-subnet
  # The cluster uses the subnet created by the landing zone
  network    = var.network
  subnetwork = var.subnetwork

  # Private cluster — nodes have no public IP addresses
  # The control plane communicates with nodes via private peering
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Keep public endpoint for kubectl access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # ========================================================================
  # WORKLOAD IDENTITY
  # ========================================================================
  # Enables pod-level GCP authentication without service account keys.
  # Pods annotated with a Kubernetes service account automatically receive
  # temporary GCP credentials bound to that service account.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # ========================================================================
  # SECURITY
  # ========================================================================
  # Shielded nodes use Secure Boot and vTPM to verify node integrity
  # Protects against rootkit and bootkit attacks at the hardware level
  enable_shielded_nodes = true

  # ========================================================================
  # ADDONS
  # ========================================================================
  addons_config {
    # HTTP load balancing creates GCP load balancers for Kubernetes Services
    # of type LoadBalancer — needed for the nginx frontend public endpoint
    http_load_balancing {
      disabled = false
    }

    # Horizontal Pod Autoscaler — scales pods based on CPU/memory
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
# The worker nodes that run your application pods.
# Separate from the cluster definition for independent lifecycle management.
resource "google_container_node_pool" "primary_nodes" {
  name     = "primary-node-pool"
  location = var.region
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  # Start with 1 node per zone — scales automatically
  node_count = 1

  # ========================================================================
  # AUTOSCALING
  # ========================================================================
  # Automatically adds or removes nodes based on pod scheduling demand
  # Min 1 node ensures the cluster is never empty
  # Max 3 nodes caps cost for the learning environment
  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  # ========================================================================
  # NODE CONFIGURATION
  # ========================================================================
  node_config {
    # e2-medium: 2 vCPU, 4GB RAM
    # Smallest machine type that comfortably runs GKE system pods + app pods
    machine_type = "e2-medium"

    # Run nodes as the dedicated GKE service account, not default compute SA
    service_account = google_service_account.gke_nodes.email

    # Enable Workload Identity on the nodes
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded instance config for node security
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Network tags for firewall rule targeting
    # The landing zone firewall rules target "gke-node" tagged instances
    tags = ["gke-node"]

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  # ========================================================================
  # UPGRADE SETTINGS
  # ========================================================================
  # Surge upgrade keeps one extra node available during upgrades
  # so pods are never left without a node to schedule on
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