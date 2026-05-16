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
echo "==> [1/11] Connecting to EKS cluster"
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl get nodes

# ── Get all IRSA roles upfront ────────────────────────────────────────────────
echo "==> Getting IRSA role ARNs"
IRSA=$(cd infra/state/addons && terraform output -json irsa)
EXTERNAL_DNS_ROLE=$(echo $IRSA | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['external_dns_role_arn'])")
CERT_MANAGER_ROLE=$(echo $IRSA | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['cert_manager_role_arn'])")
ORDER_ROLE=$(echo $IRSA        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['order_service_role_arn'])")
PAYMENT_ROLE=$(echo $IRSA      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['payment_service_role_arn'])")
SHIPPING_ROLE=$(echo $IRSA     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['shipping_service_role_arn'])")
WORKER_ROLE=$(echo $IRSA       | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['worker_role_arn'])")
NOTIF_ROLE=$(echo $IRSA        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['notification_service_role_arn'])")
SCHEDULER_ROLE=$(echo $IRSA    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['scheduler_role_arn'])")
SQS_URL=$(cd infra/state/addons && terraform output -raw sqs_queue_url)
EBS_KMS_KEY=$(cd infra/state/cluster && terraform output -raw ebs_kms_key_arn)
KARPENTER_ROLE=$(cd infra/state/addons && terraform output -raw karpenter_controller_role)
KARPENTER_QUEUE=$(cd infra/state/addons && terraform output -raw karpenter_queue_name)
NODE_ROLE=$(cd infra/state/cluster && terraform output -raw node_role_arn | cut -d'/' -f2)

echo "==> IRSA roles loaded"
echo "    ExternalDNS: $EXTERNAL_DNS_ROLE"
echo "    CertManager: $CERT_MANAGER_ROLE"
echo "    SQS URL:     $SQS_URL"

# ── Step 2: Install snapshot CRDs ────────────────────────────────────────────
echo "==> [2/11] Installing snapshot controller CRDs"
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

echo "==> Waiting for snapshot controller..."
sleep 15

# ── Step 3: Create StorageClass ───────────────────────────────────────────────
echo "==> [3/11] Creating gp3 StorageClass"
sed "s|REPLACE_WITH_KMS_KEY_ARN|${EBS_KMS_KEY}|g" \
  k8s/base/storageclass.yaml | kubectl apply -f -

# ── Step 4: Install NGINX Ingress ─────────────────────────────────────────────
echo "==> [4/11] Installing NGINX Ingress Controller"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 10m

echo "==> NGINX Ingress ELB:"
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
echo ""

# ── Step 5: Install CertManager ───────────────────────────────────────────────
echo "==> [5/11] Installing CertManager"
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set startupapicheck.enabled=false \
  --wait --timeout 10m

# ── Step 6: Create ClusterIssuer ─────────────────────────────────────────────
echo "==> [6/11] Creating Let's Encrypt ClusterIssuer"
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

kubectl get clusterissuer letsencrypt-prod

# ── Step 7: Install ExternalDNS ───────────────────────────────────────────────
echo "==> [7/11] Installing ExternalDNS"
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update
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

# ── Step 8: Install Karpenter ─────────────────────────────────────────────────
echo "==> [8/11] Installing Karpenter"
KARPENTER_VERSION="1.0.0"
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version ${KARPENTER_VERSION} \
  --namespace karpenter \
  --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${KARPENTER_ROLE}" \
  --set settings.clusterName=${CLUSTER} \
  --set settings.interruptionQueue=${KARPENTER_QUEUE} \
  --wait --timeout 5m

echo "==> Applying Karpenter NodePool"
sed "s/REPLACE_WITH_NODE_ROLE_NAME/${NODE_ROLE}/g; \
     s/REPLACE_WITH_CLUSTER_NAME/${CLUSTER}/g" \
  k8s/karpenter/nodepool.yaml | kubectl apply -f -

# ── Step 9: Install ArgoCD ────────────────────────────────────────────────────
echo "==> [9/11] Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for ArgoCD..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=180s

# ── Step 10: Install Prometheus stack ─────────────────────────────────────────
echo "==> [10/11] Installing kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f monitoring/values-prometheus.yaml \
  --wait --timeout 15m

# ── Step 11: Build and deploy app ─────────────────────────────────────────────
echo "==> [11/11] Building and pushing images"
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $REGISTRY

SHA=$(git rev-parse --short HEAD)

for svc in api-gateway order-service inventory-service payment-service \
           notification-service shipping-service worker scheduler dashboard-api; do
  echo "==> Building ${svc}..."
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

# Deploy via Helm
echo "==> Deploying application via Helm"
helm upgrade --install order-fulfillment \
  k8s/charts/order-fulfillment \
  -f k8s/charts/order-fulfillment/values.yaml \
  -f k8s/charts/order-fulfillment/values-dev.yaml \
  --set sqsQueueUrl="${SQS_URL}" \
  --set services.orderService.irsaRoleArn="${ORDER_ROLE}" \
  --set services.paymentService.irsaRoleArn="${PAYMENT_ROLE}" \
  --set services.shippingService.irsaRoleArn="${SHIPPING_ROLE}" \
  --set services.worker.irsaRoleArn="${WORKER_ROLE}" \
  --set services.notificationService.irsaRoleArn="${NOTIF_ROLE}" \
  --set services.scheduler.irsaRoleArn="${SCHEDULER_ROLE}" \
  --namespace order-fulfillment \
  --create-namespace \
  --wait --timeout 15m

# Apply network policies
kubectl apply -f k8s/network-policies/

# Apply ArgoCD
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
echo "ArgoCD URL: https://argocd.${DOMAIN}"
echo ""
kubectl get pods -n order-fulfillment