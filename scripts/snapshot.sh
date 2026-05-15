#!/bin/bash
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d%H%M%S)
SNAPSHOT_NAME="postgres-snapshot-${TIMESTAMP}"

echo "==> Taking VolumeSnapshot: ${SNAPSHOT_NAME}"

kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: order-fulfillment
spec:
  volumeSnapshotClassName: ebs-vsc
  source:
    persistentVolumeClaimName: postgres-data-postgres-0
EOF

echo "==> Waiting for snapshot to be ready..."
kubectl wait volumesnapshot/${SNAPSHOT_NAME} \
  -n order-fulfillment \
  --for=jsonpath='{.status.readyToUse}'=true \
  --timeout=300s

echo "==> Snapshot ready: ${SNAPSHOT_NAME}"
echo ""
echo "==> To restore, run:"
echo "    ./scripts/restore.sh ${SNAPSHOT_NAME}"