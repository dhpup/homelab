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
renovate.json               # Automated dependency updates (monthly, via Renovate Bot)
```

## ArgoCD Model

`app-of-apps` recursively discovers all manifests under `argocd/` and manages them automatically. ArgoCD `Application` CRs live in the `argocd` namespace; workloads deploy into their own isolated namespaces.

Each project is scoped to its expected namespaces:

| Project | Namespaces |
|---------|------------|
| `setup` | `argocd`, `cert-manager`, `external-secrets`, `kargo`, `k8s-gateway`, `metallb-system`, `traefik` |
| `external` | `seerr`, `doplarr` |
| `internal` | `bazarr`, `maintainerr`, `prowlarr`, `radarr`, `sonarr`, `tdarr`, `unpackerr` |

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
| [metallb](https://metallb.universe.tf/) v0.16.1 | Bare-metal load balancer (BGP mode, IP `172.19.0.0`) |
| [traefik](https://traefik.io/) v3.6 | Ingress controller (DaemonSet), default IngressClass, HTTP→HTTPS redirect |
| [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) v2.18.6 | Encrypts secrets for safe storage in Git |

### External

| App | Description |
|-----|-------------|
| [seerr](https://seerr.dev/) v3.3.0 | Media request portal and discovery (Overseerr/Jellyseerr successor) |
| [doplarr](https://github.com/kiranshila/Doplarr) v3.7.0 | Discord slash-command bot for requesting movies and TV shows via Seerr |

### Internal

| App | Description |
|-----|-------------|
| [bazarr](https://www.bazarr.media/) v1.5.6 | Automatic subtitle management |
| [maintainerr](https://github.com/Maintainerr/Maintainerr) v3.13.0 | Rule-based media cleanup and rotation for Plex/Jellyfin libraries |
| [prowlarr](https://prowlarr.com/) v2.3.5 | Indexer manager — syncs indexers to Radarr and Sonarr |
| [radarr](https://radarr.video/) v6.2.0 | Movie library automation (root: `/homelab-storage/movies`) |
| [sonarr](https://sonarr.tv/) v4.0.17 | TV series library automation (root: `/homelab-storage/tv`) |
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

`k8s-gateway` resolves `*.homelab.local` dynamically from Ingress and Service resources. However, macOS `/etc/resolver` does not support custom DNS ports, and k8s-gateway's LoadBalancer IP is not directly routable from macOS on k3d.

Instead, add `/etc/hosts` entries pointing each `*.homelab.local` hostname to the k3d serverlb container IP (`192.168.97.4`), which proxies ports 80/443 into the cluster via Traefik. After editing:

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

## Cluster Recovery

If the k3d cluster is restarted and nodes lose connectivity (flannel IP drift, stale taints, etc.), `scripts/k3d-healthcheck.sh` detects and corrects flannel annotation mismatches and verifies node readiness. It runs automatically via a macOS LaunchAgent on cluster restart. To trigger it manually:

```bash
bash scripts/k3d-healthcheck.sh
```

