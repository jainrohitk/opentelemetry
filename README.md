# OpenTelemetry on Kubernetes: Python Quick Start

Run two communicating Python services on kind and view traces, metrics, and logs in Grafana.
Collector debug output also shows signal counts. No application image build is needed.

## Architecture

```mermaid
flowchart TB
    Browser["Browser / curl<br/>Local access through nohup port-forwards"]

    subgraph Cluster["kind cluster: mykind"]
        subgraph Platform["Platform components"]
            CertManager["cert-manager<br/>Namespace: cert-manager"]
            Operator["OpenTelemetry Operator<br/>Namespace: opentelemetry-operator-system"]
        end

        subgraph PythonNamespace["Namespace: python"]
            Instrumentation["Python Instrumentation<br/>Collector endpoint and SDK settings"]
            App["Python Flask Pod<br/>Auto-instrumented<br/>Port 5000"]
            Client["Python caller Pod<br/>Auto-instrumented<br/>Port 5000"]
        end

        subgraph DefaultNamespace["Namespace: default"]
            Collector["OpenTelemetry Collector<br/>demo-collector"]
            Tempo[("Tempo<br/>Trace storage")]
            Prometheus[("Prometheus<br/>Metrics storage")]
            Loki[("Loki<br/>Log storage")]
            Grafana["Grafana<br/>Explore traces, metrics, and logs"]
            DebugLogs["Collector debug logs<br/>Traces, metrics, and logs"]
        end
    end

    Browser -->|"App: localhost:5000 to Pod:5000"| App
    Browser -->|"Caller: localhost:5001 to Pod:5000"| Client
    Client -->|"HTTP via python-server Service :5000"| App
    Browser -->|"Grafana: localhost:3000 to Service:3000"| Grafana
    Browser -->|"Prometheus UI: localhost:9090 to Service:9090"| Prometheus

    CertManager -.->|"Webhook TLS certificates"| Operator
    Instrumentation -.->|"Instrumentation settings"| Operator
    Operator -.->|"Inject Python libraries when annotated Pods are created"| App
    Operator -.->|"Inject Flask and Requests instrumentation"| Client
    Operator -.->|"Manage Collector resources"| Collector

    App -->|"Traces, metrics, logs: OTLP HTTP :4318"| Collector
    Client -->|"Traces, metrics, logs: OTLP HTTP :4318"| Collector
    Collector -->|"Traces: OTLP gRPC :4317"| Tempo
    Collector -->|"Logs: OTLP HTTP :3100/otlp/v1/logs"| Loki
    Tempo -->|"Service-graph metrics: remote write :9090"| Prometheus
    Prometheus -->|"Scrape app metrics: HTTP :8889 every 15s"| Collector
    Grafana -->|"Query traces: HTTP :3200"| Tempo
    Grafana -->|"Query metrics: HTTP :9090"| Prometheus
    Grafana -->|"Query logs: HTTP :3100"| Loki
    Collector -->|"Debug exporter: all three signals"| DebugLogs

    classDef app fill:#DBEAFE,stroke:#2563EB,color:#0F172A
    classDef collector fill:#FEF3C7,stroke:#D97706,color:#0F172A
    classDef storage fill:#DCFCE7,stroke:#16A34A,color:#0F172A
    classDef platform fill:#EDE9FE,stroke:#7C3AED,color:#0F172A
    class App,Client app
    class Collector,Grafana collector
    class Tempo,Prometheus,Loki storage
    class CertManager,Operator,Instrumentation platform
```

Solid arrows show telemetry or query/request traffic; dotted arrows show
configuration and management. Prometheus pulls metrics from the Collector;
Tempo remote-writes trace-derived metrics to Prometheus. Grafana queries Tempo,
Prometheus, and Loki. Logs are stored in Loki and also counted in Collector output.

| Resource | Namespace |
| --- | --- |
| cert-manager | `cert-manager` |
| OpenTelemetry Operator | `opentelemetry-operator-system` |
| Collector `demo` | `default` |
| Tempo, Prometheus, Loki, and Grafana | `default` |
| Python backend Service, both Deployments, and Instrumentation | `python` |

Use **PowerShell** unless a block is marked **Bash**, from this repository's root.
Install Docker Desktop (Linux
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
Python services to pick up instrumentation changes. Tempo restarts to reload
metrics-generator settings, Loki restarts to reload its configuration, and
Grafana restarts to reload its provisioned data sources. These restarts clear
their temporary demo data. A different existing operator version requires manual review.

The script starts and checks four `nohup` port-forwards: Python on `5000`,
the caller on `5001`, Grafana on `3000`, and Prometheus on `9090`. Logs and PIDs are saved in
`.port-forward/` (ignored by Git). Stop existing recorded forwards before
rerunning setup. Once all four forwards are healthy, the script opens
http://localhost:5000/otel-test, http://localhost:5001/otel-test,
http://localhost:3000, and http://localhost:9090
in your default browser. It uses PowerShell on Windows (Git Bash), `open` on
macOS, and `xdg-open` on Linux. If no browser launcher is available or launching
fails (for example, in a headless session), it warns and leaves the forwards
running so you can open the URLs manually. Use Step 5 to generate more traffic;
the setup steps below are the manual alternative.

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

## 4. Deploy storage, Grafana, the Collector, and Python

Create the namespace first so Instrumentation exists before the application
Pods. The Deployment file also declares the namespace.

```powershell
kubectl apply -f .\tempo.yaml
kubectl rollout restart deployment/tempo -n default
kubectl rollout status deployment/tempo -n default --timeout=300s
kubectl apply -f .\prometheus.yaml
kubectl rollout status deployment/prometheus -n default --timeout=300s
kubectl apply -f .\loki.yaml
kubectl rollout restart deployment/loki -n default
kubectl rollout status deployment/loki -n default --timeout=300s
kubectl apply -f .\grafana.yaml
kubectl rollout restart deployment/grafana -n default
kubectl rollout status deployment/grafana -n default --timeout=300s
kubectl apply -f .\otel-collector.yaml
kubectl wait --for=condition=Ready opentelemetrycollector/demo -n default --timeout=180s
kubectl rollout status deployment/demo-collector -n default --timeout=180s
kubectl create namespace python --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f .\py-instrumentation.yaml
kubectl apply -f .\py-server.yaml
kubectl rollout status deployment/python-server -n python --timeout=300s
kubectl apply -f .\py-client.yaml
kubectl rollout status deployment/python-client -n python --timeout=300s
```

| File | Purpose |
| --- | --- |
| [otel-operator.yaml](./otel-operator.yaml) | Install the operator, CRDs, permissions, and webhooks (Step 3) |
| [tempo.yaml](./tempo.yaml) | Store and query traces |
| [prometheus.yaml](./prometheus.yaml) | Scrape and store application metrics from the Collector |
| [loki.yaml](./loki.yaml) | Store and query OpenTelemetry application logs |
| [grafana.yaml](./grafana.yaml) | Grafana UI with Tempo, Prometheus, and Loki data sources already configured |
| [otel-collector.yaml](./otel-collector.yaml) | Export traces to Tempo and logs to Loki, expose metrics to Prometheus, and print all three signals |
| [py-instrumentation.yaml](./py-instrumentation.yaml) | Configure Python instrumentation and the collector endpoint |
| [py-server.yaml](./py-server.yaml) | Create namespace `python` and run an inline Flask app using official `python:3.12-slim` |
| [py-client.yaml](./py-client.yaml) | Run an instrumented Flask caller that uses Requests to call the backend Service |

When migrating from the old `python-otel` name, deploy `python-server` and wait
for readiness before applying the updated caller. Verify a caller request, then
remove only the old Deployment and Service:

```powershell
kubectl --context kind-mykind delete deployment/python-otel service/python-otel -n python
```

Restart the two Python port-forwards after migration. Historical telemetry keeps
the old service name until it ages out; fresh traffic uses `python-server`.

The apps install Flask (and Requests for the caller) at startup, so each new container needs internet access.
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

### Background port-forwards

Setup starts these automatically. For a manual setup, run the following in
**Git Bash** on Windows, or Bash on Linux/macOS, not PowerShell:

```bash
mkdir -p .port-forward
nohup kubectl --context kind-mykind port-forward deployment/python-server 5000:5000 -n python --address 127.0.0.1 > .port-forward/python.log 2>&1 < /dev/null &
echo $! > .port-forward/python.pid
nohup kubectl --context kind-mykind port-forward deployment/python-client 5001:5000 -n python --address 127.0.0.1 > .port-forward/python-client.log 2>&1 < /dev/null &
echo $! > .port-forward/python-client.pid
nohup kubectl --context kind-mykind port-forward service/grafana 3000:3000 -n default --address 127.0.0.1 > .port-forward/grafana.log 2>&1 < /dev/null &
echo $! > .port-forward/grafana.pid
nohup kubectl --context kind-mykind port-forward service/prometheus 9090:9090 -n default --address 127.0.0.1 > .port-forward/prometheus.log 2>&1 < /dev/null &
echo $! > .port-forward/prometheus.pid
```

| App | URL |
| --- | --- |
| Python | http://localhost:5000/otel-test |
| Python caller | http://localhost:5001/otel-test |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |

Inspect `.port-forward/*.log` if a port is already in use or a forward exits.
`nohup` keeps forwards running after the shell exits; it does not restart them
if a Pod is replaced or the cluster connection drops.

To stop them in Bash, first confirm the recorded PIDs still belong to these
`kubectl` forwards, then run:

```bash
kill "$(cat .port-forward/python.pid)"
kill "$(cat .port-forward/python-client.pid)"
kill "$(cat .port-forward/grafana.pid)"
kill "$(cat .port-forward/prometheus.pid)"
```

### Generate traffic

With the caller port-forward running, use [generate-traffic.ps1](./generate-traffic.ps1)
from PowerShell to send 5,000 requests at approximately 10-20 requests per second,
with up to 2 requests in flight. Traffic goes to the caller on port `5001`, which
forwards it to `python-server`. Paths, query parameters, and pacing are randomized:

```powershell
.\generate-traffic.ps1
```

Current default values:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `Count` | `5000` | Total requests |
| `MinRequestsPerSecond` | `10` | Lower end of randomized target rate |
| `MaxRequestsPerSecond` | `20` | Upper end of randomized target rate |
| `Concurrency` | `2` | Maximum requests in flight |
| `Port` | `5001` | Caller port-forward |

For example, override these defaults for a shorter run with higher concurrency:

```powershell
.\generate-traffic.ps1 -Count 2000 -MinRequestsPerSecond 15 -MaxRequestsPerSecond 20 -Concurrency 5
```

Use `-Port 5000` to target the backend directly instead; those requests do not
create a `python-client` to `python-server` relationship.

The rate applies to the whole script, not each worker. Slow responses may lower
the achieved rate once the concurrency limit is reached; missed slots are not
replayed as bursts. At the target rate, the default run takes about 4-8 minutes;
slow responses can make it take longer.
The script prints each response status, a summary, and the measured average rate.
Failed requests produce warnings, and the script exits with code `1` if any
request fails. It uses asynchronous HTTP requests and supports Windows PowerShell
5.1 and PowerShell 7.

Watch the collector in another terminal:

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

### What is Tempo?

**Grafana Tempo is a tracing backend:** it stores traces and lets Grafana search
and retrieve them. A **trace** describes a request's journey through an
application; its **spans** describe individual operations and their duration.
Across microservices, propagated trace context links those spans into one trace.

In this setup:

- The Python app generates traces through OpenTelemetry auto-instrumentation.
- The Collector receives them and forwards them to Tempo using OTLP/gRPC on
  port `4317`.
- Grafana queries Tempo's HTTP API on port `3200` and displays the spans and
  timing. **Tempo stores the traces; Grafana provides the UI.**

Tempo does not store this app's metrics or logs. Prometheus stores metrics;
Loki stores logs. The [Tempo manifest](./tempo.yaml)
uses temporary Pod storage, so its traces disappear when the Pod is replaced.

### View traces in Grafana

Open **http://localhost:3000**; no login is needed for this local demo.
Choose **Explore > Tempo**, select the last 15 minutes, and run this TraceQL query:

```traceql
{ resource.service.name = "python-server" }
```

Generate fresh app requests, allow a few seconds for export, then refresh.
Select a trace to inspect its spans and timing.

Grafana queries Tempo; it does not read traces from the collector's logs.

### View metrics in Grafana

In the same Grafana instance, choose **Explore > Prometheus** and run:

```promql
{service_name="python-server"}
```

Generate app requests and allow 60-90 seconds for Python's periodic metrics
export and Prometheus scraping. Switch to a graph to see values over time.
To find HTTP request measurements, use:

```promql
{service_name="python-server", __name__=~"http_.*"}
```

Prometheus scrapes the Collector's application-metrics exporter on port `8889`,
not the Collector's internal monitoring port `8888`. The exporter includes
resource attributes as labels, including `service_name`.

### View logs in Grafana

Choose **Explore > Loki**, select the last 15 minutes, and run:

```logql
{service_name="python-server"}
```

Generate fresh requests using Step 5, wait a few seconds for export, and refresh.
The Collector sends application log records to Loki's native OTLP HTTP endpoint.
Loki converts the resource attribute `service.name` into the label `service_name`.
Expand a log entry to inspect structured metadata, including trace and span IDs
when present.

No extra port-forward is needed: Grafana queries Loki inside the cluster.
Collector debug output remains enabled. This does not collect arbitrary
container stdout or Kubernetes system logs; those need a separate log collector.
Logs emitted before Loki was connected are not backfilled from Collector output.

### View service graphs in Grafana

Choose **Explore > Tempo > Service Graph** and run a query. The Tempo data
source is provisioned with the Prometheus data source linked under **Service
graph**. Tempo's metrics-generator produces service-graph and span metrics and
remote-writes them to Prometheus; the Collector's application metrics alone do
not provide service graphs.

Generate fresh requests and allow 60-90 seconds, then query
`traces_spanmetrics_calls_total` in **Explore > Prometheus** to confirm metrics
generation. For graph edges, query `traces_service_graph_request_total`.
Traffic through port `5001` should show `python-client -> python-server`.
Both services use the same Instrumentation resource with W3C trace-context
propagation. Flask creates server spans and Requests creates the caller's
outgoing client spans; both services' spans belong to the same trace.
External callers may also appear as a virtual node.

To verify the relationship in **Explore > Prometheus**, query:

```promql
traces_service_graph_request_total{client="python-client", server="python-server"}
```

In **Explore > Tempo**, search for `{ resource.service.name = "python-client" }`
and open a trace to inspect spans from both services. To see both services' logs
in Loki, use `{service_name=~"python-client|python-server"}`.

If Grafana reports **No service graph datasource selected**, apply
[grafana.yaml](./grafana.yaml) and restart Grafana to reload provisioning. For
an existing installation, also apply [tempo.yaml](./tempo.yaml) and
[prometheus.yaml](./prometheus.yaml), restart Tempo, and wait for all three
Deployments to become ready using Step 4. Restarting Tempo, Grafana, or
Prometheus clears that component's temporary demo data. Their active
port-forwards may exit when Pods are replaced; inspect and stop any remaining
recorded forwards before starting new ones.

## Troubleshooting

Start with application logs and Pod details:

```powershell
kubectl logs -n python deployment/python-server -c python-server --tail=100
kubectl describe pods -n python -l app=python-server
kubectl exec -n python deployment/python-server -c python-server -- printenv OTEL_EXPORTER_OTLP_ENDPOINT
```

- **No injection:** check the Pod-template annotation and the Instrumentation
  resource in `python`. Pod details should show the
  `opentelemetry-auto-instrumentation-python` init container.
- **Instrumentation changed:** existing Pods keep their injected settings.
  Recreate them:

  ```powershell
  kubectl rollout restart deployment/python-server -n python
  kubectl rollout status deployment/python-server -n python --timeout=300s
  ```

- **Only collector startup messages:** readiness is not proof of received data.
  Check application errors, the injected endpoint, and the matching signal
  pipeline.
- **Container logs but no OTLP logs:** this setup exports Python logging records,
  not arbitrary stdout or `print()` output. General container log collection
  needs a separate setup, such as a `filelog` receiver.
- **No traces in Grafana:** generate fresh requests and check the time range,
  Tempo readiness, and Collector export errors. Traces received before Tempo was
  configured are not backfilled from Collector logs.
- **Tempo restarts during traffic:** inspect its Pod's last termination reason
  and logs. The demo gives Tempo a `1Gi` memory limit and an `800MiB` Go memory
  target for trace ingestion and metrics generation; larger loads may need more.
  `OOMKilled` means the container exceeded its memory limit. Config parse errors
  require correcting the embedded YAML in [tempo.yaml](./tempo.yaml).
- **No metrics in Grafana:** allow 60-90 seconds after making requests. Check
  Prometheus readiness and its scrape target, and confirm the Collector Service
  exposes port `8889`. Rerun setup to reload the Grafana data sources.
- **No logs in Grafana:** generate fresh requests, check Loki readiness and
  Collector export errors, and use `{service_name="python-server"}` in Explore.
  Loki's OTLP ingestion requires schema `v13` and structured metadata enabled.
  Apply the Loki, Collector, and Grafana manifests and restart Grafana if the
  Loki data source is missing.

## Notes

- One collector can serve multiple microservices; give each a distinct
  `service.name`.
- Tempo uses temporary Pod storage: traces are lost when its Pod is replaced.
  Prometheus metrics, Loki logs, and Grafana's local database are temporary too;
  all three Grafana data sources are provisioned automatically at startup.
- Grafana allows anonymous Editor access for Explore. Keep it internal and use
  localhost port-forward only; configure authentication before exposing it.
- Local demo only: Flask's development server and unauthenticated OTLP endpoints
  are not production-ready. Review pinned component versions before upgrading.

## Official references

- [kind installation](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [cert-manager installation](https://cert-manager.io/docs/installation/)
- [OpenTelemetry Operator](https://opentelemetry.io/docs/platforms/kubernetes/operator/)
- [Collector and automatic instrumentation](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/)
- [Tempo data source](https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/)
- [Tempo service graphs](https://grafana.com/docs/grafana/latest/datasources/tempo/service-graph/)
- [Prometheus data source](https://grafana.com/docs/grafana/latest/datasources/prometheus/)
- [Loki OpenTelemetry ingestion](https://grafana.com/docs/loki/latest/send-data/otel/)
