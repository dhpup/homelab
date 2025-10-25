# Infisical Cloud Migration Guide

This guide shows how to use Infisical's **free cloud tier** instead of self-hosting.

## Why Infisical Cloud?

✅ **No infrastructure to manage** - Just use the cloud service  
✅ **Free tier** - Unlimited secrets, 5 users, unlimited projects  
✅ **Faster setup** - No need to deploy Helm chart  
✅ **Always updated** - Managed by Infisical team  
✅ **High availability** - Production-ready SLA  

## Architecture (Cloud)

```
┌───────────────────────────────────────────────────┐
│ Infisical Cloud (app.infisical.com)              │
│ ├── Your Organization                             │
│ └── Project: homelab-prod                         │
│     ├── Environment: prod                         │
│     └── Secrets:                                  │
│         ├── discord_bot_token                     │
│         ├── discord_client_id                     │
│         ├── ombi_api_key                          │
│         ├── sonarr_api_key                        │
│         └── radarr_api_key                        │
└───────────────────────────────────────────────────┘
                    ↓ API (TLS)
┌───────────────────────────────────────────────────┐
│ Your k3d Cluster                                  │
│                                                    │
│ External Secrets Operator                         │
│ └── ClusterSecretStore: infisical-store          │
│     └── Points to: app.infisical.com/api         │
│                                                    │
│ Requestrr Namespace                               │
│ └── ExternalSecret: requestrr-secrets            │
│     └── Syncs from: infisical-store              │
└───────────────────────────────────────────────────┘
```

## Prerequisites

- Infisical Cloud account (free)
- Sealed Secrets controller running
- kubectl access to cluster
- kubeseal CLI installed

## Step 1: Sign Up for Infisical Cloud

1. Go to https://app.infisical.com/signup
2. Create account (free tier)
3. Create organization (e.g., "Homelab")

## Step 2: Create Project

1. Click **"Create Project"**
2. Name: `homelab-prod`
3. Note your **Project ID**:
   - Go to **Project Settings**
   - Copy the Project ID (format: `6543a1b2c3d4e5f6g7h8i9j0`)

## Step 3: Create Universal Auth Identity

1. In your project, go to:
   **Settings → Access Control → Machine Identities**

2. Click **"Create Identity"**:
   - Name: `external-secrets-operator`
   - Role: `Developer` (read secrets)

3. Click **"Add Universal Auth"**:
   - Access Token TTL: `2592000` (30 days)
   - Click **Create**

4. **Copy the credentials** (you'll only see them once):
   - Client ID
   - Client Secret

## Step 4: Add Secrets to Infisical Cloud

1. Go to your project → **Secrets** tab
2. Select environment: `prod`
3. Add each secret:

| Secret Name | Value (from your Bitwarden) |
|-------------|----------------------------|
| `discord_bot_token` | Your Discord bot token |
| `discord_client_id` | Your Discord client ID |
| `ombi_api_key` | Your Ombi API key |
| `sonarr_api_key` | Your Sonarr API key |
| `radarr_api_key` | Your Radarr API key |

## Step 5: Create Sealed Secret for Auth

```bash
cd /Users/daneko/devops/homelab

# Create the secret (replace with your actual values from Step 3)
kubectl create secret generic infisical-auth \
  --from-literal=clientId='YOUR_CLIENT_ID_HERE' \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET_HERE' \
  --namespace=external-secrets \
  --dry-run=client -o yaml | \
kubeseal --format=yaml > configs/setup/external-secrets/infisical/infisical-auth-sealed-secret.yaml

# Commit
git add configs/setup/external-secrets/infisical/infisical-auth-sealed-secret.yaml
git commit -m "feat: add Infisical Cloud auth credentials (sealed)"
git push
```

## Step 6: Update SecretStore with Project ID

Edit `configs/setup/external-secrets/infisical/secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: infisical-store
spec:
  provider:
    infisical:
      auth:
        universalAuth:
          credentialsRef:
            clientId:
              name: infisical-auth
              namespace: external-secrets
              key: clientId
            clientSecret:
              name: infisical-auth
              namespace: external-secrets
              key: clientSecret
      hostAPI: "https://app.infisical.com/api"
      projectId: "YOUR_PROJECT_ID_HERE"  # ← UPDATE THIS
      environment: "prod"
      secretsPath: "/"
```

Commit and push:

```bash
git add configs/setup/external-secrets/infisical/secret-store.yaml
git commit -m "feat: configure Infisical Cloud project ID"
git push
```

ArgoCD will sync the changes automatically.

## Step 7: Update Requestrr to Use Infisical

Edit `configs/external/requestrr/external-secret.yaml`:

```yaml
spec:
  secretStoreRef:
    name: infisical-store  # Changed from: bitwarden-fields
    kind: ClusterSecretStore
```

The rest of the file stays the same.

Commit and push:

```bash
git add configs/external/requestrr/external-secret.yaml
git commit -m "feat: migrate Requestrr to Infisical Cloud secrets"
git push
```

## Step 8: Verify

```bash
# Check if Infisical SecretStore is ready
kubectl get clustersecretstore infisical-store
# Should show: READY=True

# Check if ExternalSecret syncs
kubectl get externalsecret -n requestrr
# Should show: STATUS=SecretSynced

# Check if secret is created
kubectl get secret -n requestrr requestrr-config-secret
# Should exist

# Check Requestrr pod
kubectl get pods -n requestrr
# Should be Running

kubectl logs -n requestrr -l app=requestrr
# Should show successful Discord/Ombi connections
```

## Step 9: Remove Bitwarden (Optional)

Once everything works:

```bash
# Remove Bitwarden deployment
kubectl delete deployment -n external-secrets bitwarden-cli
kubectl delete service -n external-secrets bitwarden-cli

# Remove from external-secrets ArgoCD app
# Edit: argocd/applications/setup/external-secrets.yaml
# Remove the bitwarden path source

# Commit
git add argocd/applications/setup/external-secrets.yaml
git commit -m "chore: remove deprecated Bitwarden webhook"
git push
```

## What You DON'T Need (Cloud vs Self-Hosted)

❌ **NO Infisical Helm deployment** - Cloud handles this  
❌ **NO PostgreSQL** - Managed by Infisical  
❌ **NO Redis** - Managed by Infisical  
❌ **NO Ingress** - Access via app.infisical.com  
❌ **NO infrastructure management** - Just use the API  

**You only need:**
1. ClusterSecretStore pointing to cloud API
2. Sealed auth secret
3. ExternalSecrets to fetch your secrets

## Free Tier Limits

| Feature | Free Tier |
|---------|-----------|
| **Projects** | Unlimited |
| **Secrets** | Unlimited |
| **Environments** | Unlimited |
| **Team members** | 5 users |
| **Secret versions** | Last 5 versions |
| **Audit logs** | 30 days |
| **API calls** | Unlimited |

Perfect for homelab use! 🎉

## Troubleshooting

### Connection test from cluster

```bash
# Test connectivity to Infisical Cloud
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -v https://app.infisical.com/api/status

# Should return: {"message":"Ok"}
```

### Auth errors

```bash
# Verify sealed secret was created
kubectl get sealedsecret -n external-secrets infisical-auth

# Check if secret exists
kubectl get secret -n external-secrets infisical-auth

# Check clientId format
kubectl get secret -n external-secrets infisical-auth -o jsonpath='{.data.clientId}' | base64 -d
```

### SecretStore not ready

```bash
# Check external-secrets operator logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets

# Describe the SecretStore
kubectl describe clustersecretstore infisical-store
```

## Cost Comparison

| Option | Cost | Maintenance | Features |
|--------|------|-------------|----------|
| **Infisical Cloud** | $0/mo | None | Full features |
| **Self-hosted** | Infrastructure costs | Regular updates | Full features |
| **Bitwarden + webhook** | $0-10/mo | Wrapper maintenance | Basic only |

For a homelab, **Infisical Cloud free tier is the best option**. No maintenance, full features, zero cost.

## Reference

- Infisical Cloud: https://app.infisical.com
- Documentation: https://infisical.com/docs
- ESO Provider Docs: https://external-secrets.io/latest/provider/infisical/
