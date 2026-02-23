# ============================================================================
# DATABASE MODULE — CLOUD SQL MYSQL
# ============================================================================
# Creates a managed MySQL instance using Google Cloud SQL.
# Cloud SQL handles backups, patches, failover, and maintenance automatically.
# The instance sits on the private VPC with no public IP address.
#
# AWS equivalent: RDS MySQL instance in a private subnet with no public
# accessibility, accessed via a security group rule from the application tier.

# ============================================================================
# CLOUD SQL MYSQL INSTANCE
# ============================================================================
resource "google_sql_database_instance" "main" {
  name             = "workloads-mysql-001"
  database_version = "MYSQL_8_0"
  region           = var.region
  project          = var.project_id

  # Prevent accidental deletion of the database
  # To delete, set this to false, apply, then destroy
  deletion_protection = false

  settings {
    # db-f1-micro is the smallest tier - appropriate for learning/dev
    # In production use db-n1-standard-2 or higher
    tier = "db-f1-micro"

    # ========================================================================
    # PRIVATE IP CONFIGURATION
    # ========================================================================
    # No public IP address. The instance is only reachable from within
    # the shared VPC. Application pods connect via the Cloud SQL Auth Proxy
    # which handles authentication and encrypted tunnelling automatically.
    ip_configuration {
      ipv4_enabled    = false # Disables public IP
      private_network = var.network_id

      # Require SSL for all database connections
      # The Cloud SQL Auth Proxy handles this automatically
      ssl_mode = "ENCRYPTED_ONLY"
    }

    # ========================================================================
    # BACKUP CONFIGURATION
    # ========================================================================
    backup_configuration {
      enabled            = true
      binary_log_enabled = true    # Required for point-in-time recovery
      start_time         = "02:00" # Backup at 2am UTC (quiet hours)
    }

    # ========================================================================
    # MAINTENANCE WINDOW
    # ========================================================================
    # Schedule maintenance during low-traffic periods
    # Day 7 = Sunday, hour 3 = 3am UTC
    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }
  }
}

# ============================================================================
# DATABASE
# ============================================================================
# Creates the application database inside the MySQL instance
resource "google_sql_database" "app_db" {
  name     = "appdb"
  instance = google_sql_database_instance.main.name
  project  = var.project_id
}

# ============================================================================
# DATABASE USER
# ============================================================================
# Application-specific user with limited scope.
# The application connects as this user, not as root.
# Principle of least privilege - this user only has access to appdb.
resource "google_sql_user" "app_user" {
  name     = "appuser"
  instance = google_sql_database_instance.main.name
  password = var.db_password
  project  = var.project_id
}

# ============================================================================
# SECRET MANAGER — STORE DB CONNECTION DETAILS
# ============================================================================
# Store the database password in Secret Manager so Kubernetes can
# retrieve it securely without hardcoding credentials in manifests.
# AWS equivalent: AWS Secrets Manager secret referenced by EKS pods
# via IRSA (IAM Roles for Service Accounts).

resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-password"
  project   = var.project_id

  # Auto replication is blocked by the org policy restricting resources
  # to europe-locations. Use user-managed replication pinned to europe-west1.
  replication {
    user_managed {
      replicas {
        location = "europe-west1"
      }
    }
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "instance_connection_name" {
  value       = google_sql_database_instance.main.connection_name
  description = "Connection name used by Cloud SQL Auth Proxy — format: project:region:instance"
}

output "private_ip" {
  value       = google_sql_database_instance.main.private_ip_address
  description = "Private IP of the Cloud SQL instance within the shared VPC"
}

output "database_name" {
  value       = google_sql_database.app_db.name
  description = "Name of the application database"
}