#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER="demo"
CTX="kind-${CLUSTER}"
NS="demo"
IMAGE="demo-service"
TAG="${IMAGE_TAG:-0.1.0}"
INGRESS_NGINX_VERSION="controller-v1.11.2"

for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing prerequisite: $bin" >&2; exit 1; }
done

echo "==> kind cluster '${CLUSTER}'"
if kind get clusters | grep -qx "${CLUSTER}"; then
  echo "    already exists, reusing"
else
  # 80/443 mapped to the host and node labelled so ingress-nginx's kind manifest schedules.
  cat <<'KIND' | kind create cluster --name "${CLUSTER}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
KIND
fi

echo "==> ingress-nginx ${INGRESS_NGINX_VERSION}"
if kubectl --context "${CTX}" -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
  echo "    already installed, skipping"
else
  kubectl --context "${CTX}" apply -f \
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
fi
kubectl --context "${CTX}" -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s

echo "==> build + load image ${IMAGE}:${TAG}"
docker build -t "${IMAGE}:${TAG}" service/
kind load docker-image "${IMAGE}:${TAG}" --name "${CLUSTER}"

echo "==> helm release 'demo' in namespace '${NS}'"
# Retry: the ingress admission webhook can lag a few seconds behind the controller pod.
for attempt in 1 2 3 4 5; do
  if helm --kube-context "${CTX}" upgrade --install demo chart \
        --namespace "${NS}" --create-namespace \
        --set image.repository="${IMAGE}" --set image.tag="${TAG}" \
        --wait --timeout 3m; then
    break
  fi
  [ "$attempt" -eq 5 ] && { echo "helm failed after 5 attempts" >&2; exit 1; }
  echo "    helm failed (attempt ${attempt}), retrying in 10s..."; sleep 10
done

echo
echo "Done. Verify with:  curl -s -H 'Host: demo.local' http://localhost/"
