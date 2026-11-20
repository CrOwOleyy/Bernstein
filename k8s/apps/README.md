# k8s/apps/ — Person B

Scope: Kubernetes manifests for the stateless application services (poll, worker, result), their external exposure, and the no-downtime rolling update configuration.

## Layout (to fill in)

```
poll/       Deployment + Service for the poll Flask app
worker/     Deployment for the Java worker (no Service needed for traffic, health endpoints only)
result/     Deployment + Service for the Node.js result app
ingress/    Ingress (or LoadBalancer Services) exposing poll and result externally
```

## TODO

- [x] `poll` Deployment + Service (image tag pending CI, see [ci/](../../ci/README.md))
- [x] `worker` Deployment (image tag pending CI)
- [x] `result` Deployment + Service (image tag pending CI)
- [x] Wire env vars per [app/README.md](../../app/README.md) — done for all app services
- [x] Expose poll + result externally (Ingress)
- [x] Configure RollingUpdate strategy (maxUnavailable/maxSurge) and validate zero-downtime with a continuous-request test during an update
- [x] (optional) HPA for poll/result (configured in k8s/apps/hpa.yaml)
