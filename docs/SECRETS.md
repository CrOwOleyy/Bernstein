# Secrets & credentials

Per the subject, the final delivery must **exclude**:
- the cloud platform credentials/API keys;
- the `POSTGRES_PASSWORD` secret.

Both are documented here: how and where the evaluator sets them before running the deployment.

## Cloud platform credentials & cluster access

- Platform: Azure (AKS + ACR), provisioned via Azure Portal or `infra/terraform/`. No Azure credential or kubeconfig is committed.
- The evaluator needs an Azure account that can create a resource group, an ACR and an AKS cluster (`Contributor` on a subscription), plus `az` and `kubectl` CLIs.
- Authenticate and configure kubectl:
  ```bash
  az login
  az account set --subscription <subscription-id>
  az aks get-credentials --resource-group rg-bernstein --name aks-bernstein
  kubectl get nodes
  ```
- Registry: ACR login server format is `<acr_name>.azurecr.io`. AKS pulls from it automatically via the integrated `AcrPull` role assignment (no imagePullSecret needed).
- The CI pipeline authenticates separately, see "CI (GitHub Actions) credentials" below.

## `POSTGRES_PASSWORD`

- Never committed. Not in any YAML, `.env` committed to the repo, or Dockerfile.
- Example/placeholder files use `*.example` suffix or an obvious placeholder value (`CHANGEME`) and are gitignored when real.
- Stored in the `postgres-credentials` Secret (`POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD`), consumed by the Postgres StatefulSet, worker, result, and the `postgres-schema-init` Job.
- Can be set via CLI or entered when prompted by `./scripts/deploy.sh`:
  ```bash
  kubectl create secret generic postgres-credentials -n bernstein-poll \
    --from-literal=POSTGRES_USER=poll \
    --from-literal=POSTGRES_DB=poll \
    --from-literal=POSTGRES_PASSWORD='<your-secure-password>'
  ```

## `REDIS_PASSWORD`

- Redis requires authentication (`--requirepass`). The poll and worker read the same value via `REDIS_PASSWORD`.
- Stored in the `redis-credentials` Secret, never committed (`infra/k8s/redis/secret.yaml.example` is the template).
- Created before deployment with:
  ```bash
  kubectl create secret generic redis-credentials -n bernstein-poll \
    --from-literal=REDIS_PASSWORD='<your-secure-password>'
  ```

## Automated Deployment (Recommended)

Once `kubectl` points to the cluster:

```bash
# Linux / macOS / WSL:
./scripts/deploy.sh <acr_login_server>

# Windows PowerShell:
.\scripts\deploy.ps1 -AcrLoginServer <acr_login_server>
```

The script will prompt for `POSTGRES_PASSWORD` and `REDIS_PASSWORD` (or use environment variables if exported), deploy the backing and app services in order, wait for readiness, and display the external public IPs.

## Manual Evaluator setup, in order

If the evaluator prefers to apply manifests manually step-by-step:

```bash
# 1. Namespace
kubectl apply -f infra/k8s/namespace/namespace.yaml

# 2. Secrets (never committed) — pick a password for each
kubectl create secret generic postgres-credentials -n bernstein-poll \
  --from-literal=POSTGRES_USER=poll --from-literal=POSTGRES_DB=poll \
  --from-literal=POSTGRES_PASSWORD='<postgres password>'
kubectl create secret generic redis-credentials -n bernstein-poll \
  --from-literal=REDIS_PASSWORD='<redis password>'

# 3. Backing services + network policies
kubectl apply -f infra/k8s/redis/deployment.yaml -f infra/k8s/redis/service.yaml
kubectl apply -f infra/k8s/postgres/statefulset.yaml -f infra/k8s/postgres/service.yaml
kubectl apply -f infra/k8s/network-policies/
kubectl -n bernstein-poll rollout status statefulset/postgres

# 4. Create the `votes` table
kubectl apply -f infra/k8s/postgres/schema-init-job.yaml
kubectl -n bernstein-poll wait --for=condition=complete job/postgres-schema-init

# 5. Deploy application services
for app in poll worker result; do
  sed "s#<ACR_LOGIN_SERVER>#<your-acr-login-server>#g" k8s/apps/$app/deployment.yaml | kubectl apply -f -
done
kubectl apply -f k8s/apps/poll/service.yaml -f k8s/apps/result/service.yaml

# 6. Retrieve External IPs
kubectl get svc -n bernstein-poll
```

## CI (GitHub Actions) credentials

`.github/workflows/build-push.yml` builds and pushes `poll`/`worker`/`result` to the ACR. ACR admin user is disabled (AAD-only), so the pipeline authenticates via OIDC federated credentials — no stored client secret.

Required, set once per repo:

- **Repo secrets** (Settings → Secrets and variables → Actions → Secrets):
  - `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` — from an Azure AD App Registration with a federated credential trusting this repo (`repo:<org>/<repo>:ref:refs/heads/main`) and the `AcrPush` role on the ACR instance.
- **Repo variables** (Settings → Secrets and variables → Actions → Variables):
  - `ACR_NAME` — your Azure Container Registry name
  - `ACR_LOGIN_SERVER` — `<acr_name>.azurecr.io`

## Checklist before every commit

- [ ] No real password, token, or key in any tracked file
- [ ] `.gitignore` covers local `*.tfvars`, `*.env`, generated kubeconfig, and any `secret*.yaml` that isn't a `.example`
- [ ] Any new required secret documented above
