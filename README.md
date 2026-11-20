# OpenTelemetry on Kubernetes: Python Quick Start

Run a Python service on kind and view its traces, metrics, and logs in the
OpenTelemetry Collector output. No application image build is needed.

```text
Python Pod -> OTLP HTTP :4318 -> Collector -> debug exporter -> Collector logs
```

| Resource | Namespace |
| --- | --- |
| cert-manager | `cert-manager` |
| OpenTelemetry Operator | `opentelemetry-operator-system` |
| Collector `demo` | `default` |
| Python Deployment and Instrumentation | `python` |

Use **PowerShell** from this repository's root. Install Docker Desktop (Linux
containers), kubectl, and kind first. Skip installations already present and
healthy; verify your Kubernetes context before applying files.

## Automated setup

From **Git Bash** on Windows, or Bash on Linux/macOS:

```bash
bash setup.sh
```

[setup.sh](./setup.sh) creates `mykind` if needed, installs the components in
order, and waits for readiness. It targets `kind-mykind`, reuses the matching
operator, and stops on errors. Rerunning updates the manifests and restarts the
Python service to pick up instrumentation changes. A different existing operator
version requires manual review.

The script prints the port-forward and collector-log commands when finished.
Use Step 5 below to generate traffic. The remaining setup steps are the manual
alternative.

## 1. Create a kind cluster

Skip creation if `mykind` already exists:

```powershell
kind create cluster --name mykind
kubectl config use-context kind-mykind
kubectl get nodes
```

## 2. Install cert-manager

```powershell
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
```

## 3. Install the OpenTelemetry Operator

[otel-operator.yaml](./otel-operator.yaml) is the unmodified
[official v0.163.0 installation bundle](https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.163.0/opentelemetry-operator.yaml),
saved locally with a shorter filename. It installs:

- The operator Deployment in `opentelemetry-operator-system`.
- CRDs that add resources such as `OpenTelemetryCollector` and `Instrumentation`.
- Service accounts and RBAC permissions for the operator.
- Admission webhooks, Services, and cert-manager certificate resources for injection.

The operator manages Collector instances and injects Python instrumentation into
annotated Pods when they are created. It does not receive application telemetry;
the Collector does that. Installing this bundle alone does not create the
`demo` Collector or instrument the Python app; Step 4 configures those.

```powershell
kubectl apply --server-side -f .\otel-operator.yaml
kubectl rollout status deployment/opentelemetry-operator-controller-manager -n opentelemetry-operator-system --timeout=180s
kubectl wait --for=condition=Established crd/opentelemetrycollectors.opentelemetry.io crd/instrumentations.opentelemetry.io --timeout=120s
```

Skip this step if the matching operator is already installed and healthy.

## 4. Deploy the Collector and Python service

Create the namespace first so Instrumentation exists before the application
Pods. The Deployment file also declares the namespace.

```powershell
kubectl apply -f .\otel-collector.yaml
kubectl wait --for=condition=Ready opentelemetrycollector/demo -n default --timeout=180s
kubectl rollout status deployment/demo-collector -n default --timeout=180s
kubectl create namespace python --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f .\python-instrumentation.yaml
kubectl apply -f .\python-deployment.yaml
kubectl rollout status deployment/python-otel -n python --timeout=300s
```

| File | Purpose |
| --- | --- |
| [otel-operator.yaml](./otel-operator.yaml) | Install the operator, CRDs, permissions, and webhooks (Step 3) |
| [otel-collector.yaml](./otel-collector.yaml) | Receive all three signals and print summaries with the debug exporter |
| [python-instrumentation.yaml](./python-instrumentation.yaml) | Configure Python instrumentation and the collector endpoint |
| [python-deployment.yaml](./python-deployment.yaml) | Create namespace `python` and run an inline Flask app using official `python:3.12-slim` |

The app installs Flask at startup, so each new container needs internet access.
A startup probe allows time for installation. This is a learning convenience,
not a production packaging approach.

### Two important settings

**Collector address:** the app is in `python`, while the collector is in
`default`, so the Instrumentation uses the cross-namespace address:

```text
http://demo-collector.default.svc.cluster.local:4318
```

**Annotation:** put it on the Deployment's **Pod template**, not only on the
Deployment's top-level metadata:

```yaml
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "true"
```

If multiple Instrumentation resources exist in `python`, use
`"python-instrumentation"` instead of `"true"` to select this one explicitly.

## 5. Generate traffic and view telemetry

**Terminal 1:** keep port-forward running.

```powershell
kubectl port-forward deployment/python-otel 5001:5000 -n python
```

**Terminal 2:** send requests.

```powershell
1..10 | ForEach-Object {
    Invoke-WebRequest http://localhost:5001/otel-test -UseBasicParsing | Out-Null
}
```

**Terminal 3:** watch the collector.

```powershell
kubectl logs -n default deployment/demo-collector --follow --since=2m
```

Look for positive counts:

| Signal | Collector output |
| --- | --- |
| Traces | `Traces` and `spans` |
| Metrics | `Metrics` and `data points` |
| Logs | `Logs` and `log records` |

Allow a few seconds for traces/logs and at least a minute for metrics. Health
probes also generate requests. The sample app emits a Python warning log per
request to make log export easy to test.

For individual span IDs, attributes, and log bodies, change
`debug.verbosity` from `basic` to `detailed` in
[otel-collector.yaml](./otel-collector.yaml), reapply it, and follow the current
collector logs. Detailed output may expose application data.

## Troubleshooting

Start with application logs and Pod details:

```powershell
kubectl logs -n python deployment/python-otel -c python-otel --tail=100
kubectl describe pods -n python -l app=python-otel
kubectl exec -n python deployment/python-otel -c python-otel -- printenv OTEL_EXPORTER_OTLP_ENDPOINT
```

- **No injection:** check the Pod-template annotation and the Instrumentation
  resource in `python`. Pod details should show the
  `opentelemetry-auto-instrumentation-python` init container.
- **Instrumentation changed:** existing Pods keep their injected settings.
  Recreate them:

  ```powershell
  kubectl rollout restart deployment/python-otel -n python
  kubectl rollout status deployment/python-otel -n python --timeout=300s
  ```

- **Only collector startup messages:** readiness is not proof of received data.
  Check application errors, the injected endpoint, and the matching signal
  pipeline.
- **Container logs but no OTLP logs:** this setup exports Python logging records,
  not arbitrary stdout or `print()` output. General container log collection
  needs a separate setup, such as a `filelog` receiver.

## Notes

- One collector can serve multiple microservices; give each a distinct
  `service.name`.
- The debug exporter prints telemetry; it does not provide storage or a tracing
  UI. Add a backend such as Jaeger or Tempo when needed.
- Local demo only: Flask's development server and unauthenticated OTLP endpoints
  are not production-ready. Review pinned component versions before upgrading.

## Official references

- [kind installation](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [cert-manager installation](https://cert-manager.io/docs/installation/)
- [OpenTelemetry Operator](https://opentelemetry.io/docs/platforms/kubernetes/operator/)
- [Collector and automatic instrumentation](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/)
