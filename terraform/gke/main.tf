# GKE + Cloud SQL + Secret Manager for the ledger. Applied for real on 2026-10-23 (see docs/cloud.md), then destroyed.
# Kafka stays in-cluster via Strimzi; the image stays on GHCR.
terraform {
  required_version = ">= 1.6"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "google" {
  project = var.project
  region  = var.region
}

resource "google_project_service" "apis" {
  for_each           = toset(["container.googleapis.com", "sqladmin.googleapis.com", "secretmanager.googleapis.com", "servicenetworking.googleapis.com"])
  service            = each.value
  disable_on_destroy = false
}

# --- Network: VPC-native cluster; Cloud SQL gets a private IP in the same VPC through service networking.
resource "google_compute_network" "this" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.prefix}-nodes"
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = "10.20.0.0/20"
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.24.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.28.0.0/20"
  }
}

resource "google_compute_global_address" "sql" {
  name          = "${var.prefix}-sql-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "sql" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql.name]
}

# --- Cluster (zonal: one control plane, cheapest for a demo)
resource "google_container_cluster" "this" {
  name                     = "${var.prefix}-gke"
  location                 = var.zone
  network                  = google_compute_network.this.id
  subnetwork               = google_compute_subnetwork.this.id
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  # Dataplane V2 (Cilium) enforces the chart's NetworkPolicies.
  datapath_provider = "ADVANCED_DATAPATH"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Workload Identity: a Kubernetes ServiceAccount can act as a Google service account, no key files.
  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }
}

resource "google_container_node_pool" "default" {
  name       = "default"
  cluster    = google_container_cluster.this.id
  location   = var.zone
  node_count = 2

  node_config {
    machine_type = var.machine_type
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# --- Postgres (replaces the in-cluster CloudNativePG cluster: postgres.enabled=false in values-gke.yaml)
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "this" {
  name                = "${var.prefix}-pg"
  database_version    = "POSTGRES_17"
  region              = var.region
  deletion_protection = false

  settings {
    edition = "ENTERPRISE"
    tier    = "db-f1-micro"
    # A client that dies without closing its socket (node power loss) leaves its session "idle in transaction",
    # holding row locks. Kill such sessions after 10 s, and probe idle clients every 10 s (3 misses = dead) instead
    # of the ~12 minute default. Found by the GKE node-crash drill (docs/cloud.md).
    database_flags {
      name  = "idle_in_transaction_session_timeout"
      value = "10000"
    }
    database_flags {
      name  = "tcp_keepalives_interval"
      value = "10"
    }
    database_flags {
      name  = "tcp_keepalives_count"
      value = "3"
    }
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.this.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "ledger" {
  name     = "ledger"
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "ledger" {
  name     = "ledger"
  instance = google_sql_database_instance.this.name
  password = random_password.db.result
}

# --- Secret: the DB password lives in Secret Manager; External Secrets copies it into the `ledger-db` Secret.
resource "google_secret_manager_secret" "db_password" {
  secret_id = "ledger-db-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

# --- Identity for External Secrets Operator only. The ledger pod itself gets no cloud identity and no token.
resource "google_service_account" "eso" {
  account_id   = "${var.prefix}-external-secrets"
  display_name = "External Secrets Operator for the ledger"
}

resource "google_secret_manager_secret_iam_member" "eso_reads_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.eso.email}"
}

resource "google_service_account_iam_member" "eso_workload_identity" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[external-secrets/external-secrets]"
  # The identity pool <project>.svc.id.goog only exists once a cluster with Workload Identity does.
  depends_on = [google_container_cluster.this]
}
