#!/bin/bash
set -euo pipefail

CLUSTER="order-fulfillment-dev"
REGION="eu-west-2"
ACCOUNT="989346120260"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
PROJECT="order-fulfillment"
DOMAIN="orders.hasanali.uk"
EMAIL="hasan_ali75@outlook.com"
HOSTED_ZONE_ID="Z044516511F47YV4NV151"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Order Fulfillment Platform Bootstrap       ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: Connect to cluster ────────────────────────────────────────────────
echo "==> [1/10] Connecting to EKS cluster"
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl get nodes

# ── Step 2: Install EBS CSI StorageClass ─────────────────────────────────────
echo "==> [2/10] Creating gp3 StorageClass"
kubectl apply -f k8s/base/storageclass.yaml

# ── Step 3: Install NGINX Ingress ─────────────────────────────────────────────
echo "==> [3/10] Installing NGINX Ingress Controller"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 5m

echo "==> NGINX Ingress ELB:"
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo ""

# ── Step 4: Install CertManager ───────────────────────────────────────────────
echo "==> [4/10] Installing CertManager"
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m

# ── Step 5: Create ClusterIssuer ─────────────────────────────────────────────
echo "==> [5/10] Creating Let's Encrypt ClusterIssuer"
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          route53:
            region: ${REGION}
            hostedZoneID: ${HOSTED_ZONE_ID}
EOF

# ── Step 6: Install ExternalDNS ───────────────────────────────────────────────
echo "==> [6/10] Installing ExternalDNS"
EXTERNAL_DNS_ROLE=$(aws iam get-role \
  --role-name ${PROJECT}-dev-external-dns \
  --query "Role.Arn" --output text)

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm upgrade --install external-dns external-dns/external-dns \
  --namespace external-dns \
  --create-namespace \
  --set provider=aws \
  --set aws.zoneType=public \
  --set txtOwnerId=${CLUSTER} \
  --set "domainFilters[0]=hasanali.uk" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${EXTERNAL_DNS_ROLE}" \
  --set policy=sync \
  --set interval=1m \
  --wait --timeout 5m

# ── Step 7: Install Karpenter ─────────────────────────────────────────────────
echo "==> [7/10] Installing Karpenter"
KARPENTER_ROLE=$(aws iam get-role \
  --role-name ${PROJECT}-dev-karpenter-controller \
  --query "Role.Arn" --output text)

KARPENTER_VERSION="1.0.0"
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version ${KARPENTER_VERSION} \
  --namespace karpenter \
  --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${KARPENTER_ROLE}" \
  --set settings.clusterName=${CLUSTER} \
  --set settings.interruptionQueue=${CLUSTER}-karpenter \
  --wait --timeout 5m

# Apply NodePool
CLUSTER_NAME=$CLUSTER
NODE_ROLE=$(aws iam get-role \
  --role-name ${PROJECT}-dev-nodes \
  --query "Role.RoleName" --output text)

sed "s/REPLACE_WITH_NODE_ROLE_NAME/${NODE_ROLE}/g; \
     s/REPLACE_WITH_CLUSTER_NAME/${CLUSTER}/g" \
  k8s/karpenter/nodepool.yaml | kubectl apply -f -

# ── Step 8: Install ArgoCD ────────────────────────────────────────────────────
echo "==> [8/10] Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for ArgoCD..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=120s

# ── Step 9: Install Prometheus stack ─────────────────────────────────────────
echo "==> [9/10] Installing kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f monitoring/values-prometheus.yaml \
  --wait --timeout 10m

# ── Step 10: Build and deploy app ─────────────────────────────────────────────
echo "==> [10/10] Building and pushing images"
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $REGISTRY

SHA=$(git rev-parse --short HEAD)

for svc in api-gateway order-service inventory-service payment-service \
           notification-service shipping-service worker scheduler dashboard-api; do
  echo "==> Building $svc..."
  docker build \
    --platform linux/amd64 \
    -f services/${svc}/Dockerfile \
    -t ${REGISTRY}/${PROJECT}/${svc}:${SHA} \
    .
  docker push ${REGISTRY}/${PROJECT}/${svc}:${SHA}
  echo "==> Pushed ${svc}:${SHA}"
done

# Update values with SHA
sed -i "s/imageTag:.*/imageTag: ${SHA}/" \
  k8s/charts/order-fulfillment/values-dev.yaml

# Get IRSA role ARNs from Terraform
echo "==> Getting IRSA role ARNs"
cd infra/state/addons
IRSA=$(terraform output -json irsa)
cd ../../..

# Deploy via Helm
echo "==> Deploying application"
SQS_URL=$(cd infra/state/addons && terraform output -raw sqs_queue_url)

helm upgrade --install order-fulfillment \
  k8s/charts/order-fulfillment \
  -f k8s/charts/order-fulfillment/values.yaml \
  -f k8s/charts/order-fulfillment/values-dev.yaml \
  --set sqsQueueUrl="${SQS_URL}" \
  --namespace order-fulfillment \
  --create-namespace \
  --wait --timeout 10m

# Apply ArgoCD project and app
kubectl apply -f k8s/argocd/project.yaml
kubectl apply -f k8s/argocd/app-of-apps.yaml

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║           Bootstrap Complete!                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "App URL:    https://${DOMAIN}"
echo "ArgoCD:     https://argocd.${DOMAIN}"
echo ""
echo "kubectl get pods -n order-fulfillment"
kubectl get pods -n order-fulfillment