# ci/ — Person B

Scope: build the 3 application images and push them to the private Docker registry provisioned in [infra/](../infra/README.md).

The actual workflow lives at [.github/workflows/build-push.yml](../.github/workflows/build-push.yml) (GitHub only picks up workflows from that root path, not from here).

## TODO

- [x] Pipeline: GitHub Actions, builds `app/poll`, `app/worker`, `app/result` on push to `main` (path-filtered) or manual dispatch
- [x] Tags images with the commit SHA and `latest`, pushes to the ACR from `infra/terraform/`
- [x] Authenticates via Azure OIDC federated credentials (no stored client secret) — required repo secrets/variables documented in [docs/SECRETS.md](../docs/SECRETS.md)
- [ ] Set up the federated credential + `AcrPush` role assignment in Azure AD (one-time, manual — see docs/SECRETS.md) and verify a push actually succeeds
- [ ] Trigger (or document how to trigger) the corresponding rollout in [k8s/apps/](../k8s/apps/README.md) after a successful push
