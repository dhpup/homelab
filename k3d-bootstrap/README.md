# k3d Bootstrap & Upgrade Guide

This folder contains the cluster configuration for the `homelab` k3d cluster.

**k3d has no rolling upgrade.** Upgrading k3s requires deleting and recreating the cluster. Because PVC data lives inside Docker containers (not on the host), it must be backed up first.

---

## Cluster topology

| Role | Count | Image |
|------|-------|-------|
| Server | 1 | `rancher/k3s:v1.33.4-k3s1` (see `k3d-config.yaml`) |
| Agent | 3 | same |

Host mounts:
- `/Users/daneko/homelab-storage` → `/homelab-storage` on all nodes (media, downloads)

PVC data (app configs, databases) lives at `/var/lib/rancher/k3s/storage/` **inside** `k3d-homelab-server-0`. This data is lost on `k3d cluster delete`.

---

## Step 1 — Back up PVC data

Run this before deleting the cluster. It copies every PVC directory from the server container to your host:

```bash
BACKUP_DIR="/Users/daneko/homelab-storage/pvc-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

for pvc_dir in $(docker exec k3d-homelab-server-0 ls /var/lib/rancher/k3s/storage/); do
  echo "Backing up $pvc_dir..."
  docker cp "k3d-homelab-server-0:/var/lib/rancher/k3s/storage/$pvc_dir" "$BACKUP_DIR/"
done

echo "Backup complete: $BACKUP_DIR"
ls "$BACKUP_DIR"
```

This will back up all of:

| PVC | Namespace | Contents |
|-----|-----------|----------|
| `nzbget-config` | nzbget | NZBGet settings, queue |
| `radarr-config` | radarr | Radarr DB + config |
| `sonarr-config` | sonarr | Sonarr DB + config |
| `bazarr-config` | bazarr | Bazarr DB + config |
| `prowlarr-config` | prowlarr | Prowlarr DB + config |
| `tdarr-local-path-config` | tdarr | Tdarr config |
| `tdarr-local-path-data` | tdarr | Tdarr data |
| `ombi-config` | ombi | Ombi DB + config |
| `requestrr-config` | requestrr | Seeded from ExternalSecret — backup optional |

---

## Step 2 — Update the k3s image tag

Edit `k3d-config.yaml` and bump the `image` field:

```yaml
image: rancher/k3s:v1.34.0-k3s1   # ← new version
```

Find available tags at: https://github.com/k3s-io/k3s/releases

> Only upgrade one minor version at a time (e.g. 1.33 → 1.34, not 1.33 → 1.35).

---

## Step 3 — Delete the cluster

```bash
k3d cluster delete homelab
```

This removes all k3d containers and their volumes. Your `/Users/daneko/homelab-storage` host mount and the PVC backup from Step 1 are unaffected.

---

## Step 4 — Recreate the cluster

```bash
cd /Users/daneko/devops/homelab
k3d cluster create --config k3d-bootstrap/k3d-config.yaml
```

k3d updates your kubeconfig automatically. Port 6443 is pinned to host port `60070` in the config, so the kubeconfig server URL stays stable across recreations.

---

## Step 5 — Bootstrap ArgoCD

ArgoCD must be installed before the app-of-apps can deploy everything else:

```bash
# Install ArgoCD
kubectl apply -k configs/setup/argocd

# Wait for ArgoCD to come up
kubectl rollout status deploy/argocd-server -n argocd --timeout=5m

# Apply the app-of-apps (ArgoCD will then sync all other apps automatically)
kubectl apply -f argocd/app-of-apps.yaml
```

ArgoCD will pick up all applications and begin syncing. Setup apps (cert-manager, metallb, nginx-ingress, etc.) have `automated: {}` and will sync without intervention.

---

## Step 6 — Restore PVC data

Wait for ArgoCD to create the PVCs (deployments will be in `Pending` or `Running` briefly), then copy backup data back in.

Find the new PVC directory names:
```bash
docker exec k3d-homelab-server-0 ls /var/lib/rancher/k3s/storage/
```

Restore a specific app (example — Sonarr):
```bash
BACKUP_DIR="/Users/daneko/homelab-storage/pvc-backup/<timestamp>"

# Find the new PVC dir for sonarr-config
NEW_DIR=$(docker exec k3d-homelab-server-0 ls /var/lib/rancher/k3s/storage/ | grep sonarr-config)

# Scale down first to avoid file conflicts
kubectl scale deploy/sonarr -n sonarr --replicas=0

# Copy backup in
docker cp "$BACKUP_DIR/pvc-<old-id>_sonarr_sonarr-config/." \
  "k3d-homelab-server-0:/var/lib/rancher/k3s/storage/$NEW_DIR/"

# Scale back up
kubectl scale deploy/sonarr -n sonarr --replicas=1
```

Repeat for each app. The PVC directory names change on recreation (UUID prefix), so match by the `_namespace_claimname` suffix.

---

## Step 7 — Verify

```bash
# All nodes ready
kubectl get nodes

# All apps healthy in ArgoCD
kubectl get applications -n argocd

# Run the healthcheck script
bash scripts/k3d-healthcheck.sh
```

---

## macOS system setup (after new machine or Docker reset)

These are not in git and must be recreated manually:

**DNS resolver** (`/etc/resolver/homelab.local`):
```bash
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/homelab.local <<'EOF'
# Homelab DNS via k8s-gateway LoadBalancer endpoints
nameserver 192.168.97.2
nameserver 192.168.97.3
nameserver 192.168.97.5
nameserver 192.168.97.6
EOF
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

> k8s-gateway must be running and its LoadBalancer IPs must be up for DNS to work. Run this after Step 5.

---

## First-time cluster creation (no existing cluster)

If you are setting up from scratch with no backup to restore, skip Steps 1 and 6:

```bash
k3d cluster create --config k3d-bootstrap/k3d-config.yaml
kubectl apply -k configs/setup/argocd
kubectl rollout status deploy/argocd-server -n argocd --timeout=5m
kubectl apply -f argocd/app-of-apps.yaml
```

ArgoCD will deploy everything. Apps will initialize fresh on their first run.
