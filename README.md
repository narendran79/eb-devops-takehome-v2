# DevOps — Narendran Karthikeyan

## Run it
Make sure to have Docker, kind, kubectl, helm.
```bash
./setup.sh
```

## Verify
```bash
kubectl -n demo get pods,svc,ingress                 # Check the pods are running
curl -s -H 'Host: demo.local' http://localhost/      # Get to know what version is running and pod name on the host
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: demo.local' http://localhost/healthz   # Should see 200 status
```
Chart overrides:
```bash
helm template demo chart --set replicaCount=3 --set config.appName=foo | grep -E 'replicas|APP_NAME'
```
```bash
kubectl -n demo patch cm demo --type merge -p '{"data":{"APP_NAME":"changed"}}'
curl -s -H 'Host: demo.local' http://localhost/
```
`helm upgrade` with new `config.*` values also rolls the pods - checksum annotation

## Resource requests and limits
| | CPU | Memory |
|---|---|---|
| requests | 50m | 128Mi |
| limits | 200m | 256Mi |

*Why:* Till's a basic Python HTTP server, So I've configured 128Mi request to give few threads headroom and 256Mi limit so it prevent python memory leak, without throttling CPU. 50m CPU is more than enough for basic http request for a python service that is mostly idle. 200m limit allows bursts without letting one pod hog a core. All these are **estimates, not measured** once. So in production I will run a load test and size from kubectl top or using Prometheus, since CPU limits causes throttling.


## Design decisions
- **ConfigMap changes and env vars:** env vars are frozen at pod start, so patching a ConfigMap alone does not change them. The ConfigMap is therefore both injected as env (`envFrom`, the documented source) and mounted as files; the app prefers the file so a patch is visible without a restart.
- Container runs as UID 10001, read-only root FS, all capabilities dropped.
- Image tag is pinned (`0.1.0`) and `pullPolicy: IfNotPresent`, because the image is loaded into kind, not pulled.
- Base images pinned to `python:3.12.7-slim-bookworm`.

## What I deliberately skipped (and the risk)
- **HPA / PodDisruptionBudget / anti-affinity:**
- **TLS on the Ingress:**
- **NetworkPolicies:**
- **Metrics/logging/alerting:**
- **Unit tests for the service:**
- **Image pinned by tag, not digest:**

## Production-ready changes
Registry + CI-built, digest-pinned, signed images; TLS via cert-manager; HPA + PDB + topology spread; NetworkPolicies; Prometheus ServiceMonitor and alerts; structured logging; External Secrets for any secrets; GitOps (Argo CD / Flux) instead of `helm install` from a script; replace ingress-nginx with a supported Gateway API controller; chart tests (`helm test`) and a kind-based integration test in CI.

## Github Pipeline
`.github/workflows/ci.yml`: helm lint/template, docker build, Trivy scan failing on HIGH/CRITICAL.

## How I used AI
- Tool: Kubernetes Official Documentation
- Helped me to get sample reference templates and technical specifications for any configuration related doubts
- Tool: Kiro. 
- Used for: first draft of the python service and setup script. Code review of the project, got suggestion.
- AI Suggestion: After code review, AI suggested to use python:3.12.7-slim-bookworm before that I've used python:3.12.7-alpine. Its suggested that alpine image has compatibility issues, slower build times, or unexpected runtime bugs. 
- What I had to correct: <list After code review, Kiro says to use request and limit memory 64Mi and 128Mi. But to prevent memory leak and give thread to have room space, I have not changed my memory>.
