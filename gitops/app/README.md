# Site

The talk's public site, deployed by Flux on every cluster:

- `/`: the phone page, which asks `/api/info` every 2 s and shows who answers.
- `/slides.html`: the deck (a copy of `slides.html` at the root of this repository).
- `/api/info`: podinfo, answering with this cluster's message and colour.

k8gb serves `GSLB_HOST` with the `failover` strategy. `SITE_HOST` is a CNAME to it, created by
k8gb's external-dns, so the parent zone keeps its own records and certificates. When the primary
cluster's podinfo has no ready pods, k8gb answers with the other cluster's Gateway.

## Variables (Flux `postBuild.substitute`)

| Variable | Example | Meaning |
| --- | --- | --- |
| `SITE_HOST` | `kcd.example.com` | The address people open. |
| `GSLB_HOST` | `kcd.gslb.example.com` | The name k8gb load balances, inside its delegated zone. |
| `CLUSTER_HOST` | `kcd.porto.example.com` | This cluster only, bypassing k8gb. |
| `GATEWAY_IP` | `203.0.113.10` | This cluster's Gateway load balancer IP, the address k8gb answers with. |
| `PRIMARY_GEO_TAG` | `porto` | The cluster that serves while healthy. |
| `APP_MESSAGE` | `Porto` | Shown on the phone page. |
| `APP_COLOR` | `1f6feb` | Phone page background, hex without `#`. |
| `APP_REPLICAS` | `2` | Optional, podinfo replicas. |
| `GATEWAY_NAME`, `GATEWAY_NAMESPACE` | `public`, `gateway-system` | Optional, the Gateway to attach to. |

The Gateway needs an HTTPS listener and certificate for `SITE_HOST` and `CLUSTER_HOST`.

Terraform sets every variable through the `cluster-vars` and `gslb-vars` ConfigMaps.
