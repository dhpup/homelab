#!/bin/bash
# Infisical Cloud Setup Helper
# This script helps you set up Infisical Cloud integration

set -e

echo "🚀 Infisical Cloud Setup for Homelab"
echo "======================================"
echo ""

# Step 1: Check prerequisites
echo "📋 Step 1: Checking prerequisites..."
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl first."
    exit 1
fi

if ! command -v kubeseal &> /dev/null; then
    echo "⚠️  kubeseal not found. Install with: brew install kubeseal"
    echo "   You'll need this to create sealed secrets."
    exit 1
fi

echo "✅ Prerequisites OK"
echo ""

# Step 2: Get credentials
echo "📝 Step 2: Enter your Infisical Cloud credentials"
echo ""
echo "First, sign up at: https://app.infisical.com/signup"
echo "Then create a project and Machine Identity (Universal Auth)"
echo ""
read -p "Enter your Client ID: " CLIENT_ID
read -sp "Enter your Client Secret: " CLIENT_SECRET
echo ""
read -p "Enter your Project ID: " PROJECT_ID
echo ""

# Step 3: Create sealed secret
echo ""
echo "🔐 Step 3: Creating sealed secret..."
kubectl create secret generic infisical-auth \
  --from-literal=clientId="$CLIENT_ID" \
  --from-literal=clientSecret="$CLIENT_SECRET" \
  --namespace=external-secrets \
  --dry-run=client -o yaml | \
kubeseal --format=yaml > configs/setup/external-secrets/infisical/infisical-auth-sealed-secret.yaml

echo "✅ Created: configs/setup/external-secrets/infisical/infisical-auth-sealed-secret.yaml"
echo ""

# Step 4: Update SecretStore
echo "📝 Step 4: Updating SecretStore with Project ID..."
sed -i.bak "s/projectId: \"\"/projectId: \"$PROJECT_ID\"/" configs/setup/external-secrets/infisical/secret-store.yaml
rm configs/setup/external-secrets/infisical/secret-store.yaml.bak
echo "✅ Updated: configs/setup/external-secrets/infisical/secret-store.yaml"
echo ""

# Step 5: Update Requestrr
echo "📝 Step 5: Updating Requestrr ExternalSecret..."
sed -i.bak "s/name: bitwarden-fields/name: infisical-store/" configs/external/requestrr/external-secret.yaml
rm configs/external/requestrr/external-secret.yaml.bak
echo "✅ Updated: configs/external/requestrr/external-secret.yaml"
echo ""

# Summary
echo "✨ Setup Complete!"
echo ""
echo "Next steps:"
echo "1. Add secrets to Infisical Cloud at: https://app.infisical.com"
echo "   Required secrets in 'prod' environment:"
echo "   - discord_bot_token"
echo "   - discord_client_id"
echo "   - ombi_api_key"
echo "   - sonarr_api_key"
echo "   - radarr_api_key"
echo ""
echo "2. Commit and push the changes:"
echo "   git add configs/setup/external-secrets/infisical/"
echo "   git add configs/external/requestrr/external-secret.yaml"
echo "   git commit -m 'feat: migrate to Infisical Cloud'"
echo "   git push"
echo ""
echo "3. Verify deployment:"
echo "   kubectl get clustersecretstore infisical-store"
echo "   kubectl get externalsecret -n requestrr"
echo "   kubectl get pods -n requestrr"
echo ""
