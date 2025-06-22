#!/bin/bash
set -e

# Get ACR info from environment or discover it
if [ -z "$ACR_LOGIN_SERVER" ]; then
    RESOURCE_GROUP="home-task"
    ACR_NAME=$(az acr list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "loginServer" -o tsv)
fi

echo "🐳 Building Service B for AMD64 architecture..."
echo "ACR: $ACR_LOGIN_SERVER"

# Build for AMD64 platform and push
docker buildx build --platform linux/amd64 -t "${ACR_LOGIN_SERVER}/service-b:latest" . --push

echo "✅ Service B pushed successfully!"
echo "Image: ${ACR_LOGIN_SERVER}/service-b:latest"
echo "Platform: linux/amd64"