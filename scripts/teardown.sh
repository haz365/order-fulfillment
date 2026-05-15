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

echo "==> Uninstalling Helm releases"
helm uninstall order-fulfillment -n order-fulfillment  2>/dev/null || true
helm uninstall prometheus        -n monitoring          2>/dev/null || true
helm uninstall karpenter         -n karpenter           2>/dev/null || true
helm uninstall external-dns      -n external-dns        2>/dev/null || true
helm uninstall cert-manager      -n cert-manager        2>/dev/null || true
helm uninstall ingress-nginx     -n ingress-nginx       2>/dev/null || true

echo "==> Deleting namespaces"
for ns in order-fulfillment monitoring karpenter \
          external-dns cert-manager ingress-nginx argocd; do
  kubectl delete namespace $ns --ignore-not-found
done

echo "==> Destroying Terraform - addons"
cd infra/state/addons
terraform destroy -auto-approve

echo "==> Destroying Terraform - cluster"
cd ../cluster
terraform destroy -auto-approve

echo "==> Destroying Terraform - network"
cd ../network
terraform destroy -auto-approve

echo "==> Done"