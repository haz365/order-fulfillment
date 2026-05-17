#!/bin/bash
set -euo pipefail

CLUSTER="order-fulfillment-dev"
REGION="eu-west-2"

echo "==> Tearing down order-fulfillment-dev"
echo "==> This will destroy all resources"
read -p "Type 'destroy' to confirm: " confirm
if [ "$confirm" != "destroy" ]; then
  echo "Aborted"
  exit 1
fi

# ── Step 1: Delete Karpenter nodes first ──────────────────────────────────────
echo "==> Scaling down Karpenter nodes"
kubectl delete nodeclaims --all 2>/dev/null || true
kubectl delete nodepools --all 2>/dev/null || true

echo "==> Waiting for Karpenter nodes to terminate..."
sleep 60

# Terminate any remaining Karpenter instances
KARPENTER_INSTANCES=$(aws ec2 describe-instances \
  --region eu-west-2 \
  --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
             "Name=instance-state-name,Values=running,stopped,pending" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text 2>/dev/null || true)

if [ -n "$KARPENTER_INSTANCES" ]; then
  echo "==> Terminating Karpenter instances: $KARPENTER_INSTANCES"
  aws ec2 terminate-instances \
    --instance-ids $KARPENTER_INSTANCES \
    --region eu-west-2
  aws ec2 wait instance-terminated \
    --instance-ids $KARPENTER_INSTANCES \
    --region eu-west-2
  echo "==> Karpenter instances terminated"
fi

# ── Step 2: Uninstall Helm releases ───────────────────────────────────────────
echo "==> Uninstalling Helm releases"
helm uninstall order-fulfillment -n order-fulfillment  2>/dev/null || true
helm uninstall prometheus        -n monitoring          2>/dev/null || true
helm uninstall karpenter         -n karpenter           2>/dev/null || true
helm uninstall external-dns      -n external-dns        2>/dev/null || true
helm uninstall cert-manager      -n cert-manager        2>/dev/null || true
helm uninstall ingress-nginx     -n ingress-nginx       2>/dev/null || true

# ── Step 3: Delete namespaces ─────────────────────────────────────────────────
echo "==> Deleting namespaces"
for ns in order-fulfillment monitoring karpenter \
          external-dns cert-manager ingress-nginx argocd; do
  kubectl delete namespace $ns --force --grace-period=0 2>/dev/null || true
done

# ── Step 4: Remove finalizers if namespaces stuck ─────────────────────────────
echo "==> Removing stuck namespace finalizers"
for ns in order-fulfillment monitoring karpenter \
          external-dns cert-manager ingress-nginx argocd; do
  kubectl get namespace $ns -o json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
done

# ── Step 5: Destroy Terraform ─────────────────────────────────────────────────
echo "==> Destroying Terraform - addons"
cd infra/state/addons
terraform destroy -auto-approve

echo "==> Destroying Terraform - cluster"
cd ../cluster
terraform destroy -auto-approve

echo "==> Destroying Terraform - network"
cd ../network
terraform destroy -auto-approve

echo ""
echo "==> Teardown complete"