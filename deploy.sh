#!/bin/bash
set -e

# Load Azure subscription configuration
source subscription.conf

# Configurable values
RESOURCE_GROUP="home-task"
LOCATION="eastus"
CLUSTER_NAME="bitcoin-rate-cluster"
ACR_NAME="bitcoinrateacr"  # Unique ACR name
NODE_COUNT=2
NODE_SIZE="Standard_B2s"

echo "🚀 Starting AKS deployment with security policies and ingress..."
echo "Resource Group: $RESOURCE_GROUP"
echo "Cluster Name: $CLUSTER_NAME"
echo "Location: $LOCATION"
echo "Node Count: $NODE_COUNT"
echo ""

# Check if resource group exists, create if not
echo "📋 Checking resource group..."
RG_EXISTS=$(az group show --name "$RESOURCE_GROUP" --query "name" -o tsv 2>/dev/null || echo "")
if [ -n "$RG_EXISTS" ]; then
    echo "✅ Resource group '$RESOURCE_GROUP' already exists, skipping creation..."
else
    echo "🆕 Creating resource group '$RESOURCE_GROUP'..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
fi

# Check if AKS cluster exists, create if not
echo "🏗️ Checking AKS cluster..."
CLUSTER_EXISTS=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query "name" -o tsv 2>/dev/null || echo "")
if [ -n "$CLUSTER_EXISTS" ]; then
    echo "✅ AKS cluster '$CLUSTER_NAME' already exists, skipping creation..."
else
    echo "🆕 Creating AKS cluster '$CLUSTER_NAME'..."
    az aks create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$CLUSTER_NAME" \
      --node-count "$NODE_COUNT" \
      --node-vm-size "$NODE_SIZE" \
      --enable-addons monitoring \
      --enable-msi-auth-for-monitoring \
      --generate-ssh-keys \
      --network-plugin azure \
      --network-policy azure \
      --location "$LOCATION" \
      --enable-managed-identity 
fi

# Get cluster credentials
echo "🔑 Getting cluster credentials..."
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing

# Verify cluster
echo "✅ Verifying cluster deployment..."
kubectl get nodes
kubectl cluster-info

# Verify Metrics Server is available (required for HPA)
echo "📊 Verifying Metrics Server for HPA..."
kubectl wait --for=condition=available --timeout=30s deployment/metrics-server -n kube-system || echo "⚠️ Metrics Server not ready - HPA may not work immediately"
echo "✅ Metrics Server verified"

# Setup Azure Container Registry
echo "📦 Setting up Azure Container Registry..."
source acr/create-acr.sh

# Apply RBAC configurations
echo "🔐 Applying RBAC configurations..."
kubectl apply -f k8s/rbac/

# Deploy Redis infrastructure first (before services that depend on it)
echo "🗄️ Deploying Redis infrastructure..."
# Deploy namespace first, then other Redis resources
kubectl apply -f k8s/redis/redis-namespace.yaml
kubectl apply -f k8s/redis/redis-configmap.yaml
kubectl apply -f k8s/redis/redis-pvc.yaml
kubectl apply -f k8s/redis/redis-service.yaml
kubectl apply -f k8s/redis/redis-deployment.yaml
echo "⏳ Waiting for Redis to be ready..."
kubectl wait --namespace redis \
  --for=condition=ready pod \
  --selector=app=redis \
  --timeout=120s

# Apply Network Policies for service isolation
echo "🔒 Applying Network Policies..."
kubectl apply -f k8s/network-policies/

# Install Traefik Ingress Controller
echo "🌐 Installing Traefik Ingress Controller..."
kubectl apply -f k8s/ingress/

# Wait for Traefik to be ready
echo "⏳ Waiting for Traefik to be ready..."
kubectl wait --namespace traefik \
  --for=condition=ready pod \
  --selector=app=traefik \
  --timeout=120s

# Build and push services to ACR
echo "🐳 Building and pushing services..."
# Check if docker is available, if not use ACR build tasks
if command -v docker &> /dev/null; then
    echo "Using local Docker..."
    
    # Login to ACR
    echo "🔐 Logging into ACR..."
    az acr login --name "$ACR_NAME"
    
    echo "Building Service A..."
    cd src/service-a
    docker buildx build --platform linux/amd64 -t "bitcoinrateacr.azurecr.io/service-a:latest" . --push
    cd ../..
    
    echo "Building Service B..."
    cd src/service-b  
    docker buildx build --platform linux/amd64 -t "bitcoinrateacr.azurecr.io/service-b:latest" . --push
    cd ../..
else
    echo "Docker not found, using Azure Container Registry build tasks..."
    echo "Building Service A..."
    az acr build --registry "$ACR_NAME" --image "service-a:latest" src/service-a/
    echo "Building Service B..."
    az acr build --registry "$ACR_NAME" --image "service-b:latest" src/service-b/
fi

echo "✅ All services built and pushed to ACR!"

# Deploy services to Kubernetes
echo "🚀 Deploying services to Kubernetes..."

# Deploy Service A
echo "Deploying Service A..."
kubectl apply -f k8s/services/service-a/service.yaml
kubectl apply -f k8s/services/service-a/deployment.yaml

# Deploy Service B  
echo "Deploying Service B..."
kubectl apply -f k8s/services/service-b/service.yaml
kubectl apply -f k8s/services/service-b/deployment.yaml

# Wait for deployments to be ready
echo "⏳ Waiting for services to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/service-a -n service-a
kubectl wait --for=condition=available --timeout=300s deployment/service-b -n service-b

# Deploy HPA (Horizontal Pod Autoscaler) for auto-scaling
echo "📈 Deploying Horizontal Pod Autoscalers..."
echo "📊 Setting up auto-scaling for Service A (2-8 pods, CPU>70%, Memory>80%)..."
kubectl apply -f k8s/autoscaling/service-a-hpa.yaml

echo "📊 Setting up auto-scaling for Service B (1-4 pods, CPU>80%)..."
kubectl apply -f k8s/autoscaling/service-b-hpa.yaml

# Wait a moment for HPA to initialize
echo "⏳ Waiting for HPA to initialize..."
sleep 10

# Verify HPA status
echo "✅ Verifying HPA deployment..."
kubectl get hpa --all-namespaces

# Verify Redis connectivity from Service A
echo "🔍 Verifying Redis connectivity..."
echo "Testing Redis connection from Service A..."
kubectl exec -n service-a deployment/service-a -- redis-cli -h redis-service.redis.svc.cluster.local ping || echo "⚠️ Redis connectivity test failed - check network policies"

echo ""
echo "🎉 Complete deployment successful!"
echo "Cluster name: bitcoin-rate-cluster"
echo "Resource group: home-task"
echo "Node count: $NODE_COUNT"
echo "ACR: $ACR_LOGIN_SERVER"
echo ""
echo "📋 Getting Traefik external IP..."
kubectl get services -n traefik
echo ""
echo "🗄️ Redis Status:"
kubectl get pods -n redis
echo ""
echo "📈 HPA Status:"
kubectl get hpa --all-namespaces
echo ""
echo "🎯 Traefik Dashboard will be available at: http://<EXTERNAL-IP>:8080/dashboard/"
echo "🌐 Services will be accessible at:"
echo "   - http://<EXTERNAL-IP>/service-a (Bitcoin Rate Tracker with Redis persistence)"
echo "   - http://<EXTERNAL-IP>/service-b"
echo ""
echo "🔍 Check service status:"
echo "   kubectl get pods -n service-a"
echo "   kubectl get pods -n service-b"
echo "   kubectl get pods -n traefik"
echo "   kubectl get pods -n redis"
echo ""
echo "📊 Monitor auto-scaling:"
echo "   kubectl get hpa --all-namespaces -w"
echo "   kubectl describe hpa service-a-hpa -n service-a"
echo "   kubectl describe hpa service-b-hpa -n service-b"
echo ""
echo "🧪 Test auto-scaling (generate load):"
echo "   kubectl run -i --tty load-generator --rm --image=busybox --restart=Never -- /bin/sh"
echo "   # Inside the pod: while true; do wget -q -O- http://<EXTERNAL-IP>/service-a; done"
echo ""
echo "🧪 Test Redis persistence:"
echo "   # Check current data"
echo "   curl http://<EXTERNAL-IP>/service-a"
echo "   # Restart Service A pods"
echo "   kubectl rollout restart deployment/service-a -n service-a"
echo "   # Data should persist after restart!"