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

echo "🔗 Checking ACR attachment to AKS cluster..."

echo "🔗 Ensuring ACR is attached to AKS cluster..."
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --attach-acr "$ACR_NAME"

echo "✅ ACR setup complete!"
