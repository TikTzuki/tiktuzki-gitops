# Room Manager Helm Chart

This Helm chart deploys the Room Manager Spring Boot application on Kubernetes with support for local node volumes for logs storage.

## Features

- Spring Boot application (tiktuzki/room-manager)
- NodePort service for external access on port 30080
- Local persistent volume for `/app/logs` directory
- Spring Boot Actuator health checks
- ArgoCD application ready
- Configurable resources and JVM options

## Prerequisites

1. Kubernetes cluster (tested with MicroK8s)
2. Local storage path created on the node for logs
3. ArgoCD installed (for ArgoCD deployment)

## Local Volume Setup

Before deploying, ensure the local storage path exists on your node:

```bash
# SSH into your node or run on the node
ssh user@node-hostname

# Create the directory for logs
sudo mkdir -p /mnt/data/room-manager/logs
sudo chmod 755 /mnt/data/room-manager/logs
# Allow the application user to write logs (adjust UID if needed)
sudo chown -R 1000:1000 /mnt/data/room-manager/logs
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
helm install room-manager . -n default --create-namespace
```

### Method 2: ArgoCD Deployment

1. Update `room-manager-application.yaml`:
  - Set your Git repository URL
  - Update the node name in `nodeAffinity`
  - Set the image tag to your desired version

2. Apply the ArgoCD application:

```bash
kubectl apply -f room-manager-application.yaml
```

## Configuration

### Key Values

| Parameter                    | Description                 | Default                       |
|------------------------------|-----------------------------|-------------------------------|
| `image.repository`           | Docker image repository     | `tiktuzki/room-manager`       |
| `image.tag`                  | Image tag                   | `""` (uses Chart.AppVersion)  |
| `springBoot.javaOpts`        | JVM options                 | `"-Xms512m -Xmx1024m"`        |
| `springBoot.profiles`        | Spring profiles             | `"prod"`                      |
| `service.type`               | Service type                | `NodePort`                    |
| `service.port`               | Service port                | `8080`                        |
| `service.nodePort`           | NodePort number             | `30080`                       |
| `persistence.enabled`        | Enable persistence for logs | `true`                        |
| `persistence.size`           | Storage size for logs       | `5Gi`                         |
| `persistence.useLocalVolume` | Use local node volume       | `true`                        |
| `persistence.localPath`      | Path on node                | `/mnt/data/room-manager/logs` |

### Spring Boot Configuration

The chart supports configuring Spring Boot via environment variables:

```yaml
springBoot:
  javaOpts: "-Xms512m -Xmx1024m -XX:+UseG1GC"
  profiles: "prod,mysql"
```

This sets:

- `JAVA_OPTS` environment variable
- `SPRING_PROFILES_ACTIVE` environment variable

### Health Checks

The chart uses Spring Boot Actuator endpoints:

- Liveness: `/actuator/health/liveness`
- Readiness: `/actuator/health/readiness`

Ensure your Spring Boot application has these endpoints enabled:

```yaml
management:
  endpoint:
    health:
      probes:
        enabled: true
  health:
    livenessState:
      enabled: true
    readinessState:
      enabled: true
```

## Accessing Room Manager

### From outside the cluster (NodePort):

```bash
# Get node IP
kubectl get nodes -o wide

# Access the application
curl http://<node-ip>:30080

# Check health
curl http://<node-ip>:30080/actuator/health
```

### From within the cluster:

```bash
# Port-forward for local testing
kubectl port-forward svc/room-manager 8080:8080

# Access locally
curl http://localhost:8080
```

## Getting Node Name

To find your node name:

```bash
kubectl get nodes
```

Or with labels:

```bash
kubectl get nodes --show-labels
```

## Verify Deployment

```bash
# Check if PV is created and bound
kubectl get pv

# Check if PVC is bound
kubectl get pvc

# Check pod status
kubectl get pods

# Check service
kubectl get svc room-manager

# Check logs
kubectl logs -l app.kubernetes.io/name=room-manager

# Check application logs from mounted volume
kubectl exec -it deployment/room-manager -- ls -la /app/logs
```

## Troubleshooting

### PVC not binding to PV

1. Check node affinity matches your actual node:

```bash
kubectl get nodes --show-labels
kubectl describe pv
kubectl describe pvc
```

2. Verify the local path exists and has correct permissions:

```bash
ls -la /mnt/data/room-manager/logs
```

### Pod not starting

Check logs:

```bash
kubectl logs -l app.kubernetes.io/name=room-manager
```

Check events:

```bash
kubectl describe pod -l app.kubernetes.io/name=room-manager
```

Common issues:

- Image pull errors - check image name and tag
- Health check failures - verify actuator endpoints are enabled
- Permission issues - check log directory permissions

### Application logs

View application logs from the persistent volume:

```bash
# Enter pod
kubectl exec -it deployment/room-manager -- bash

# Check logs directory
ls -la /app/logs
tail -f /app/logs/application.log
```

### Cannot access via NodePort

1. Verify service is running:

```bash
kubectl get svc room-manager
```

2. Check firewall allows port 30080

3. Verify pod is running and ready:

```bash
kubectl get pods -l app.kubernetes.io/name=room-manager
```

## Uninstall

### Helm:

```bash
helm uninstall room-manager
```

### ArgoCD:

```bash
kubectl delete -f room-manager-application.yaml
```

**Note:** The PV has `Retain` reclaim policy, so logs will persist even after uninstall. Manually delete the PV if needed.

## Upgrading

### Update image version:

```bash
helm upgrade room-manager . --set image.tag=v1.2.3
```

### Update via ArgoCD:

Edit the application YAML or use ArgoCD UI to change the image tag, then sync.

## Advanced Configuration

### Custom application.properties

You can mount custom configuration using ConfigMap:

1. Create ConfigMap:

```bash
kubectl create configmap room-manager-config --from-file=application.properties
```

2. Mount in values.yaml:

```yaml
volumeMounts:
  - name: config
    mountPath: /app/config
    
volumes:
  - name: config
    configMap:
      name: room-manager-config
```

### Database Configuration

Add database environment variables:

```yaml
env:
  - name: SPRING_DATASOURCE_URL
    value: "jdbc:mysql://mysql:3306/roomdb"
  - name: SPRING_DATASOURCE_USERNAME
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: username
  - name: SPRING_DATASOURCE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: password
```

### Resource Limits

Configure resource requests and limits:

```yaml
resources:
  limits:
    cpu: 2000m
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 512Mi
```

## Monitoring

### Check metrics endpoint:

```bash
curl http://<node-ip>:30080/actuator/metrics
```

### View application info:

```bash
curl http://<node-ip>:30080/actuator/info
```

## Security Recommendations

1. Use specific image tags instead of `latest`
2. Set resource limits to prevent resource exhaustion
3. Use secrets for sensitive configuration
4. Consider using ingress with TLS instead of NodePort for production
5. Enable RBAC and use appropriate service accounts
6. Regularly update dependencies and base images
7. Use network policies to restrict pod communication

## Backup Logs

Since logs are persisted on local volume:

```bash
# From the node
tar -czf room-manager-logs-backup-$(date +%Y%m%d).tar.gz /mnt/data/room-manager/logs

# Or from pod
kubectl exec deployment/room-manager -- tar -czf /tmp/logs-backup.tar.gz /app/logs
kubectl cp <pod-name>:/tmp/logs-backup.tar.gz ./logs-backup.tar.gz
```

## Support

For application-specific issues, check:

- Application logs: `kubectl logs -l app.kubernetes.io/name=room-manager`
- Persistent logs: `/mnt/data/room-manager/logs` on the node
- Health status: `http://<node-ip>:30080/actuator/health`
