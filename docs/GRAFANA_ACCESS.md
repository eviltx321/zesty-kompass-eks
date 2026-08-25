# Accessing Grafana

Kompass's Grafana is only reachable from inside the cluster (`ClusterIP` service, no public
endpoint) — use `kubectl port-forward` to reach it from your machine.

## 1. Point kubectl at the cluster

```bash
aws eks update-kubeconfig --name zesty-kompass --region eu-west-1 \
  --profile 695214758399_AdministratorAccess
```

## 2. Get the admin password

```bash
kubectl get secret --namespace zesty-system kompass-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

Username is `admin`. **Note:** `values.yaml` doesn't override the chart's default
`grafana.adminPassword`, so this is currently the chart's plaintext default (`password`) rather
than a generated secret — worth rotating if this cluster is anything other than a throwaway
demo/dev environment.

## 3. Port-forward

```bash
kubectl port-forward -n zesty-system svc/kompass-grafana 3000:80
```

Leave that running, then open **http://localhost:3000** and log in with `admin` / the password
from step 2.

## Notes

- The service is `kompass-grafana` (`ClusterIP`, port `80`) in the `zesty-system` namespace — no
  LoadBalancer or Ingress is provisioned for it. If you want external access instead of
  port-forwarding, that'd need a new `Service`/`Ingress` added to this deployment (not currently
  part of it) or a tool like `kubectl port-forward --address 0.0.0.0` (still requires network
  access to wherever `kubectl` is running).
- Grafana's PVC (`storage-kompass-grafana-0`, 1Gi on `gp2`) persists dashboards/settings across
  pod restarts, so this survives normal cluster operation - only a full `terraform destroy` wipes
  it.
