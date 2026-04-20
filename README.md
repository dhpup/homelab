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
```

## ArgoCD Model

`app-of-apps` recursively discovers all manifests under `argocd/` and manages them automatically. ArgoCD `Application` CRs live in the `argocd` namespace; workloads deploy into their own isolated namespaces.

Each project is scoped to its expected namespaces:

| Project | Namespaces |
|---------|------------|
| `setup` | `argocd`, `cert-manager`, `external-secrets`, `k8s-gateway`, `metallb-system`, `ingress-nginx`, `kube-system` |
| `external` | `ombi`, `requestrr` |
| `internal` | `bazarr`, `nzbget`, `prowlarr`, `radarr`, `sonarr`, `sealed-secrets-ui`, `tdarr` |

## Applications

### Setup

| App | Description |
|-----|-------------|
| [argocd](https://argoproj.github.io/cd/) | GitOps controller — self-manages from this repo |
| [cert-manager](https://cert-manager.io/) | TLS certificates via mkcert (self-signed CA) |
| [external-secrets](https://external-secrets.io/) | Syncs secrets from Infisical Cloud into Kubernetes |
| [k8s-gateway](https://github.com/ori-edge/k8s_gateway) | CoreDNS plugin — resolves `*.homelab.local` from Ingress/Service resources |
| [metallb](https://metallb.universe.tf/) | Bare-metal load balancer (BGP mode) |
| [nginx-ingress](https://github.com/kubernetes/ingress-nginx) | Ingress controller (DaemonSet) |
| [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) | Encrypts secrets for safe storage in Git |

### External

| App | Description |
|-----|-------------|
| [ombi](https://ombi.io/) | Media request portal |
| [requestrr](https://github.com/darkalfx/requestrr) | Discord bot for requesting movies and TV shows |

### Internal

| App | Description |
|-----|-------------|
| [bazarr](https://www.bazarr.media/) | Automatic subtitle management |
| [nzbget](https://nzbget.net/) | Usenet download client |
| [prowlarr](https://prowlarr.com/) | Indexer manager for the \*arr stack |
| [radarr](https://radarr.video/) | Movie library automation |
| [sonarr](https://sonarr.tv/) | TV series library automation |
| [sealed-secrets-ui](https://github.com/komodor-io/sealed-secrets-ui) | Web UI for sealing secrets |
| [tdarr](https://tdarr.io/) | Automated media transcoding |

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
| Requestrr | `https://requestrr.homelab.local` |
| Ombi | `https://ombi.homelab.local` |
| Sonarr | `https://sonarr.homelab.local` |
| Radarr | `https://radarr.homelab.local` |
| Bazarr | `https://bazarr.homelab.local` |
| NZBGet | `https://nzbget.homelab.local` |
| Prowlarr | `https://prowlarr.homelab.local` |
| Tdarr | `https://tdarr.homelab.local` |
| Sealed Secrets UI | `https://secrets.homelab.local` |

Initial ArgoCD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## DNS Setup (macOS)

`k8s-gateway` resolves `*.homelab.local` dynamically from Ingress and Service resources. Configure macOS to use it:

```bash
# Create domain-specific resolver
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/homelab.local <<'EOF'
nameserver 192.168.97.2
nameserver 192.168.97.3
nameserver 192.168.97.5
nameserver 192.168.97.6
EOF

# Flush resolver cache
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

Do **not** add `*.homelab.local` entries to `/etc/hosts` — they will take precedence over the resolver and bypass k8s-gateway. Reserve `/etc/hosts` overrides only for intentionally static LAN services (e.g. `plex.homelab.local`, `qbittorrent.homelab.local`).

## Secrets

Two systems manage secrets:

- **[External Secrets Operator](https://external-secrets.io/)** + **[Infisical Cloud](https://infisical.com/)** — fetches secrets at runtime and creates Kubernetes `Secret` objects. Secrets refresh every 15 minutes.
- **[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)** — encrypts secrets with the cluster's sealing key so they can be committed to Git safely.

> If you fork this repository, you will need to provision your own Infisical secrets and re-seal any Sealed Secret resources with your own cluster key.

## Requestrr

Requestrr's `settings.json` is seeded from an ExternalSecret on first startup. After initialization, the persisted config on the PVC is the source of truth. See [REQUESTRR_USAGE.md](REQUESTRR_USAGE.md) for full details.

## Cluster Recovery

If the k3d cluster is restarted and nodes lose connectivity (flannel IP drift, stale taints, etc.), run:

```bash
bash scripts/k3d-healthcheck.sh
```

This script detects and corrects flannel annotation mismatches and verifies node readiness.

