# infra/ — Person A

Scope: cluster & registry provisioning, stateful backing services (Redis, PostgreSQL), secrets, network policies.

## Layout

```
terraform/              IaC for the Kubernetes cluster + private registry (Azure: AKS + ACR, see terraform/README.md)
k8s/namespace/          Namespace for the whole app
k8s/redis/              Redis Deployment + Service
k8s/postgres/           PostgreSQL StatefulSet + PVC + Service + schema-init Job
k8s/network-policies/   NetworkPolicies restricting access to Redis/Postgres
```

## Starter manifests

`k8s/` contains a working starting point (no cloud-specific resources, no real secrets):
- image tags/versions (Redis 8.x, PostgreSQL 18 per the app contract)
- resource requests/limits
- storage class for the PostgreSQL PVC (`managed-csi` on AKS)
- the `postgres-credentials` Secret: `secret.yaml.example` is a template — copy it to `secret.yaml` locally with the real password, never commit `secret.yaml` itself (already gitignored)

## TODO

- [x] Pick the cloud platform (Azure AKS + ACR) and write the Terraform / scripts to provision cluster + private registry
- [x] Document cluster access (kubeconfig retrieval) and the evaluator's secrets/apply steps in the root [docs/SECRETS.md](../docs/SECRETS.md)
- [x] Apply and validate the `k8s/` manifests here against a real cluster (AKS)
- [x] Write the NetworkPolicies in `k8s/network-policies/` (Redis ← poll/worker, Postgres ← worker/result; tested on kind and AKS)
- [x] Decide & document Postgres persistence/backup strategy in [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)
