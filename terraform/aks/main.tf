# AKS + managed Postgres + Key Vault for the ledger. Validated with `terraform validate`; never applied from this
# repo (it costs money). Kafka stays in-cluster via Strimzi; the image stays on GHCR.
terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.20" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# --- Network: AKS nodes and the database share a VNet, so Postgres needs no public endpoint.
resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.10.0.0/16"]
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.0.0/22"]
}

resource "azurerm_subnet" "db" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.8.0/24"]
  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# --- Cluster
resource "azurerm_kubernetes_cluster" "this" {
  name                = "${var.prefix}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.prefix

  default_node_pool {
    name           = "system"
    node_count     = 2
    vm_size        = var.node_size
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  identity {
    type = "SystemAssigned"
  }

  # Workload Identity: pods exchange their ServiceAccount token for an Entra ID token, no stored credentials.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    # Cilium enforces the chart's NetworkPolicies (the default AKS setup does not enforce any).
    network_policy     = "cilium"
    network_data_plane = "cilium"
  }
}

# --- Postgres (replaces the in-cluster CloudNativePG cluster: postgres.enabled=false in values-aks.yaml)
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "azurerm_private_dns_zone" "db" {
  name                = "${var.prefix}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "db" {
  name                  = "${var.prefix}-db-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.db.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = "${var.prefix}-pg"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  delegated_subnet_id           = azurerm_subnet.db.id
  private_dns_zone_id           = azurerm_private_dns_zone.db.id
  public_network_access_enabled = false
  administrator_login           = "ledger"
  administrator_password        = random_password.db.result
  zone                          = "1"

  depends_on = [azurerm_private_dns_zone_virtual_network_link.db]
}

resource "azurerm_postgresql_flexible_server_database" "ledger" {
  name      = "ledger"
  server_id = azurerm_postgresql_flexible_server.this.id
}

# --- Secret: the DB password lives in Key Vault; External Secrets copies it into the `ledger-db` Secret.
resource "azurerm_key_vault" "this" {
  name                       = "${var.prefix}-kv-${substr(md5(azurerm_resource_group.this.id), 0, 6)}"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
}

resource "azurerm_role_assignment" "deployer_writes_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "ledger-db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.deployer_writes_secrets]
}

# --- Identity for External Secrets Operator only. The ledger pod itself gets no cloud identity and no token.
resource "azurerm_user_assigned_identity" "eso" {
  name                = "${var.prefix}-external-secrets"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_role_assignment" "eso_reads_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

resource "azurerm_federated_identity_credential" "eso" {
  name                = "external-secrets"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.eso.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:external-secrets:external-secrets"
}
