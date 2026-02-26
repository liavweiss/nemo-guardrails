#!/usr/bin/env bash
# Build and setup NeMo Guardrails on Kind (cluster + image + deploy).
# Each step is skipped if already done (cluster exists, deploy applied).
set -e

CLUSTER_NAME="${CLUSTER_NAME:-guardrails}"
SKIP_BUILD="${SKIP_BUILD:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s"

echo "=== Setup NeMo Guardrails (Kind + build + deploy) ==="
echo ""

# --- Step 1: Create Kind cluster (skip if already exists) ---
echo "[1/3] Kind cluster..."
if kind get kubeconfig --name "$CLUSTER_NAME" &>/dev/null; then
  echo "      Cluster '$CLUSTER_NAME' already exists. Skipping create."
else
  echo "      Creating cluster: $CLUSTER_NAME"
  kind create cluster --config "$REPO_ROOT/kind-config.yaml" --name "$CLUSTER_NAME"
  echo "      Done."
fi
echo ""

# --- Step 2: Build image and load into Kind (skip build if SKIP_BUILD=1) ---
echo "[2/3] Build and load image..."
if [[ -n "$SKIP_BUILD" ]]; then
  echo "      SKIP_BUILD is set. Skipping docker build."
else
  echo "      Building image from $REPO_ROOT"
  docker build -t nemoguardrails:latest "$REPO_ROOT"
  echo "      Build done."
fi
if kind get kubeconfig --name "$CLUSTER_NAME" &>/dev/null; then
  echo "      Loading image into cluster..."
  kind load docker-image nemoguardrails:latest --name "$CLUSTER_NAME"
  echo "      Load done."
else
  echo "      No cluster found; skipping load."
fi
echo ""

# --- Step 3: Deploy to K8s (apply is idempotent) ---
echo "[3/3] Deploy to Kubernetes..."
kubectl apply -f "$K8S_DIR/namespace.yaml"
kubectl apply -f "$K8S_DIR/deployment.yaml" -f "$K8S_DIR/service.yaml"
echo "      Waiting for pod to be ready..."
if kubectl wait --for=condition=ready pod -l app=nemo-guardrails -n nemo-guardrails --timeout=120s 2>/dev/null; then
  echo "      Pod is ready."
else
  echo "      Wait timed out or no matching pod. Check: kubectl get pods -n nemo-guardrails"
fi
echo ""
echo "=== Done. NeMo Guardrails (guards only) is running in namespace nemo-guardrails."
echo "    Test with: ./scripts/test-nemo.sh"
echo "    Or port-forward and curl: kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000"
