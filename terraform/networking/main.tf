# ============================================================================
# NETWORKING MODULE
# ============================================================================
# This module does NOT create a new VPC. Instead it references the Shared VPC
# that was created by the landing zone networking module. The prod-workloads
# project is already attached to the shared VPC as a service project.
#
# What we DO create here:
# - Private IP allocation for Cloud SQL (so it sits on the shared VPC)
# - Additional firewall rules specific to GKE and application traffic
#
# AWS equivalent: Adding security group rules and VPC endpoint policies
# to an existing shared VPC after attaching an account to it via RAM.

# ============================================================================
# DATA SOURCES — REFERENCE EXISTING LANDING ZONE RESOURCES
# ============================================================================
# Data sources read existing infrastructure without managing it.
# The shared VPC was created by the landing zone - we just reference it here.

data "google_compute_network" "shared_vpc" {
  name    = "shared-vpc"
  project = "networking-host-lz-001"
}

data "google_compute_subnetwork" "prod_subnet" {
  name    = "prod-subnet"
  region  = var.region
  project = "networking-host-lz-001"
}

# ============================================================================
# PRIVATE IP RANGE FOR CLOUD SQL
# ============================================================================
# Cloud SQL with private IP requires a reserved IP range in the VPC.
# This range is used internally by Google's service networking to place
# the Cloud SQL instance on your private network.
# No public IP = no exposure to internet = enterprise security standard.
resource "google_compute_global_address" "private_ip_range" {
  name          = "cloudsql-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = data.google_compute_network.shared_vpc.id
  project       = "networking-host-lz-001"
}

# Connect the private IP range to Google's service networking
# This creates a VPC peering between your network and Google's managed network
# where Cloud SQL instances run
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = data.google_compute_network.shared_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

# ============================================================================
# FIREWALL RULES FOR APPLICATION TRAFFIC
# ============================================================================

# Allow traffic into GKE nodes from the GKE control plane
# GKE master nodes need to communicate with worker nodes for health checks
# and webhook calls. This is required for GKE to function correctly.
resource "google_compute_firewall" "gke_master_webhook" {
  name    = "allow-gke-master-webhook"
  network = data.google_compute_network.shared_vpc.name
  project = "networking-host-lz-001"

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["8443", "9443", "15017"]
  }

  # GKE control plane IP range for europe-west1
  source_ranges = ["172.16.0.0/28"]

  target_tags = ["gke-node"]
}

# Allow HTTP and HTTPS traffic to reach the nginx frontend LoadBalancer
# The LoadBalancer gets a public IP - this is the only public-facing entry point
resource "google_compute_firewall" "allow_http_https" {
  name    = "allow-http-https-ingress"
  network = data.google_compute_network.shared_vpc.name
  project = "networking-host-lz-001"

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["gke-node"]
}

# ============================================================================
# OUTPUTS
# ============================================================================
# Outputs pass values from this module to the root and other modules

output "network_id" {
  value       = data.google_compute_network.shared_vpc.id
  description = "Shared VPC network ID for Cloud SQL private IP"
}

output "network_name" {
  value       = data.google_compute_network.shared_vpc.name
  description = "Shared VPC network name for GKE cluster"
}

output "subnetwork_name" {
  value       = data.google_compute_subnetwork.prod_subnet.name
  description = "Production subnet name for GKE node placement"
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = data.google_compute_network.shared_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  # Must wait for the API to be enabled on the networking host project
  depends_on = [google_compute_global_address.private_ip_range]
}