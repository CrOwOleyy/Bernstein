# ACR names are global, lowercase alphanumeric only -> add a random suffix.
resource "random_string" "acr_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project}"
  location = var.location
  tags     = var.tags
}

# Private Docker registry. Admin user is disabled: access goes through
# Azure AD identities only (AKS kubelet identity, CI service principal).
resource "azurerm_container_registry" "main" {
  name                = "acr${var.project}${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.acr_sku
  admin_enabled       = false
  tags                = var.tags
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.project}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = var.project
  tags                = var.tags

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_vm_size
  }

  identity {
    type = "SystemAssigned"
  }

  # Needed for the NetworkPolicies in k8s/network-policies/ to be enforced.
  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }
}

# Lets the cluster nodes pull images from the private registry, so no
# imagePullSecret is needed in the Kubernetes manifests.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
