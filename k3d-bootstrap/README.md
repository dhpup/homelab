# k3d Bootstrap & Upgrade Guide

This folder contains the cluster configuration for the `homelab` k3d cluster.

**k3d has no rolling upgrade.** Upgrading k3s requires deleting and recreating the cluster. Because PVC data lives inside Docker containers (not on the host), it must be backed up first.

---

## Cluster topology

| Role | Count | Image |
|------|-------|-------|
| Server | 1 | `rancher/k3s:v1.35.3-k3s1` (see `k3d-config.yaml`) |
| Agent | 3 | same |

Host mounts:
- `/Users/daneko/homelab-storage` → `/homelab-storage` on all nodes (media, downloads)

PVC data (app configs, databases) lives at `/var/lib/rancher/k3s/storage/` **inside** `k3d-homelab-server-0`. This data is lost on `k3d cluster delete`.

---

## Pre-delete checklist

Run through this before deleting the cluster. Each item covers something that lives only in the cluster and is not recoverable from Git or Infisical.

```
[ ] 1. Back up PVC data          (Step 1)
[ ] 2. Back up Sealed Secrets keys  (Step 1)
[ ] 3. Confirm mkcert CA is on Mac  (Step 1)
[ ] 4. Note ArgoCD admin password   (optional)
```

---

## Step 1 — Back up cluster state

### PVC data

```bash
cd /Users/daneko/devops/homelab
./scripts/pvc-backup.sh backup
```

This scales down all apps cleanly, backs up every PVC to `~/homelab-pvc-backup/<timestamp>/`, then scales apps back up. The following PVCs are included:

| PVC | Namespace | Contents |
|-----|-----------|----------|
| `sonarr` | sonarr | Sonarr DB + config |
| `radarr` | radarr | Radarr DB + config |
| `bazarr` | bazarr | Bazarr DB + config |
| `prowlarr` | prowlarr | Prowlarr DB + config |
| `seerr` | seerr | Seerr DB + config |
| `maintainerr` | maintainerr | Maintainerr DB + config |
| `tdarr-config` | tdarr | Tdarr config |
| `tdarr-data` | tdarr | Tdarr server data |

To see existing backups: `./scripts/pvc-backup.sh list`

### Sealed Secrets keys

The sealed-secrets controller uses a private key to decrypt SealedSecrets. A new cluster generates a new key, making all existing SealedSecrets unreadable — including `external-secrets/infisical-auth`, which bootstraps the entire secrets chain.

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > ~/homelab-pvc-backup/sealed-secrets-keys.yaml
```

> Do not commit this file — it contains private key material.

### mkcert CA

The `mkcert-ca-secret` in cert-manager is the CA that signs all `*.homelab.local` TLS certs. It is not managed by ArgoCD and will not be recreated automatically. If lost, a new CA is generated and macOS will no longer trust homelab certs until re-trusted in Keychain.

The CA key lives on your Mac — confirm it is present before deleting the cluster:

```bash
ls "$(mkcert -CAROOT)"
# Expected: rootCA-key.pem  rootCA.pem
```

### ArgoCD admin password (optional)

A fresh install generates a new `argocd-initial-admin-secret`. Note the current password if needed:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## Step 2 — Update the k3s image tag

Edit `k3d-config.yaml` and bump the `image` field:

```yaml
image: rancher/k3s:v1.35.3-k3s1   # ← new version
```

Find available tags at: https://github.com/k3s-io/k3s/releases

---

## Step 3 — Delete the cluster

```bash
k3d cluster delete homelab
```

This removes all k3d containers and their volumes. Your `/Users/daneko/homelab-storage` host mount and the backups from Step 1 are unaffected.

---

## Step 4 — Recreate the cluster

```bash
cd /Users/daneko/devops/homelab
k3d cluster create --config k3d-bootstrap/k3d-config.yaml
```

k3d updates your kubeconfig automatically. Port 6443 is pinned to host port `60070` in the config, so the kubeconfig server URL stays stable across recreations.

---

## Step 5 — Restore secrets (before ArgoCD)

These must be in place before ArgoCD syncs, otherwise cert-manager and sealed-secrets will initialise with fresh state and the restore becomes harder.

### Sealed Secrets keys

```bash
kubectl apply -f ~/homelab-pvc-backup/sealed-secrets-keys.yaml
```

### mkcert CA

```bash
kubectl create namespace cert-manager
kubectl create secret tls mkcert-ca-secret \
  -n cert-manager \
  --cert="$(mkcert -CAROOT)/rootCA.pem" \
  --key="$(mkcert -CAROOT)/rootCA-key.pem"
```

---

## Step 6 — Bootstrap ArgoCD

```bash
# Install ArgoCD
kubectl apply -k configs/setup/argocd

# Wait for ArgoCD to come up
kubectl rollout status deploy/argocd-server -n argocd --timeout=5m

# Restart sealed-secrets controller so it picks up the imported keys
kubectl rollout restart deploy/sealed-secrets-controller -n kube-system

# Apply the app-of-apps — ArgoCD syncs everything else automatically
kubectl apply -f argocd/app-of-apps.yaml
```

ArgoCD will pick up all applications and begin syncing. Setup apps (cert-manager, metallb, traefik, etc.) have `automated: {}` and will sync without intervention.

---

## Step 7 — Restore PVC data

Wait for ArgoCD to sync and pods to reach `Running` or `Pending` state (PVCs must exist before restoring), then:

```bash
cd /Users/daneko/devops/homelab
./scripts/pvc-backup.sh restore ~/homelab-pvc-backup/<timestamp>
```

The script scales apps down, restores each PVC from the backup, then scales back up. It skips any PVC that doesn't exist yet and prints a warning — re-run after ArgoCD finishes syncing if needed.

---

## Step 8 — Verify

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

> k8s-gateway must be running and its LoadBalancer IPs must be up for DNS to work. Run this after Step 6.

**Auto-heal LaunchAgent** (`com.homelab.k3d-healthcheck`):

After a machine reboot, Docker restarts the k3d node containers in parallel with no
ordering, which can leave an agent's kubelet wedged (`NotReady` / "Kubelet stopped
posting node status"). Every app with a pod on that node then sits `Progressing` in
ArgoCD. `scripts/k3d-healthcheck.sh` detects and repairs this; the LaunchAgent runs it
at login and hourly.

```bash
# Install / update from the tracked copy
cp k3d-bootstrap/com.homelab.k3d-healthcheck.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.homelab.k3d-healthcheck 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.homelab.k3d-healthcheck.plist
launchctl kickstart -k gui/$(id -u)/com.homelab.k3d-healthcheck   # run once now

# Verify it ran (runs > 0, last exit code = 0)
launchctl print gui/$(id -u)/com.homelab.k3d-healthcheck | grep -E 'runs|last exit'
tail ~/Library/Logs/k3d-healthcheck.log
```

> The plist hard-codes the absolute path to `k3d-healthcheck.sh`. **If you move this
> repo, re-run the install block above** — a stale path fails silently and self-healing
> stops (check `~/Library/Logs/k3d-healthcheck.launchd.log` for "No such file").

---

## First-time cluster creation (no existing cluster)

If you are setting up from scratch with no backup to restore, skip Steps 1, 5, and 7:

```bash
k3d cluster create --config k3d-bootstrap/k3d-config.yaml
kubectl apply -k configs/setup/argocd
kubectl rollout status deploy/argocd-server -n argocd --timeout=5m
kubectl apply -f argocd/app-of-apps.yaml
```

ArgoCD will deploy everything. Apps will initialize fresh on their first run.
