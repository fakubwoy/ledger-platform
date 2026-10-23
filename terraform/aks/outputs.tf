output "get_credentials" {
  value = "az aks get-credentials -g ${azurerm_resource_group.this.name} -n ${azurerm_kubernetes_cluster.this.name}"
}

output "db_url" {
  description = "Goes into db.url in values-aks.yaml"
  value       = "jdbc:postgresql://${azurerm_postgresql_flexible_server.this.fqdn}:5432/ledger?sslmode=require"
}

output "key_vault_url" {
  value = azurerm_key_vault.this.vault_uri
}

output "external_secrets_client_id" {
  description = "Annotate the external-secrets ServiceAccount with azure.workload.identity/client-id"
  value       = azurerm_user_assigned_identity.eso.client_id
}
