# Requestrr

Requestrr is a Discord bot that lets users request movies and TV shows. It is deployed as a Kubernetes workload in the `requestrr` namespace and integrated with Ombi, Sonarr, and Radarr via internal cluster DNS.

## Access

| Method | URL |
|--------|-----|
| Browser (HTTPS) | `https://requestrr.homelab.local` |
| Port-forward | `kubectl port-forward -n requestrr svc/requestrr 4545:4545` → `http://localhost:4545` |

## Bot Commands

```text
!request movie The Matrix
!request show The Office
!request show Breaking Bad 3-5
!request show Stranger Things latest
```

## Configuration

Requestrr configuration is managed by External Secrets — there is no ConfigMap.

| Resource | File |
|----------|------|
| ExternalSecret definition | `configs/external/requestrr/external-secret.yaml` |
| Generated Kubernetes Secret | `requestrr-config-secret` (in `requestrr` namespace) |

**First-run behavior**: on initial startup, an init container seeds `settings.json` on the persistent config volume from the generated secret. On subsequent restarts the existing `settings.json` is preserved — secret updates do not automatically overwrite it.

### Required Infisical Keys

| Key | Used for |
|-----|----------|
| `discord_bot_token` | Bot authentication |
| `discord_client_id` | OAuth2 invite link |
| `ombi_api_key` | Request forwarding |
| `sonarr_api_key` | TV show automation — must match Sonarr's current API key |
| `radarr_api_key` | Movie automation — must match Radarr's current API key |

Secrets sync every 15 minutes.

## Discord Bot Setup

1. Create a Discord application and bot at [discord.com/developers](https://discord.com/developers/applications).
2. Copy the bot token and client ID into Infisical using the key names above.
3. Invite the bot to your server:

```text
https://discord.com/api/oauth2/authorize?client_id=YOUR_CLIENT_ID&permissions=8&scope=bot
```

## Resetting Configuration

If you need Requestrr to re-seed `settings.json` from the current secret (e.g. after rotating API keys):

1. Optionally back up the current config from the PVC.
2. Delete the `settings.json` file from the config volume (or recreate the PVC).
3. Restart the deployment:

```bash
kubectl rollout restart deployment/requestrr -n requestrr
```

For day-to-day settings changes, use the Requestrr web UI — the persisted `settings.json` is the live source of truth after first run.

## Troubleshooting

```bash
# Pod and secret status
kubectl get pods -n requestrr
kubectl describe externalsecret -n requestrr requestrr-secrets
kubectl get secret -n requestrr requestrr-config-secret

# Logs
kubectl logs -n requestrr -f deploy/requestrr --tail=100

# Ingress
kubectl describe ingress -n requestrr requestrr

# Dependent services
kubectl get pods -n ombi -n sonarr -n radarr
```

## Request Status

| Service | URL |
|---------|-----|
| Ombi (request queue) | `https://ombi.homelab.local` |
| Sonarr (TV activity) | `https://sonarr.homelab.local` |
| Radarr (movie activity) | `https://radarr.homelab.local` |

For architecture and project layout, see [README.md](README.md).
