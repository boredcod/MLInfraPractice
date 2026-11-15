#!/usr/bin/env bash
set -euo pipefail

CLUSTER=mlops-lab
CTX="kind-${CLUSTER}"
ARGOCD_CHART_VERSION=10.18.0

cd "$(dirname "$0")/.."

# 1. Create the cluster if it doesn't exist
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config infra/kind/kind-config.yaml
fi
kubectl --context "$CTX" wait --for=condition=Ready nodes --all --timeout=180s

# 2. Install ArgoCD (pinned)
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --kube-context "$CTX" \
  --namespace argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  -f platform/argocd/values.yaml \
  --wait --timeout 5m

# 3. Hand everything else over to ArgoCD
kubectl --context "$CTX" apply -f bootstrap/root.yaml

# 4. Wait until every Application is Synced and Healthy
expected=$(( $(ls platform/apps/*.yaml | wc -l) + 1 ))   # children + root
echo "Waiting for $expected applications..."
for _ in $(seq 1 90); do
  total=$(kubectl --context "$CTX" -n argocd get applications --no-headers 2>/dev/null | wc -l)
  bad=$(kubectl --context "$CTX" -n argocd get applications --no-headers 2>/dev/null | grep -vc 'Synced *Healthy' || true)
  if [ "$total" -ge "$expected" ] && [ "$bad" -eq 0 ]; then
    echo "All applications are Synced and Healthy."
    exit 0
  fi
  sleep 10
done
echo "Timed out waiting for applications." >&2
kubectl --context "$CTX" -n argocd get applications
exit 1
