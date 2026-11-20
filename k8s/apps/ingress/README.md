# k8s/apps/ingress/ — External Exposure

This directory documents how the application is exposed externally.

## Recommended Approach: `type: LoadBalancer` Services

On managed Kubernetes like Azure Kubernetes Service (AKS), the standard, cloud-native way to expose web workloads without managing an extra Ingress Controller is using **`type: LoadBalancer`** directly in the Kubernetes Services:

- `k8s/apps/poll/service.yaml` → `type: LoadBalancer`
- `k8s/apps/result/service.yaml` → `type: LoadBalancer`

When applied on AKS, Azure automatically provisions an Azure Public Load Balancer and assigns a dedicated Public IP to each service.

```bash
kubectl get svc -n bernstein-poll
```
Outputs:
```
NAME         TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)
poll         LoadBalancer   10.0.12.34     20.x.x.x        80:31234/TCP
result       LoadBalancer   10.0.56.78     20.y.y.y        80:32456/TCP
```

This fulfills the project requirement:
> *"You will be allowed to check what the external IP addresses of the deployed application are and give them to the evaluator."*

## Alternative Approach: Ingress Controller (`ingress.yaml`)

If an Ingress Controller (such as `ingress-nginx` or Azure App Routing) is installed on the cluster, `ingress.yaml` provides host-based routing.

### Why Host-Based Routing?
The `result` application is an Express + Socket.IO app that expects root path `/` for its views and assets (`/stylesheets/style.css`, `/socket.io/socket.io.js`). Simple path-based routing (`/` to poll and `/result` to result on the same host) causes the browser to request Result's CSS and WebSocket through Poll, breaking the page. Host-based routing (`poll.yourdomain.com` and `result.yourdomain.com`) avoids this completely.
