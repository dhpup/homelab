# Self-Managing Kubernetes Homelab with ArgoCD

A local homelab Kubernetes cluster managed with ArgoCD using the [app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/).

## Repository Layout

```
argocd/
  app-of-apps.yaml          # root application — discovers everything under argocd/
  applications/
    setup/                  # ArgoCD Application CRs for platform services
    external/               # ArgoCD Application CRs for externally-facing apps
    internal/               # ArgoCD Application CRs for internal services
  projects/                 # ArgoCD AppProject definitions with namespace scoping
configs/
  setup/                    # Helm values and manifests for platform services
  external/                 # Helm values and manifests for external apps
  internal/                 # Helm values and manifests for internal apps
scripts/
  k3d-healthcheck.sh        # Cluster health check and flannel IP drift recovery
  pvc-backup.sh             # Back up and restore PVC data
```

## ArgoCD Model

`app-of-apps` recursively discovers all manifests under `argocd/` and manages them automatically. ArgoCD `Application` CRs live in the `argocd` namespace; workloads deploy into their own isolated namespaces.

Each project is scoped to its expected namespaces:

| Project | Namespaces |
|---------|------------|
| `setup` | `argocd`, `cert-manager`, `external-secrets`, `kargo`, `kargo-cluster-secrets`, `kargo-shared-resources`, `kargo-system-resources`, `k8s-gateway`, `kube-system`, `metallb-system`, `monitoring`, `traefik` |
| `external` | `seerr`, `doplarr` |
| `internal` | `bazarr`, `maintainerr`, `prowlarr`, `radarr`, `recyclarr`, `sonarr`, `tdarr`, `unpackerr` |

The `default` project intentionally uses wildcard source/destination/resource permissions — it exists solely to host the `app-of-apps` root Application and requires broad access to bootstrap everything else.

## Applications

### Setup

| App | Description |
|-----|-------------|
| [argocd](https://argoproj.github.io/cd/) v3.4.3 | GitOps controller — self-manages from this repo |
| [cert-manager](https://cert-manager.io/) v1.20.2 | TLS certificates via mkcert (self-signed CA) and Let's Encrypt |
| [external-secrets](https://external-secrets.io/) v2.5.0 | Syncs secrets from Infisical Cloud into Kubernetes |
| [kargo](https://kargo.io/) v1.10.5 | Progressive delivery and promotion orchestration |
| [k8s-gateway](https://github.com/ori-edge/k8s_gateway) v2.4.0 | CoreDNS plugin — resolves `*.homelab.local` from Ingress/Service resources |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) v86.2.3 | Observability — Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics |
| [loki](https://grafana.com/oss/loki/) v7.0.0 | Log aggregation (single-binary, filesystem storage, 14-day retention) |
| [alloy](https://grafana.com/docs/alloy/) v1.10.0 | DaemonSet log collector — ships pod logs to Loki (Promtail successor) |
| [metallb](https://metallb.universe.tf/) v0.16.1 | Bare-metal load balancer (BGP mode, pool `172.19.0.1-50`, in-cluster only) |
| [traefik](https://traefik.io/) v3.6 | Ingress controller (DaemonSet), default IngressClass, HTTP→HTTPS redirect |
| [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) v2.18.6 | Encrypts secrets for safe storage in Git |

### External

| App | Description |
|-----|-------------|
| [seerr](https://seerr.dev/) v3.3.0 | Media request portal and discovery (Overseerr/Jellyseerr successor) |
| [doplarr](https://github.com/kiranshila/Doplarr) v3.8.0 | Discord slash-command bot for requesting movies and TV shows via Seerr |

### Internal

| App | Description |
|-----|-------------|
| [bazarr](https://www.bazarr.media/) v1.5.6 | Automatic subtitle management |
| [maintainerr](https://github.com/Maintainerr/Maintainerr) v3.17.0 | Rule-based media cleanup and rotation for Plex/Jellyfin libraries |
| [prowlarr](https://prowlarr.com/) v2.3.5 | Indexer manager — syncs indexers to Radarr and Sonarr |
| [radarr](https://radarr.video/) v6.2.1 | Movie library automation (root: `/homelab-storage/movies`) |
| [recyclarr](https://recyclarr.dev/) v7.5.2 | Scheduled CronJob — syncs [Trash Guides](https://trash-guides.info/) quality definitions, custom formats, and profiles into Radarr/Sonarr |
| [sonarr](https://sonarr.tv/) v4.0.18 | TV series library automation (root: `/homelab-storage/tv`) |
| [tdarr](https://tdarr.io/) v2.77.01 | Automated media transcoding |
| [unpackerr](https://github.com/unpackerr/unpackerr) v0.15.2 | Unpacks completed downloads and notifies Radarr/Sonarr |

## Bootstrapping

Prerequisite: a running Kubernetes cluster with a CNI.

```bash
# Deploy ArgoCD
kubectl apply -k configs/setup/argocd/

# Deploy the root app-of-apps — ArgoCD will take over from here
kubectl apply -f argocd/app-of-apps.yaml -n argocd
```

All other applications are deployed automatically. Changes pushed to `main` are reconciled on the next ArgoCD sync cycle.

## Accessing Services

All ingress endpoints use HTTPS with mkcert-issued certificates.

| Service | URL |
|---------|-----|
| ArgoCD | `https://argocd.homelab.local` |
| Kargo | `https://kargo.homelab.local` |
| Grafana | `https://grafana.homelab.local` |
| Prometheus | `https://prometheus.homelab.local` |
| Alertmanager | `https://alertmanager.homelab.local` |
| Seerr | `https://seerr.homelab.local` |
| Maintainerr | `https://maintainerr.homelab.local` |
| Sonarr | `https://sonarr.homelab.local` |
| Radarr | `https://radarr.homelab.local` |
| Bazarr | `https://bazarr.homelab.local` |
| Prowlarr | `https://prowlarr.homelab.local` |
| Tdarr | `https://tdarr.homelab.local` |

Initial ArgoCD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## DNS Setup (macOS)

`k8s-gateway` resolves `*.homelab.local` dynamically from Ingress and Service resources, but it is only useful *inside* the cluster: its MetalLB LoadBalancer IP (`172.19.0.x`) is not routable from macOS, so from the Mac its answers point at unreachable addresses. Do **not** create an `/etc/resolver/homelab.local` file pointing at node IPs — node IPs drift when Docker reassigns addresses after a reboot, and the answers are unreachable anyway.

Instead, add `/etc/hosts` entries pointing each `*.homelab.local` hostname to **`127.0.0.1`**. The k3d serverlb publishes ports 80/443 to localhost (see `k3d-bootstrap/k3d-config.yaml`), and Traefik routes by SNI/Host header — so localhost works for every app and never drifts across reboots or IP reshuffles:

```
127.0.0.1 argocd.homelab.local
127.0.0.1 radarr.homelab.local
# ... one line per app
```

After editing:

```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

To query k8s-gateway directly for DNS debugging (find the NodePort with `kubectl get svc -n k8s-gateway k8s-gateway`):

```bash
dig @<k3d-server-node-ip> -p <nodeport> argocd.homelab.local +short
```

## Secrets

Two systems manage secrets in an intentional two-layer pattern:

- **[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)** — bootstrap layer. Encrypts secrets with the cluster's sealing key for safe Git storage. Used to store the Infisical credentials that ESO needs to start.
- **[External Secrets Operator](https://external-secrets.io/)** + **[Infisical Cloud](https://infisical.com/)** — runtime layer. Once ESO is running, it fetches all other secrets from Infisical Cloud and creates Kubernetes `Secret` objects. Secrets refresh every 15 minutes.

> If you fork this repository, you will need to provision your own Infisical secrets and re-seal any Sealed Secret resources with your own cluster key.

## Doplarr

Doplarr is a Discord slash-command bot that forwards requests to Seerr via Discord slash commands (`/request`). It has no web UI — configuration is entirely via environment variables in the deployment. Users must have their Discord ID linked in Seerr (Users → Edit → Discord ID) for requests to be attributed correctly.

## Recyclarr

Recyclarr keeps Radarr and Sonarr aligned with [Trash Guides](https://trash-guides.info/) recommendations. It has no web UI — it runs as a monthly Kubernetes `CronJob` (04:00 on the 1st) that executes `recyclarr sync`, pulling quality definitions, custom formats, and quality profiles from the Trash Guides config templates. The Radarr/Sonarr API keys come from Infisical via an `ExternalSecret`; the sync config (`recyclarr.yml`) is a `ConfigMap` mounted into the job.

The current setup applies the **HD-tier** profiles (Radarr: *HD Bluray + WEB*; Sonarr: *WEB-1080p*) — 720p/1080p only, no 4K/Remux. To apply changes immediately instead of waiting for the schedule:

```bash
kubectl -n recyclarr create job --from=cronjob/recyclarr recyclarr-manual
kubectl -n recyclarr logs job/recyclarr-manual
```

> Pinned to image `7.5.2`: Recyclarr 8.x defaults its config-templates source to the upstream `v8` branch, whose includes registry is currently empty (breaking every templated include). 7.x sources templates from `master`, where the registry is populated, with no workaround needed.

## Monitoring

Cluster and workload observability is provided by `kube-prometheus-stack` (metrics) plus `loki` + `alloy` (logs), all in the `monitoring` namespace. Grafana is the single pane of glass — it ships pre-loaded with the kube-prometheus dashboards and is wired to both the bundled Prometheus datasource and Loki for logs.

Grafana's default login is `admin` / `prom-operator`. Retrieve (or rotate) it from the generated secret:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

Notes specific to this cluster:

- **k3s control plane** — `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, and `kubeEtcd` scrape targets are disabled in `values.yaml`; k3s bundles them into one process and does not expose their metrics, so leaving them on creates permanently-down targets and noisy alerts.
- **Retention** — Prometheus keeps 15 days *or* 18 GB (whichever comes first, via `retentionSize`); Loki keeps 14 days. Storage plateaus once those windows fill (~33 Gi provisioned across the four PVCs, ~23 GB of actual data at steady state).
- **Logs** — Alloy reads pod logs through the Kubernetes API (no host mounts) and pushes to Loki's gateway. Query them in Grafana via **Explore → Loki**, e.g. `{namespace="sonarr"}`.

Remember to add the three new hostnames (`grafana`, `prometheus`, `alertmanager`.homelab.local) to `/etc/hosts` pointing at `127.0.0.1` — see [DNS Setup](#dns-setup-macos).

## Cluster Recovery

If the k3d cluster is restarted and nodes lose connectivity (flannel IP drift, stale taints, etc.), `scripts/k3d-healthcheck.sh` detects and corrects flannel annotation mismatches and verifies node readiness. It runs automatically via a macOS LaunchAgent on cluster restart. To trigger it manually:

```bash
bash scripts/k3d-healthcheck.sh
```

