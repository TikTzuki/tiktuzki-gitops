---
title: "[Superseded] Quy trình backup cũ (LVM snapshot + pg_dump CronJob)"
---

:::danger[Superseded — do not follow this]
This documents the **previous** backup strategy: LVM snapshots plus a `pg_dump` CronJob.
It is no longer how this cluster is backed up and following it will not produce a
restorable backup.

The current procedure is [`docs/operations/backup-restore/backup-flow.md`](../operations/backup-restore/backup-flow.md)
— staged collection, age encryption, and a split upload to S3 Standard-IA + Deep Archive.

Kept because it is the only substantial Vietnamese-language writing in the corpus and it
records why the strategy changed. It lives in `docs/history/` and is deliberately **not**
published to the site: it is Vietnamese prose, and it is wrong.
:::

# Quy trình Backup

## Tổng quan

Chiến lược backup cho microk8s cluster on-premise chạy trên Ubuntu Server 24 với LVM.
Tất cả PV đều dùng `local` volume trên node1, nên backup tập trung vào 2 layer:

1. **Application-level** - pg_dump cho PostgreSQL/TimescaleDB
2. **Infrastructure-level** - LVM snapshot cho toàn bộ filesystem

```
┌─────────────────────────────────────────────────────────────────┐
│                        BACKUP FLOW                              │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐  │
│  │  CronJob     │    │  CronJob     │    │  Cron (host)      │  │
│  │  db-backup   │    │  tsdb-backup │    │  lvm-snapshot     │  │
│  │  Daily 2AM   │    │  Daily 2AM   │    │  Weekly Sun 3AM   │  │
│  └──────┬───────┘    └──────┬───────┘    └─────────┬─────────┘  │
│         │                   │                      │            │
│         ▼                   ▼                      ▼            │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐  │
│  │  pg_dump     │    │  pg_dump     │    │  lvcreate         │  │
│  │  --format=c  │    │  --format=c  │    │  --snapshot       │  │
│  │  + gzip      │    │  + gzip      │    │  5G               │  │
│  └──────┬───────┘    └──────┬───────┘    └─────────┬─────────┘  │
│         │                   │                      │            │
│         ▼                   ▼                      ▼            │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │              /mnt/backup/ (on node1)                        ││
│  │                                                             ││
│  │  postgres/                                                  ││
│  │    ├── postgres-20260214-020000.dump.gz                     ││
│  │    ├── fnb-admin-20260214-020000.dump.gz                    ││
│  │    ├── room_manager-20260214-020000.dump.gz                 ││
│  │    └── keycloak-20260214-020000.dump.gz                     ││
│  │  timescaledb/                                               ││
│  │    └── timescaledb-20260214-020000.dump.gz                  ││
│  │  lvm-snapshots/                                             ││
│  │    └── ubuntu-lv-snap-20260209.img.gz                       ││
│  └─────────────────────────────────────────────────────────────┘│
│         │                                                       │
│         ▼  (optional - rsync/rclone ra external)                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  External Storage (NAS / S3 / remote server qua VPN)        ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

## Các service có state cần backup

| Service       | Namespace | Data Path (node)             | Databases                                   | Mức độ         |
|---------------|-----------|------------------------------|---------------------------------------------|----------------|
| PostgreSQL 16 | database  | `/mnt/data/postgres`         | postgres, fnb-admin, room_manager, keycloak | **Quan trọng** |
| TimescaleDB   | database  | `/home/tik/data/timescaledb` | timescaledb                                 | **Quan trọng** |
| MongoDB       | database  | -                            | -                                           | Trung bình     |
| Redis         | database  | - (in-memory)                | -                                           | Thấp (cache)   |

> Redis chủ yếu dùng làm cache, không cần backup. MongoDB backup tương tự flow pg_dump nhưng dùng `mongodump`.

## Layer 1: Database Backup (CronJob)

### Chuẩn bị trên node

```bash
# Tạo thư mục backup
sudo mkdir -p /mnt/backup/{postgres,timescaledb,mongodb,scripts}
sudo chown -R 1000:1000 /mnt/backup

# PV cho backup storage
```

### Tạo PV cho backup

```yaml
# backup-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: backup-pv
  labels:
    type: backup
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  local:
    path: /mnt/backup
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - node1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backup-pvc
  namespace: database
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  selector:
    matchLabels:
      type: backup
```

### PostgreSQL Backup CronJob

```yaml
# postgres-backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: database
spec:
  schedule: "0 2 * * *"  # Hàng ngày lúc 2 giờ sáng
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          nodeSelector:
            kubernetes.io/hostname: node1
          containers:
            - name: pg-backup
              image: postgres:16
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: database-secret
                      key: password
              command:
                - /bin/bash
                - -c
                - |
                  set -euo pipefail
                  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
                  BACKUP_DIR=/backup/postgres
                  RETENTION_DAYS=7
                  PG_HOST=postgres-postgresql.database.svc.cluster.local

                  DATABASES="postgres fnb-admin room_manager keycloak"

                  for DB in $DATABASES; do
                    echo "[$(date)] Đang backup $DB..."
                    pg_dump -h $PG_HOST -U postgres -Fc $DB | \
                      gzip > "$BACKUP_DIR/${DB}-${TIMESTAMP}.dump.gz"
                    echo "[$(date)] Xong: ${DB}-${TIMESTAMP}.dump.gz ($(du -h "$BACKUP_DIR/${DB}-${TIMESTAMP}.dump.gz" | cut -f1))"
                  done

                  # Dọn dẹp backup cũ
                  echo "[$(date)] Xoá backup cũ hơn $RETENTION_DAYS ngày..."
                  find $BACKUP_DIR -name "*.dump.gz" -mtime +$RETENTION_DAYS -delete

                  echo "[$(date)] Backup hoàn tất."
              volumeMounts:
                - name: backup-storage
                  mountPath: /backup
          volumes:
            - name: backup-storage
              persistentVolumeClaim:
                claimName: backup-pvc
          restartPolicy: OnFailure
```

### TimescaleDB Backup CronJob

```yaml
# timescaledb-backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: timescaledb-backup
  namespace: database
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          nodeSelector:
            kubernetes.io/hostname: node1
          containers:
            - name: tsdb-backup
              image: timescale/timescaledb:2.24.0-pg17
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: database-secret
                      key: password
              command:
                - /bin/bash
                - -c
                - |
                  set -euo pipefail
                  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
                  BACKUP_DIR=/backup/timescaledb
                  RETENTION_DAYS=7
                  TSDB_HOST=timescaledb.database.svc.cluster.local

                  echo "[$(date)] Đang backup TimescaleDB..."
                  pg_dump -h $TSDB_HOST -U postgres -Fc timescaledb | \
                    gzip > "$BACKUP_DIR/timescaledb-${TIMESTAMP}.dump.gz"
                  echo "[$(date)] Xong: timescaledb-${TIMESTAMP}.dump.gz"

                  # Dọn dẹp
                  find $BACKUP_DIR -name "*.dump.gz" -mtime +$RETENTION_DAYS -delete
                  echo "[$(date)] Backup hoàn tất."
              volumeMounts:
                - name: backup-storage
                  mountPath: /backup
          volumes:
            - name: backup-storage
              persistentVolumeClaim:
                claimName: backup-pvc
          restartPolicy: OnFailure
```

## Layer 2: LVM Snapshot (Host-level)

LVM snapshot chụp toàn bộ filesystem tại một thời điểm, bao gồm cả data directory của tất cả PV.

### Script backup trên host

```bash
#!/bin/bash
# /mnt/backup/scripts/lvm-snapshot-backup.sh
set -euo pipefail

VG="ubuntu-vg"
LV="ubuntu-lv"
SNAP_SIZE="5G"
BACKUP_DIR="/mnt/backup/lvm-snapshots"
RETENTION_DAYS=30
TIMESTAMP=$(date +%Y%m%d)
SNAP_NAME="${LV}-snap-${TIMESTAMP}"

echo "[$(date)] === LVM Snapshot Backup ==="

# Kiểm tra dung lượng trống trong VG
FREE_SPACE=$(vgs --noheadings -o vg_free --units g $VG | tr -d ' ')
echo "Dung lượng trống VG: $FREE_SPACE"

# Xoá snapshot cũ nếu tồn tại cùng tên
if lvs /dev/$VG/$SNAP_NAME &>/dev/null; then
  echo "Xoá snapshot cũ: $SNAP_NAME"
  lvremove -f /dev/$VG/$SNAP_NAME
fi

# Tạo snapshot
echo "Tạo snapshot: $SNAP_NAME ($SNAP_SIZE)"
lvcreate --size $SNAP_SIZE --snapshot --name $SNAP_NAME /dev/$VG/$LV

# Mount và dump snapshot (tuỳ chọn - nếu muốn lưu ra file)
MOUNT_DIR="/tmp/snap-mount-${TIMESTAMP}"
mkdir -p $MOUNT_DIR
mount -o ro /dev/$VG/$SNAP_NAME $MOUNT_DIR

echo "Đang nén dữ liệu snapshot..."
tar czf "$BACKUP_DIR/${SNAP_NAME}.tar.gz" \
  -C $MOUNT_DIR \
  mnt/data/postgres \
  home/tik/data/timescaledb \
  2>/dev/null || true

umount $MOUNT_DIR
rmdir $MOUNT_DIR

# Xoá snapshot sau khi đã archive
lvremove -f /dev/$VG/$SNAP_NAME

# Dọn dẹp archive cũ
find $BACKUP_DIR -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete

echo "[$(date)] === Snapshot backup hoàn tất ==="
echo "Archive: $BACKUP_DIR/${SNAP_NAME}.tar.gz ($(du -h "$BACKUP_DIR/${SNAP_NAME}.tar.gz" | cut -f1))"
```

### Cài đặt cron trên host

```bash
# Cấp quyền execute
sudo chmod +x /mnt/backup/scripts/lvm-snapshot-backup.sh

# Thêm vào root crontab
sudo crontab -e
```

```cron
# LVM snapshot backup - Chủ nhật hàng tuần lúc 3 giờ sáng
0 3 * * 0 /mnt/backup/scripts/lvm-snapshot-backup.sh >> /var/log/lvm-backup.log 2>&1
```

## Quy trình Restore

### Restore database PostgreSQL

```bash
# Liệt kê các bản backup
ls -la /mnt/backup/postgres/

# Restore database cụ thể
BACKUP_FILE="fnb-admin-20260214-020000.dump.gz"
DB_NAME="fnb-admin"

# Cách 1: Restore từ node (nhanh nhất)
gunzip -c /mnt/backup/postgres/$BACKUP_FILE | \
  kubectl exec -i -n database deployment/postgres -- \
  pg_restore -U postgres -d $DB_NAME --clean --if-exists

# Cách 2: Restore với tạo lại database
kubectl exec -n database deployment/postgres -- \
  psql -U postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
kubectl exec -n database deployment/postgres -- \
  psql -U postgres -c "CREATE DATABASE \"$DB_NAME\";"
gunzip -c /mnt/backup/postgres/$BACKUP_FILE | \
  kubectl exec -i -n database deployment/postgres -- \
  pg_restore -U postgres -d $DB_NAME
```

### Restore TimescaleDB

```bash
BACKUP_FILE="timescaledb-20260214-020000.dump.gz"

# Trước khi restore: đảm bảo extension timescaledb đã được cài
kubectl exec -n database deployment/timescaledb -- \
  psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"

gunzip -c /mnt/backup/timescaledb/$BACKUP_FILE | \
  kubectl exec -i -n database deployment/timescaledb -- \
  pg_restore -U postgres -d timescaledb --clean --if-exists
```

### Restore từ LVM snapshot

```bash
# Chỉ dùng khi cần disaster recovery toàn bộ node

# 1. Dừng workloads
kubectl scale deployment --all -n database --replicas=0

# 2. Giải nén backup
ARCHIVE="ubuntu-lv-snap-20260209.tar.gz"
sudo tar xzf /mnt/backup/lvm-snapshots/$ARCHIVE -C /

# 3. Khởi động lại workloads
kubectl scale deployment --all -n database --replicas=1

# 4. Kiểm tra
kubectl get pods -n database
kubectl exec -n database deployment/postgres -- psql -U postgres -c "SELECT datname FROM pg_database;"
```

## Kiểm tra Backup

### Kiểm tra thủ công (nên chạy định kỳ hàng tháng)

```bash
# Kiểm tra backup file không bị corrupt
BACKUP_FILE="/mnt/backup/postgres/postgres-20260214-020000.dump.gz"

# Test gunzip
gunzip -t $BACKUP_FILE && echo "OK: File không bị lỗi"

# Test pg_restore dry-run (liệt kê nội dung)
gunzip -c $BACKUP_FILE | pg_restore -l | head -20
```

### Chạy backup thủ công

```bash
# Chạy PostgreSQL backup ngay lập tức
kubectl create job --from=cronjob/postgres-backup manual-pg-backup-$(date +%s) -n database

# Chạy TimescaleDB backup
kubectl create job --from=cronjob/timescaledb-backup manual-tsdb-backup-$(date +%s) -n database

# Kiểm tra trạng thái job
kubectl get jobs -n database
kubectl logs job/manual-pg-backup-<id> -n database
```

## Tóm tắt lịch Backup

| Đối tượng              | Phương pháp    | Lịch          | Lưu trữ | Vị trí                       |
|------------------------|----------------|---------------|---------|------------------------------|
| PostgreSQL (tất cả DB) | pg_dump + gzip | Hàng ngày 2AM | 7 ngày  | `/mnt/backup/postgres/`      |
| TimescaleDB            | pg_dump + gzip | Hàng ngày 2AM | 7 ngày  | `/mnt/backup/timescaledb/`   |
| LVM Snapshot (toàn bộ) | lvcreate + tar | Chủ nhật 3AM  | 30 ngày | `/mnt/backup/lvm-snapshots/` |

## Backup ra bên ngoài (Tuỳ chọn)

Nếu muốn đẩy backup ra external storage để phòng trường hợp mất node:

```bash
# Rsync tới remote server qua VPN
rsync -avz /mnt/backup/ user@remote-server:/backup/dev-cluster/

# Hoặc dùng rclone tới S3-compatible storage
rclone sync /mnt/backup/ s3:dev-cluster-backup/
```

Thêm vào crontab sau khi backup chạy xong:

```cron
# Đồng bộ backup ra remote - Hàng ngày 4AM (sau khi DB backup xong)
0 4 * * * rsync -avz /mnt/backup/ user@remote-server:/backup/dev-cluster/ >> /var/log/backup-sync.log 2>&1
```
