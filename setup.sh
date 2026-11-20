#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

for tool in docker kind kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$tool" >&2
    exit 1
  fi
done

kube() {
  kubectl --context kind-mykind "$@"
}

echo "Checking Docker and kind cluster..."
docker info >/dev/null
clusters="$(kind get clusters)"
if ! grep -Fxq mykind <<< "$clusters"; then
  kind create cluster --name mykind
fi
kube get nodes

echo "Installing cert-manager..."
kube apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml
for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
  kube rollout status "deployment/$deployment" -n cert-manager --timeout=180s
done

echo "Checking OpenTelemetry Operator..."
operator_image="$(kube get deployment opentelemetry-operator-controller-manager \
  -n opentelemetry-operator-system --ignore-not-found \
  -o 'jsonpath={.spec.template.spec.containers[?(@.name=="manager")].image}')"
expected_image="ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator:0.163.0"
if [[ -z "$operator_image" ]]; then
  kube apply --server-side -f ./otel-operator.yaml
elif [[ "$operator_image" != "$expected_image" ]]; then
  printf 'Existing operator image differs from this sample: %s\nReview the installation before continuing.\n' \
    "$operator_image" >&2
  exit 1
else
  echo "Matching operator already installed; reusing it."
fi
kube rollout status deployment/opentelemetry-operator-controller-manager \
  -n opentelemetry-operator-system --timeout=180s
kube wait --for=condition=Established \
  crd/opentelemetrycollectors.opentelemetry.io \
  crd/instrumentations.opentelemetry.io --timeout=120s

echo "Deploying Collector..."
kube apply -f ./otel-collector.yaml
kube wait --for=condition=Ready opentelemetrycollector/demo -n default --timeout=180s
kube rollout status deployment/demo-collector -n default --timeout=180s

echo "Configuring Python instrumentation..."
kube create namespace python --dry-run=client -o yaml | kube apply -f -
kube apply -f ./python-instrumentation.yaml

echo "Deploying Python service..."
kube apply -f ./python-deployment.yaml
# Existing Pods must be recreated to pick up Instrumentation changes.
kube rollout restart deployment/python-otel -n python
kube rollout status deployment/python-otel -n python --timeout=300s

echo "Setup complete. Run these in separate terminals:"
echo "kubectl --context kind-mykind port-forward deployment/python-otel 5001:5000 -n python"
echo "kubectl --context kind-mykind logs -n default deployment/demo-collector --follow --since=2m"
echo "Visit http://localhost:5001/otel-test to generate telemetry."
