# Self-Managing Kubernetes Homelab w/ ArgoCD

Applications are divided into ArgoCD projects by their respective types.

- `setup` - Required base components used to operate the cluster and deployments.
  - ArgoCD Application Definitions: `argocd/applications/setup`
  - Configurations: `configs/setup/`
- `external` - Externally facing applications.
  - ArgoCD Application Definitions: `argocd/applications/external`
  - Configurations: `configs/external/`
- `internal` - Internal-only applications.
  - ArgoCD Application Definitions: `argocd/applications/internal`
  - Configurations: `configs/internal/`

## Applications

🔄 [`app-of-apps`](argocd/app-of-apps.yaml)

### Setup

- 🔵 [`argocd`](https://argoproj.github.io/cd/) - The GitOps operator responsible for managing the cluster
- 🔐 [`cert-manager`](https://cert-manager.io/) - Automatic SSL certificate generation using self-signed certificates
- 🔒 [`external-secrets`](https://external-secrets.io/) - Sync secrets from external secret management systems
- 🌐 [`k8s-gateway`](https://github.com/ori-edge/k8s_gateway) - CoreDNS controller plugin
- ⚖️ [`metallb`](https://metallb.universe.tf/) - A loadbalancer for non-cloud deployments
- 📊 [`metrics-server`](https://github.com/kubernetes-sigs/metrics-server) - Reports resource usage when running `kubectl top`
- 🚀 [`nginx-ingress`](https://github.com/kubernetes/ingress-nginx) - The ingress controller for the cluster (official Kubernetes ingress)
- 🔐 [`sealed-secrets`](https://github.com/bitnami-labs/sealed-secrets) - A controller for encrypting and decrypting secrets

### External

- 🎬 [`ombi`](https://ombi.io/) - A multimedia request platform for Plex

### Internal

- ⬇️ [`nzbget`](https://nzbget.net/) - A Usenet download platform
- 🎥 [`radarr`](https://radarr.video/) - Automatically search, download, and manage movies
- 📺 [`sonarr`](https://sonarr.tv/) - Automatically search, download, and manage television series
- 🔐 [`sealed-secrets-ui`](https://github.com/komodor-io/sealed-secrets-ui) - Web UI for managing sealed secrets
- ⚙️ [`tdarr`](https://tdarr.io/) - An automatic multimedia transcoder
- 📝 [`bazarr`](https://www.bazarr.media/) - Automatically search, download, and manage subtitles

## Bootstrapping

ArgoCD needs to be manually bootstrapped before it can self-manage. The only prerequisite is a Kubernetes cluster with a CNI installed. All other required components will be installed after bootstrapping.

```bash
kubectl apply -k configs/setup/argocd/
kubectl apply -f argocd/app-of-apps.yaml -n argocd
```

The above commands will deploy ArgoCD and the `app-of-apps` application which will be used to discover and deploy all other applications out of this repository. From this point forward, ArgoCD will also self-manage. Any updates to `configs/setup/argocd/` will be automatically discovered and applied.

## Accessing ArgoCD

Once bootstrapped, ArgoCD is available at:

```
https://argocd.homelab.local
```

The initial admin password can be retrieved with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Secrets

All secrets are encrypted and stored in this repository using [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) by Bitnami. Only the sealing key stored on the cluster can decrypt these secrets. If you are using this repository as the basis for your own homelab or Kubernetes cluster, you will need to seal your own secrets and replace the encrypted ones in this repository. As a result, if you try to deploy the applications contained in this repository using my configurations as-is, most applications will not function correctly due to missing secrets.

