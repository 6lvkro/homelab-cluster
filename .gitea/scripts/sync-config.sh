#!/usr/bin/env bash
set -euo pipefail

# ConfigMap 업데이트
kubectl create configmap cluster-config \
  -n flux-system \
  --from-env-file=.env.config \
  --dry-run=client -o yaml \
| kubectl apply -f -

# 모든 티어 reconcile 트리거
for ks in homelab-core homelab-data homelab-platform homelab-apps; do
  kubectl annotate kustomization "$ks" \
    -n flux-system \
    reconcile.fluxcd.io/requestedAt="$(date +%s)" \
    --overwrite
done
