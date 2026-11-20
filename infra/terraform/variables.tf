variable "project" {
  description = "Short name used as prefix for all resources."
  type        = string
  default     = "bernstein"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "node_count" {
  description = "Number of worker nodes in the default node pool."
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "VM size of the worker nodes. Change it if your subscription restricts this size."
  type        = string
  default     = "Standard_B2s"
}

variable "acr_sku" {
  description = "ACR tier: Basic is enough for this project."
  type        = string
  default     = "Basic"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project = "bernstein"
    managed = "terraform"
  }
}
