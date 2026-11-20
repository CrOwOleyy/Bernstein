# RollingUpdate Strategy & Zero-Downtime Validation

## Strategy Configuration

All application Deployments (poll, worker, result) are configured with a RollingUpdate strategy that guarantees zero downtime:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0      # Never allow zero replicas running
    maxSurge: 1            # Allow 1 extra replica during update
```

### How it Works

1. **maxUnavailable: 0**: Ensures that at least `replicas - 0 = 2` pods are always running
2. **maxSurge: 1**: Allows up to `replicas + 1 = 3` pods during the rolling update
3. **Update flow**: 
   - Start 1 new pod with the new image (3 total: 2 old + 1 new)
   - Wait for readiness probe to pass on the new pod
   - Kill 1 old pod (3 total: 1 old + 2 new)
   - Repeat until all pods are updated
   - Final state: 2 new pods running

This ensures that traffic is always routed to at least one healthy pod, with no service interruption.

## Testing Zero-Downtime

Use the provided script to validate that rolling updates do not cause downtime:

```bash
./test-zero-downtime.sh <service> <namespace>
```

Example:
```bash
./test-zero-downtime.sh poll bernstein-poll
```

### What the Script Does

1. Sends continuous GET requests to the service (one per second)
2. Triggers a rolling update by patching the Deployment with a new annotation
3. Monitors request success rate during the update
4. Reports any failed requests (which would indicate downtime)
5. Verifies that all pods were rolled over to the new version

### Success Criteria

- ✅ No failed requests during the entire update (100% success rate)
- ✅ All pods show the new image after the update completes
- ✅ Service latency remains consistent throughout
