# OpenSearch Observability Stack on Minikube

A fast, local observability demo that deploys OpenSearch, OpenSearch Dashboards, Jaeger (OpenSearch storage), and the OpenTelemetry Demo to Minikube.

This README gives you the quickest path to up and running.

## Quick Start (Minikube)

1) Clone the repo locally
```
git clone https://github.com/danish9039/otel-opensearch-jaeger-demo.git
```

2) Start Minikube (recommended resources)
```
minikube start --memory=6144 --cpus=4
```

3) Deploy the stack (portable script)
```
chmod +x *.sh
./deploy.sh
```

4) Port-forward to access UIs
```
# Use the helper script (recommended)
./start-port-forwarding.sh

# Or do it manually
kubectl port-forward -n jaeger svc/jaeger-query-clusterip 16686:16686 &
kubectl port-forward -n opensearch svc/opensearch-dashboards 5601:5601 &
kubectl port-forward -n opensearch svc/opensearch-cluster-single 9200:9200 &
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080 &
kubectl port-forward -n otel-demo svc/load-generator 8089:8089 &
```

5) Open the URLs
- Jaeger UI: http://localhost:16686
- OpenSearch Dashboards: http://localhost:5601
- OpenSearch API: http://localhost:9200
- OTEL Demo Frontend: http://localhost:8080
- Load Generator: http://localhost:8089

6) Cleanup
```
# Preferred: full cleanup script
./cleanup.sh
```

### Fast one-liner cleanup (force delete, zero grace period)
If you want the fastest teardown, run this single command. It will stop port-forwards and force-delete the namespaces immediately.
```
pkill -f "kubectl port-forward" 2>/dev/null || true; for ns in otel-demo jaeger opensearch; do kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true; done
```

Note: This one-liner uses --force and --grace-period=0 for faster deletion as preferred. It’s meant for local demos; use with care.

## Files
- deploy.sh:  deployment script
- start-port-forwarding.sh: Starts all port-forward sessions
- cleanup.sh: Removes all components


## Troubleshooting
- Ensure Minikube is running and kubectl points to it
- If ports are busy, kill existing forwards: pkill -f "kubectl port-forward"

