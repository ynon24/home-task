#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting cleanup and redeployment process...${NC}"

# Set defaults
RESOURCE_GROUP="bitcoin-home-task"
CLUSTER_NAME="bitcoin-cluster"

# Check if currently connected to the cluster
if kubectl config current-context | grep -q "$CLUSTER_NAME"; then
    echo -e "${YELLOW}Switching away from $CLUSTER_NAME context...${NC}"
    kubectl config use-context docker-desktop 2>/dev/null || true
fi

# Remove output directory
if [ -d "_output/$CLUSTER_NAME" ]; then
    echo -e "${YELLOW}Removing output directory...${NC}"
    rm -rf "_output/$CLUSTER_NAME"
fi

# Check if resource group exists
if az group show --name $RESOURCE_GROUP &>/dev/null; then
    echo -e "${YELLOW}Deleting resource group $RESOURCE_GROUP...${NC}"
    az group delete --name $RESOURCE_GROUP --yes --no-wait
    
    # Wait for deletion
    while az group show --name $RESOURCE_GROUP &>/dev/null; do
        echo -n "."
        sleep 10
    done
    echo -e "\n${GREEN}Resource group deleted successfully!${NC}"
else
    echo -e "${GREEN}Resource group doesn't exist, skipping deletion.${NC}"
fi

# Clean up kubeconfig
echo -e "${YELLOW}Cleaning up kubeconfig...${NC}"
kubectl config delete-context $CLUSTER_NAME 2>/dev/null || true
kubectl config delete-cluster $CLUSTER_NAME 2>/dev/null || true
kubectl config delete-user $CLUSTER_NAME-admin 2>/dev/null || true

echo -e "${GREEN}Cleanup complete!${NC}"

# Ask if user wants to redeploy
read -p "Do you want to redeploy the cluster now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Starting redeployment...${NC}"
    
    # Run setup
    if [ -f "./setup.sh" ]; then
        echo -e "${YELLOW}Running setup...${NC}"
        ./setup.sh
    else
        echo -e "${RED}setup.sh not found!${NC}"
        exit 1
    fi
    
    # Run deploy
    if [ -f "./deploy.sh" ]; then
        echo -e "${YELLOW}Running deployment...${NC}"
        ./deploy.sh
    else
        echo -e "${RED}deploy.sh not found!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Redeployment complete!${NC}"
else
    echo -e "${YELLOW}Skipping redeployment. Run './setup.sh && ./deploy.sh' when ready.${NC}"
fi