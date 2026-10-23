output "get_credentials" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${var.zone} --project ${var.project}"
}

output "db_url" {
  description = "Goes into db.url in values-gke.yaml"
  value       = "jdbc:postgresql://${google_sql_database_instance.this.private_ip_address}:5432/ledger?sslmode=require"
}

output "external_secrets_gsa" {
  description = "Annotate the external-secrets ServiceAccount with iam.gke.io/gcp-service-account"
  value       = google_service_account.eso.email
}
