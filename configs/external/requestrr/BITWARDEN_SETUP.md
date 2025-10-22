# Requestrr Bitwarden Secret Setup Guide

This document explains how to add Requestrr credentials to Bitwarden so they can be automatically synced into your Kubernetes cluster via ExternalSecrets.

## Overview

The `external-secret.yaml` manifest is configured to pull secrets from a Bitwarden item called `requestrr`. The secrets will be stored in Kubernetes as a Secret named `requestrr-discord-secrets` and automatically injected into the ConfigMap and deployment.

## Prerequisites

1. Bitwarden CLI is running in your cluster (see `/configs/setup/external-secrets/bitwarden/`)
2. You have access to your Bitwarden vault
3. You have gathered all required API keys:
   - Discord Bot Token
   - Discord Client ID
   - Ombi API Key
   - Sonarr API Key
   - Radarr API Key

## Steps to Add Secrets to Bitwarden

### Option 1: Via Bitwarden Web Vault (Recommended for beginners)

1. **Log in to Bitwarden**: Go to https://vault.bitwarden.com
2. **Create a new item**: Click "+ Add Item" → Select "Login"
3. **Fill in the details**:
   - **Name**: `requestrr`
   - **Username**: (can be anything, e.g., `requestrr-bot`)
   - **Password**: (not used, can leave blank)

4. **Add Custom Fields** (scroll down to "Custom Fields" section):
   - Click "New Custom Field"
   - Add these fields (type: Text):
     - `discord_bot_token` = your Discord bot token
     - `discord_client_id` = your Discord client ID
     - `ombi_api_key` = your Ombi API key
     - `sonarr_api_key` = your Sonarr API key
     - `radarr_api_key` = your Radarr API key

5. **Save**: Click "Save" button

### Option 2: Via Bitwarden CLI (Advanced)

If you prefer using the CLI:

```bash
# Create the secret item
bw create object itemTemplate > requestrr_template.json

# Edit the template with your values
nano requestrr_template.json
```

Then populate with:
```json
{
  "object": "itemTemplate",
  "type": 1,
  "name": "requestrr",
  "login": {
    "username": "requestrr-bot"
  },
  "fields": [
    {
      "type": 0,
      "name": "discord_bot_token",
      "value": "YOUR_DISCORD_BOT_TOKEN"
    },
    {
      "type": 0,
      "name": "discord_client_id",
      "value": "YOUR_DISCORD_CLIENT_ID"
    },
    {
      "type": 0,
      "name": "ombi_api_key",
      "value": "YOUR_OMBI_API_KEY"
    },
    {
      "type": 0,
      "name": "sonarr_api_key",
      "value": "YOUR_SONARR_API_KEY"
    },
    {
      "type": 0,
      "name": "radarr_api_key",
      "value": "YOUR_RADARR_API_KEY"
    }
  ]
}
```

Then save:
```bash
bw create item requestrr_template.json
```

## How ExternalSecrets Works

Once the secrets are added to Bitwarden:

1. **ExternalSecret watches** the Bitwarden item `requestrr`
2. **Bitwarden CLI container** (running in `kube-system` namespace) provides a webhook API that queries Bitwarden
3. **External Secrets operator** makes HTTP requests to the webhook to fetch the custom field values
4. **Kubernetes Secret** `requestrr-discord-secrets` is created/updated with the fetched values
5. **Requestrr Deployment** reads these values as environment variables via `valueFrom.secretKeyRef`
6. **Config.json** uses environment variable substitution to populate the actual API keys

## Verification

Check that the secret was created:

```bash
kubectl get secret -n requestrr requestrr-discord-secrets
kubectl describe secret -n requestrr requestrr-discord-secrets
```

View the secret values (WARNING: this will show unencrypted secrets):

```bash
kubectl get secret -n requestrr requestrr-discord-secrets -o jsonpath='{.data.bot_token}' | base64 -d
```

Check Requestrr pod logs to see if it's connecting to Discord:

```bash
kubectl logs -n requestrr -f deploy/requestrr
```

## Troubleshooting

### Secret not appearing
- Check that Bitwarden CLI is healthy: `kubectl get pods -n kube-system | grep bitwarden`
- Verify the item name is exactly `requestrr` (case-sensitive)
- Verify custom field names match exactly (they're case-sensitive)

### Requestrr still not connecting
- Check ExternalSecret status: `kubectl describe externalsecret -n requestrr requestrr-secrets`
- Check pod logs: `kubectl logs -n requestrr -f deploy/requestrr`
- Verify the values in the Kubernetes Secret: `kubectl describe secret -n requestrr requestrr-discord-secrets`

### Bitwarden CLI webhook errors
Check Bitwarden CLI logs: `kubectl logs -n kube-system -f deploy/bitwarden-cli`

## Security Notes

- Secrets are stored encrypted in the Kubernetes cluster using sealed-secrets
- Only the Bitwarden CLI pod can read values from Bitwarden vault
- API keys are never stored in plain text in your repository or ConfigMap
- Rotate your Discord bot token or API keys in Bitwarden, and the cluster will automatically sync the updated values (within 15 minutes)
