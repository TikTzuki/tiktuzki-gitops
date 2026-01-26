```
gitops/
├── bootstrap/
│   └── argocd/
│       └── install.yaml
│
├── clusters/
│   ├── dev/
│   │   ├── apps.yaml
│   │   ├── namespace.yaml
│   │   └── values/
│   ├── staging/
│   │   ├── apps.yaml
│   │   └── values/
│   └── prod/
│       ├── apps.yaml
│       └── values/
│
├── apps/
│   ├── base/
│   │   ├── myapp.yaml
│   │   └── redis.yaml
│   ├── dev/
│   │   └── myapp.yaml
│   ├── staging/
│   │   └── myapp.yaml
│   └── prod/
│       └── myapp.yaml
│
├── charts/
│   └── myapp/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-dev.yaml
│       ├── values-staging.yaml
│       ├── values-prod.yaml
│       └── templates/
│
└── README.md
```

### Create backup on for LVM disk:

```bash
# resize logical volume to create space for snapshot
sudo lvreduce -L -5G /dev/ubuntu-vg/ubuntu-lv

sudo lvcreate  --size 5G  --snapshot  --name ubuntu-lv-snap-$(date +%Y%m%d)  /dev/ubuntu-vg/ubuntu-lv
```
