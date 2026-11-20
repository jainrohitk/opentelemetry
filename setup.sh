#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

for tool in docker kind kubectl nohup curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$tool" >&2
    exit 1
  fi
done

for name in python grafana prometheus; do
  if [[ -f ".port-forward/$name.pid" ]]; then
    if ! read -r pid < ".port-forward/$name.pid" || [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
      printf 'Invalid PID file: .port-forward/%s.pid. Inspect it before rerunning setup.\n' "$name" >&2
      exit 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
      printf 'Recorded %s port-forward PID %s is still active. Inspect and stop it before rerunning setup.\n' \
        "$name" "$pid" >&2
      exit 1
    fi
  fi
done

kube() {
  kubectl --context kind-mykind "$@"
}

start_port_forward() {
  local name="$1" namespace="$2" resource="$3" ports="$4" url="$5"
  local log=".port-forward/$name.log" pid attempt
  nohup kubectl --context kind-mykind port-forward "$resource" "$ports" \
    -n "$namespace" --address 127.0.0.1 > "$log" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > ".port-forward/$name.pid"
  for ((attempt = 0; attempt < 30; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '%s port-forward exited; see %s:\n' "$name" "$log" >&2
      cat "$log" >&2
      return 1
    fi
    if grep -q '^Forwarding from 127.0.0.1:' "$log" &&
      curl --silent --fail --max-time 2 "$url" > /dev/null; then
      printf '%s port-forward ready (PID %s).\n' "$name" "$pid"
      return 0
    fi
    sleep 1
  done
  printf '%s port-forward did not become healthy; see %s.\n' "$name" "$log" >&2
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
  fi
  return 1
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

echo "Deploying Tempo, Prometheus, and Grafana..."
kube apply -f ./tempo.yaml
kube rollout status deployment/tempo -n default --timeout=300s
kube apply -f ./prometheus.yaml
kube rollout status deployment/prometheus -n default --timeout=300s
kube apply -f ./grafana.yaml
# Reload provisioned data sources when rerunning with an updated ConfigMap.
kube rollout restart deployment/grafana -n default
kube rollout status deployment/grafana -n default --timeout=300s

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

echo "Starting background port-forwards..."
mkdir -p .port-forward
start_port_forward python python deployment/python-otel 5001:5000 http://127.0.0.1:5001/
start_port_forward grafana default service/grafana 3000:3000 http://127.0.0.1:3000/api/health
start_port_forward prometheus default service/prometheus 9090:9090 http://127.0.0.1:9090/-/ready

echo "Setup complete. Port-forward logs and PIDs are in .port-forward/."
echo "kubectl --context kind-mykind logs -n default deployment/demo-collector --follow --since=2m"
echo "Visit http://localhost:5001/otel-test to generate telemetry."
echo "Open http://localhost:3000 and use Explore > Tempo to search traces."
echo "Use Explore > Prometheus and query {service_name=\"python-otel\"} to see app metrics."
echo "Prometheus UI: http://localhost:9090"
