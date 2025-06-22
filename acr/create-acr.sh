#!/bin/bash
set -e

echo "🏗️  Setting up Azure Container Registry..."

# Check if ACR already exists
ACR_EXISTS=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "name" -o tsv 2>/dev/null || echo "")

if [ -n "$ACR_EXISTS" ]; then
    echo "✅ ACR '$ACR_NAME' already exists, reusing..."
else
    echo "🆕 Creating new ACR '$ACR_NAME'..."
    az acr create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$ACR_NAME" \
      --sku Basic \
      --location "$LOCATION"
fi

# Check if ACR is already attached to cluster
echo "🔗 Checking ACR attachment to AKS cluster..."

# Always try to attach (it's idempotent - won't fail if already attached)
echo "🔗 Ensuring ACR is attached to AKS cluster..."
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --attach-acr "$ACR_NAME"

# Get ACR login server
# ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "loginServer" -o tsv)

echo "✅ ACR setup complete!"
# echo "ACR Name: $ACR_NAME"
# echo "ACR Login Server: $ACR_LOGIN_SERVER"

# Export for use in parent script - this is the key fix
# export ACR_LOGIN_SERVER
# export ACR_NAME

# Also echo for verification
# echo "Exported ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER"