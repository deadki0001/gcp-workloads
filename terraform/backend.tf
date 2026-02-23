# ============================================================================
# REMOTE STATE BACKEND
# ============================================================================
# Reuses the same GCS bucket as the landing zone but with a different prefix.
# This keeps all infrastructure state in one governed location while
# separating landing zone state from workload state.
# The bucket was created by the landing zone bootstrap stage.
terraform {
  backend "gcs" {
    bucket = "project-5a757d72-eb26-477c-bd9-tf-state"
    prefix = "gcp-workloads"
  }
}