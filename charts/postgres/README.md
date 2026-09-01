# PostgreSQL Helm Chart with Local Volume Support

This Helm chart deploys PostgreSQL on Kubernetes with support for local node volumes.

## Features

- PostgreSQL 16
- Local persistent volume support
- NodePort service for external access
- ArgoCD application ready
- Configurable resources and persistence

## Prerequisites

1. Kubernetes cluster (tested with MicroK8s)
2. Local storage path created on the node
3. ArgoCD installed (for ArgoCD deployment)

## Local Volume Setup

Before deploying, ensure the local storage path exists on your node:

```bash
# SSH into your node
ssh user@node-hostname

# Create the directory for PostgreSQL data
sudo mkdir -p /srv/k8s-volumes/postgres
sudo chown -R 999:999 /srv/k8s-volumes/postgres  # PostgreSQL user UID/GID
sudo chmod 700 /srv/k8s-volumes/postgres
```

## Installation

### Method 1: Direct Helm Install

1. Update `values.yaml` with your node name:

```yaml
persistence:
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - your-node-name  # Change this!
```

2. Install the chart:

```bash
helm install postgres . -n database --create-namespace
```

### Method 2: ArgoCD Deployment

1. Update `postgres-application.yaml`:
  - Set your Git repository URL
  - Update the node name in `nodeAffinity`
  - Set a secure password or use `existingSecret`

2. Apply the ArgoCD application:

```bash
kubectl apply -f postgres-application.yaml
```

## Configuration

### Key Values

| Parameter                    | Description                      | Default              |
|------------------------------|----------------------------------|----------------------|
| `postgres.database`          | Database name                    | `postgres`           |
| `postgres.username`          | Database username                | `postgres`           |
| `postgres.password`          | Database password                | `""`                 |
| `postgres.existingSecret`    | Use existing secret for password | `""`                 |
| `persistence.enabled`        | Enable persistence               | `true`               |
| `persistence.size`           | Storage size                     | `10Gi`               |
| `persistence.useLocalVolume` | Use local node volume            | `true`               |
| `persistence.localPath`      | Path on node                     | `/srv/k8s-volumes/postgres` |
| `service.type`               | Service type                     | `NodePort`           |
| `service.nodePort`           | NodePort number                  | `30432`              |

### Using with Existing Secret

For production, create a secret for the password:

```bash
kubectl create secret generic postgres-secret \
  --from-literal=postgres-password='your-secure-password' \
  -n database
```

Then set in values:

```yaml
postgres:
  existingSecret: postgres-secret
  existingSecretPasswordKey: postgres-password
```

## Accessing PostgreSQL

### From within the cluster:

```bash
kubectl run -it --rm psql-client --image=postgres:16 --restart=Never -n database -- \
  psql -h postgres -U postgres -d postgres
```

### From outside the cluster (NodePort):

```bash
psql -h <node-ip> -p 30432 -U postgres -d postgres
```

## Getting Node Name

To find your node name:

```bash
kubectl get nodes
```

## Verify Deployment

```bash
# Check if PV is created and bound
kubectl get pv

# Check if PVC is bound
kubectl get pvc -n database

# Check pod status
kubectl get pods -n database

# Check service
kubectl get svc -n database
```

## Troubleshooting

### PVC not binding to PV

1. Check node affinity matches your actual node:

```bash
kubectl get nodes --show-labels
```

2. Verify the local path exists and has correct permissions:

```bash
ls -la /srv/k8s-volumes/postgres
```

### Pod not starting

Check logs:

```bash
kubectl logs -n database -l app.kubernetes.io/name=postgres
```

Check events:

```bash
kubectl describe pod -n database -l app.kubernetes.io/name=postgres
```

## Uninstall

### Helm:

```bash
helm uninstall postgres -n database
```

### ArgoCD:

```bash
kubectl delete -f postgres-application.yaml
```

**Note:** The PV has `Retain` reclaim policy, so data will persist even after uninstall. Manually delete the PV if needed.

## Security Recommendations

1. Always use `existingSecret` for passwords in production
2. Use RBAC to restrict access to the namespace
3. Consider using network policies to limit pod access
4. Regularly backup your data
5. Use TLS for connections in production

## Backup and Restore

### Backup:

```bash
kubectl exec -n database deployment/postgres -- \
  pg_dump -U postgres postgres > backup.sql
```

### Restore:

```bash
kubectl exec -i -n database deployment/postgres -- \
  psql -U postgres postgres < backup.sql
```
