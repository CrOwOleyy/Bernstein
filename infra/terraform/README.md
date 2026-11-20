IaC for the Azure resources: resource group, private registry (ACR) and Kubernetes cluster (AKS).

| File | Role |
|------|------|
| `versions.tf` | Terraform + provider versions, azurerm provider config |
| `variables.tf` | Inputs (region, node count/size, ACR tier) with defaults |
| `main.tf` | Resource group, ACR, AKS, `AcrPull` role assignment |
| `outputs.tf` | Registry login server, cluster name, kubeconfig command |
| `terraform.tfvars.example` | Template for local overrides (real `*.tfvars` is gitignored) |

## Usage

```bash
az login
az account set --subscription <id>
terraform init
terraform plan
terraform apply
$(terraform output -raw get_credentials_command)   # configure kubectl
az acr login --name $(terraform output -raw acr_name)
```

Tear down: `terraform destroy`. AKS bills while it runs.
