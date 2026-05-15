#!/bin/bash
set -euo pipefail

SNAPSHOT_NAME=${1:-""}
if [ -z "$SNAPSHOT_NAME" ]; then
  echo "Usage: ./scripts/restore.sh <snapshot-name>"
  echo ""
  echo "Available snapshots:"
  kubectl get volumesnapshots -n order-fulfillment
  exit 1
fi

echo "==> Restoring from snapshot: ${SNAPSHOT_NAME}"
echo "==> This will scale down postgres and restore data"
read -p "Continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Aborted"
  exit 1
fi

echo "==> Scaling down postgres"
kubectl scale statefulset postgres \
  -n order-fulfillment --replicas=0

echo "==> Deleting existing PVC"
kubectl delete pvc postgres-data-postgres-0 \
  -n order-fulfillment

echo "==> Creating new PVC from snapshot"
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-postgres-0
  namespace: order-fulfillment
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 20Gi
  dataSource:
    name: ${SNAPSHOT_NAME}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

echo "==> Scaling postgres back up"
kubectl scale statefulset postgres \
  -n order-fulfillment --replicas=1

echo "==> Waiting for postgres to be ready"
kubectl wait pod/postgres-0 \
  -n order-fulfillment \
  --for=condition=ready \
  --timeout=120s

echo "==> Restore complete"
echo "==> Verifying data..."
kubectl exec -n order-fulfillment postgres-0 -- \
  psql -U appuser -d fulfillment -c "\dt"