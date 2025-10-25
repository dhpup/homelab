# Infisical Authentication Secret Template
# 
# This file provides a template for creating the Infisical auth secret.
# After deploying Infisical and creating a Universal Auth identity, 
# replace the placeholder values and create a SealedSecret.
#
# Steps:
# 1. Deploy Infisical via ArgoCD
# 2. Access Infisical UI at https://infisical.homelab.local
# 3. Create a new project (e.g., "homelab")
# 4. Go to Project Settings → Access Control → Service Tokens
# 5. Create a "Universal Auth" identity
# 6. Copy the Client ID and Client Secret
# 7. Create the secret and seal it:
#
#    kubectl create secret generic infisical-auth \
#      --from-literal=clientId='YOUR_CLIENT_ID' \
#      --from-literal=clientSecret='YOUR_CLIENT_SECRET' \
#      --namespace=external-secrets \
#      --dry-run=client -o yaml | \
#    kubeseal --format=yaml > infisical-auth-sealed-secret.yaml
#
# 8. Add the sealed secret file to this directory
# 9. Update the projectId in secret-store.yaml with your project ID
#
---
# Placeholder - replace with actual SealedSecret after setup
apiVersion: v1
kind: Secret
metadata:
  name: infisical-auth
  namespace: external-secrets
type: Opaque
stringData:
  clientId: "REPLACE_WITH_ACTUAL_CLIENT_ID"
  clientSecret: "REPLACE_WITH_ACTUAL_CLIENT_SECRET"
