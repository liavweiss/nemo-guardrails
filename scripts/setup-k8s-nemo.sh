#!/usr/bin/env bash
# Build and setup NeMo Guardrails on Kind (cluster + image + deploy).
# Use --rebuild to force rebuild image, load into Kind, and restart the deployment.
set -e

CLUSTER_NAME="${CLUSTER_NAME:-guardrails}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s"

# Container runtime: podman (default) or docker. Kind loads from Docker by default;
# with podman we save to a tarball and use kind load image-archive.
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"

# Options (set by parse_args)
SKIP_BUILD=""
REBUILD=""
RESTART_ONLY=""
LOAD_ONLY=""
DOCKER_NO_CACHE=""
CONFIG_DIR="guard-only-config"   # relative to REPO_ROOT; override with --config-dir

usage() {
  cat <<'EOF'
Usage: setup-k8s-nemo.sh [OPTIONS]

Build and deploy NeMo Guardrails to a Kind cluster (namespace nemo-guardrails).
Creates the cluster if it does not exist, builds the NeMo image, loads it into Kind,
and applies Kubernetes manifests.

Two deployment tiers are supported automatically:

  Guard-only  (default: guard-only-config, or any guard-only-examples/NN-*)
              Single pod. No external model service. Uses k8s/ manifests at repo root.

  Model-guard (model-guard-examples/NN-*)
              Two pods: NeMo guard pod + model server pod (e.g. Ollama).
              Detected automatically when <config-dir>/k8s/ contains manifests.
              Also pulls and loads the model server image (e.g. ollama/ollama:latest).

Options:
  --help                    Show this help and exit.
  --docker                  Use Docker for build/load (default: podman).
  --config-dir <dir>        Config directory (relative to repo root, default: guard-only-config).
                            Guard-only:  guard-only-examples/01-keywords-patterns
                            Model-guard: model-guard-examples/05-llama-guard
  --rebuild                 Force rebuild NeMo image, reload into Kind, and restart deployment.
  --no-cache                Pass --no-cache to build (full rebuild).
  --restart-only            Only restart the NeMo deployment (no build or load).
  --load-only               Load current nemoguardrails:latest into Kind and restart (no build).
  --skip-build              Skip build and load; only apply/update K8s manifests.

Build:
  Every config directory is self-contained: own Dockerfile + requirements.txt + config files.
  Model-guard examples also have a k8s/ subdirectory with deployment and service manifests.

Environment:
  CLUSTER_NAME       Kind cluster name (default: guardrails).
  CONTAINER_RUNTIME  podman (default) or docker.
  SKIP_BUILD         If set (e.g. 1), skip build step (same as --skip-build).

Examples:
  # Guard-only (default)
  ./scripts/setup-k8s-nemo.sh
  ./scripts/setup-k8s-nemo.sh --rebuild
  ./scripts/setup-k8s-nemo.sh --rebuild --config-dir guard-only-examples/01-keywords-patterns
  ./scripts/setup-k8s-nemo.sh --rebuild --config-dir guard-only-examples/03-jailbreak-heuristics

  # Model-guard (Llama Guard 3 1B via Ollama — two pods)
  ./scripts/setup-k8s-nemo.sh --rebuild --config-dir model-guard-examples/05-llama-guard

  ./scripts/setup-k8s-nemo.sh --docker --rebuild     # use Docker instead of Podman
  ./scripts/setup-k8s-nemo.sh --load-only            # after manual build: load + restart
  ./scripts/setup-k8s-nemo.sh --restart-only
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --docker)
        CONTAINER_RUNTIME=docker
        shift
        ;;
      --config-dir)
        CONFIG_DIR="$2"
        shift 2
        ;;
      --rebuild)
        REBUILD=1
        shift
        ;;
      --no-cache)
        DOCKER_NO_CACHE=1
        shift
        ;;
      --load-only)
        LOAD_ONLY=1
        shift
        ;;
      --restart-only)
        RESTART_ONLY=1
        shift
        ;;
      --skip-build)
        SKIP_BUILD=1
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

if [[ "$CONTAINER_RUNTIME" != "podman" ]] && [[ "$CONTAINER_RUNTIME" != "docker" ]]; then
  echo "Invalid CONTAINER_RUNTIME=$CONTAINER_RUNTIME (use podman or docker)" >&2
  exit 1
fi

if [[ ! -d "$REPO_ROOT/$CONFIG_DIR" ]]; then
  echo "Config directory not found: $REPO_ROOT/$CONFIG_DIR" >&2
  echo "Available configs:" >&2
  echo "  guard-only-config  (production default — all guards combined)" >&2
  ls "$REPO_ROOT/guard-only-examples/" 2>/dev/null | sed 's/^/  guard-only-examples\//' >&2
  ls "$REPO_ROOT/model-guard-examples/" 2>/dev/null | grep -v README | sed 's/^/  model-guard-examples\//' >&2
  exit 1
fi

# Detect deployment tier from config dir layout
CONFIG_K8S_DIR="$REPO_ROOT/$CONFIG_DIR/k8s"
if [[ -d "$CONFIG_K8S_DIR" ]]; then
  DEPLOY_TIER="model-guard"
else
  DEPLOY_TIER="guard-only"
fi
echo "Config dir: $CONFIG_DIR  (tier: $DEPLOY_TIER)"

# Legacy: env SKIP_BUILD still skips build unless --rebuild is set
if [[ -z "$REBUILD" ]] && [[ -n "${SKIP_BUILD:-}" ]]; then
  SKIP_BUILD=1
fi

# --restart-only: just rollout restart and exit
if [[ -n "$RESTART_ONLY" ]]; then
  echo "=== Restarting NeMo Guardrails deployment ==="
  kubectl rollout restart deployment/nemo-guardrails -n nemo-guardrails
  echo "Waiting for pod to be ready..."
  kubectl wait --for=condition=ready pod -l app=nemo-guardrails -n nemo-guardrails --timeout=120s 2>/dev/null || true
  echo "Done. Port-forward: kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000"
  exit 0
fi

# --load-only: load current image into Kind and restart (no build)
# Use image ID as tag so the deployment uses the exact image we load (avoids "latest" pointing to old image on node).
if [[ -n "$LOAD_ONLY" ]]; then
  echo "=== Load image and restart NeMo Guardrails deployment ==="
  if ! kind get kubeconfig --name "$CLUSTER_NAME" &>/dev/null; then
    echo "Kind cluster '$CLUSTER_NAME' not found. Create it first (e.g. run without --load-only)." >&2
    exit 1
  fi
  if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    IMG_ID=$(docker image inspect nemoguardrails:latest --format '{{.Id}}' 2>/dev/null | sed 's/^sha256://' | cut -c1-12)
  else
    IMG_ID=$(podman images --format '{{.ID}}' nemoguardrails:latest 2>/dev/null | head -1 | cut -c1-12)
    [[ -z "$IMG_ID" ]] && IMG_ID=$(podman images --format '{{.ID}}' localhost/nemoguardrails:latest 2>/dev/null | head -1 | cut -c1-12)
  fi
  if [[ -z "$IMG_ID" ]]; then
    echo "Image nemoguardrails:latest not found. Build first (run without --load-only)." >&2
    exit 1
  fi
  IMAGE_TAG="nemoguardrails:${IMG_ID}"
  # Use docker.io/library/... so the image on the Kind node matches what kubelet expects (avoids ImagePullBackOff with Podman)
  IMAGE_FULL="${KIND_IMAGE_NAME:-docker.io/library/nemoguardrails:${IMG_ID}}"
  echo "Loading $IMAGE_TAG into cluster (runtime: $CONTAINER_RUNTIME)..."
  if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    docker tag nemoguardrails:latest "$IMAGE_TAG"
    kind load docker-image "$IMAGE_TAG" --name "$CLUSTER_NAME"
  else
    podman tag "$IMG_ID" "$IMAGE_FULL"
    TAR=$(mktemp -u).tar
    podman save -o "$TAR" "$IMAGE_FULL"
    kind load image-archive "$TAR" --name "$CLUSTER_NAME"
    rm -f "$TAR"
  fi
  echo "Updating deployment to use $IMAGE_TAG..."
  kubectl set image deployment/nemo-guardrails nemo-guardrails="$IMAGE_TAG" -n nemo-guardrails
  echo "Waiting for pod to be ready..."
  kubectl rollout status deployment/nemo-guardrails -n nemo-guardrails --timeout=120s 2>/dev/null || true
  kubectl wait --for=condition=ready pod -l app=nemo-guardrails -n nemo-guardrails --timeout=120s 2>/dev/null || true
  echo "Done. Port-forward: kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000"
  exit 0
fi

echo "=== Setup NeMo Guardrails (Kind + build + deploy) ==="
echo ""

# --- Step 1: Create Kind cluster (skip if already exists) ---
echo "[1/3] Kind cluster..."
if kind get kubeconfig --name "$CLUSTER_NAME" &>/dev/null; then
  echo "      Cluster '$CLUSTER_NAME' already exists. Skipping create."
else
  echo "      Creating cluster: $CLUSTER_NAME"
  kind create cluster --config "$K8S_DIR/kind-config.yaml" --name "$CLUSTER_NAME"
  echo "      Done."
fi
echo ""

# --- Step 2: Build + load NeMo image; load model-server image for model-guard configs ---
# Use image ID as tag so the deployment uses the exact image we load (avoids "latest" on node pointing to old image).
DID_LOAD_IMAGE=""
echo "[2/3] Build and load image (runtime: $CONTAINER_RUNTIME)..."
if [[ -n "$REBUILD" ]] || [[ -z "$SKIP_BUILD" ]]; then
  # Every config directory is self-contained (own Dockerfile + requirements.txt + config files).
  CONFIG_DIR_ABS="$REPO_ROOT/$CONFIG_DIR"
  if [[ ! -f "$CONFIG_DIR_ABS/Dockerfile" ]]; then
    echo "ERROR: No Dockerfile found in $CONFIG_DIR — every config dir must be self-contained." >&2
    exit 1
  fi
  echo "      Building NeMo image from $CONFIG_DIR..."
  BUILD_ARGS=(-f "$CONFIG_DIR_ABS/Dockerfile" -t nemoguardrails:latest "$CONFIG_DIR_ABS")
  [[ -n "$DOCKER_NO_CACHE" ]] && BUILD_ARGS=(--no-cache "${BUILD_ARGS[@]}")
  if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    docker build "${BUILD_ARGS[@]}"
  else
    podman build "${BUILD_ARGS[@]}"
  fi
  echo "      Build done."
  if kind get kubeconfig --name "$CLUSTER_NAME" &>/dev/null; then
    echo "      Loading NeMo image into cluster..."
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
      IMG_ID=$(docker image inspect nemoguardrails:latest --format '{{.Id}}' 2>/dev/null | sed 's/^sha256://' | cut -c1-12)
    else
      IMG_ID=$(podman images --format '{{.ID}}' nemoguardrails:latest 2>/dev/null | head -1 | cut -c1-12)
      [[ -z "$IMG_ID" ]] && IMG_ID=$(podman images --format '{{.ID}}' localhost/nemoguardrails:latest 2>/dev/null | head -1 | cut -c1-12)
    fi
    if [[ -z "$IMG_ID" ]]; then
      echo "      Failed to get image ID for nemoguardrails:latest" >&2
      exit 1
    fi
    IMAGE_TAG="nemoguardrails:${IMG_ID}"
    IMAGE_FULL="${KIND_IMAGE_NAME:-docker.io/library/nemoguardrails:${IMG_ID}}"
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
      docker tag nemoguardrails:latest "$IMAGE_TAG"
      kind load docker-image "$IMAGE_TAG" --name "$CLUSTER_NAME"
    else
      podman tag "$IMG_ID" "$IMAGE_FULL"
      TAR=$(mktemp -u).tar
      podman save -o "$TAR" "$IMAGE_FULL"
      kind load image-archive "$TAR" --name "$CLUSTER_NAME"
      rm -f "$TAR"
    fi
    echo "      Load done ($IMAGE_TAG)."
    DID_LOAD_IMAGE="$IMAGE_TAG"

    # Model-guard: pre-load the Ollama image into Kind so the sidecar container
    # doesn't need to pull from Docker Hub on the Kind node.
    if [[ "$DEPLOY_TIER" == "model-guard" ]]; then
      # Use fully-qualified name to avoid Podman trying quay.io/ollama before docker.io/ollama
      OLLAMA_IMAGE="docker.io/ollama/ollama:latest"
      echo "      [model-guard] Pulling and loading $OLLAMA_IMAGE into cluster..."
      echo "      NOTE: The llama-guard3:1b model (~700 MB) is pulled by the init container at pod startup."
      if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        docker pull "$OLLAMA_IMAGE" || true
        kind load docker-image "$OLLAMA_IMAGE" --name "$CLUSTER_NAME"
      else
        podman pull "$OLLAMA_IMAGE" || true
        OLLAMA_TAR=$(mktemp -u).tar
        podman save -o "$OLLAMA_TAR" "$OLLAMA_IMAGE"
        kind load image-archive "$OLLAMA_TAR" --name "$CLUSTER_NAME"
        rm -f "$OLLAMA_TAR"
      fi
      echo "      Ollama image loaded."
    fi
  fi
else
  echo "      SKIP_BUILD is set. Skipping build and load."
  if kind get kubeconfig --name "$CLUSTER_NAME" &>/dev/null; then
    echo "      (Images already in cluster from previous run.)"
  fi
fi
echo ""

# --- Step 3: Deploy to K8s ---
echo "[3/3] Deploy to Kubernetes..."
# --validate=false: skip OpenAPI schema download (Kind clusters often can't serve it)
kubectl apply --validate=false -f "$K8S_DIR/namespace.yaml"

if [[ "$DEPLOY_TIER" == "model-guard" ]]; then
  # Model-guard: apply example-specific manifests (NeMo + Ollama pods)
  echo "      Applying model-guard manifests from $CONFIG_DIR/k8s/ ..."
  kubectl apply --validate=false -f "$CONFIG_K8S_DIR/"
  if [[ -n "$DID_LOAD_IMAGE" ]]; then
    echo "      Updating NeMo deployment to use $DID_LOAD_IMAGE..."
    kubectl set image deployment/nemo-guardrails nemo-guardrails="$DID_LOAD_IMAGE" -n nemo-guardrails
  fi
  # Both NeMo and Ollama run as sidecars in the same pod.
  # The init container pulls the model first (~5-10 min), then both sidecars start.
  # kubectl wait on the pod covers both containers (pod is only Ready when all containers pass probes).
  echo "      Waiting for pod (init container pulls model — first run: ~5-10 min)..."
  echo "      Watch progress: kubectl logs -f -n nemo-guardrails -l app=nemo-guardrails -c model-puller"
  if kubectl rollout status deployment/nemo-guardrails -n nemo-guardrails --timeout=900s 2>/dev/null; then
    echo "      NeMo pod is ready."
  else
    echo "      Wait timed out. Check: kubectl get pods -n nemo-guardrails"
  fi
  echo ""
  echo "=== Done. NeMo Guardrails + Ollama (Llama Guard 3 1B) running in namespace nemo-guardrails."
  echo "    Port-forward: kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000"
  echo "    Rebuild:      ./scripts/setup-k8s-nemo.sh --rebuild --config-dir $CONFIG_DIR"
else
  # Guard-only: apply root k8s/ manifests (single NeMo pod)
  kubectl apply --validate=false -f "$K8S_DIR/deployment.yaml" -f "$K8S_DIR/service.yaml"
  if [[ -n "$DID_LOAD_IMAGE" ]]; then
    echo "      Updating deployment to use $DID_LOAD_IMAGE..."
    kubectl set image deployment/nemo-guardrails nemo-guardrails="$DID_LOAD_IMAGE" -n nemo-guardrails
  fi
  echo "      Waiting for pod to be ready..."
  if kubectl wait --for=condition=ready pod -l app=nemo-guardrails -n nemo-guardrails --timeout=120s 2>/dev/null; then
    echo "      Pod is ready."
  else
    echo "      Wait timed out or no matching pod. Check: kubectl get pods -n nemo-guardrails"
  fi
  echo ""
  echo "=== Done. NeMo Guardrails (guard-only) running in namespace nemo-guardrails."
  echo "    Test with: ./scripts/test-rails-mock.sh"
  echo "    Port-forward: kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000"
  echo "    Rebuild:      ./scripts/setup-k8s-nemo.sh --rebuild"
fi