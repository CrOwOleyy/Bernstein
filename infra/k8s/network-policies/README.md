NetworkPolicies restricting access to the stateful backing services (ingress only):

- `redis.yaml` — only pods labelled `app: poll` or `app: worker` can reach Redis on 6379.
- `postgres.yaml` — only pods labelled `app: worker`, `app: result` or `app: postgres-schema-init` can reach PostgreSQL on 5432.

The app Deployments must carry these `app:` labels on their pod templates. The schema-init Job pod template is labelled `app: postgres-schema-init`.

Enforcement requires a CNI that supports NetworkPolicy (kindnet on kind, Azure Network Policy / Cilium on AKS — set `network_policy` in the Terraform if not already).
