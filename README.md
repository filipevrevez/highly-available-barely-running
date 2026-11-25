# Highly Available, Barely Running

Slides and demo from **Highly Available, Barely Running: Multi-Region HA That Doesn't Cost Twice**,
presented by Filipe Revez and Nuno Guedes at KCD Porto × DevOps Days Portugal on 20 November 2026.
The talk and the deck were created by Filipe Revez and Pedro Cachaldora.

A standby region that costs close to nothing until you need it, built from three CNCF projects:
[Flux](https://fluxcd.io/) decides what runs, [KEDA](https://keda.sh/) how much runs, and
[K8GB](https://www.k8gb.io/) where the traffic goes. Recap, recording and the slides as a PDF:
[filiperevez.com/talks/highly-available-barely-running](https://filiperevez.com/talks/highly-available-barely-running/).

## What's here

| Path | What it is |
| --- | --- |
| `slides.html` | The deck, one self-contained file. Open it in a browser: arrow keys or a clicker to move, `F` for full screen. |
| `terraform/` | OpenTofu for the demo on [Hostman](https://hostman.com/): three managed Kubernetes clusters, Flux, and a dnsdist DNS front per site cluster. |
| `gitops/` | Everything Flux deploys on the clusters. |
| `chaos/` | The failure scenarios and the script that drops a failed cluster's open connections. |

## The demo

```
phone ──▶ kcd.example.com  CNAME  kcd.gslb.example.com
                                     │  delegated by Cloudflare to K8GB (NS + glue → DNS fronts)
                                     ▼
          dnsdist (53/UDP+TCP), one per site cluster ── TCP ──▶ Gateway :53 ──▶ K8GB CoreDNS
                                     │
                answer: the healthy cluster's Gateway IP ──▶ Gateway :443 ──▶ phone page + podinfo
```

Three clusters in one Hostman VPC:

- **porto**, the primary: serves the site while it's healthy, with 3 podinfo replicas.
- **lisboa**, the standby: a pilot light of 1 replica.
- **control**: Prometheus, Grafana and Chaos Mesh, so what watches and breaks the site clusters isn't one of them.

Porto and Lisboa are separate clusters playing the part of two regions; both run in the same Hostman
location. The site is a page that asks `/api/info` every 2 seconds and shows which cluster answered.
K8GB serves `kcd.gslb.<zone>` with the `failover` strategy and a 5-second TTL. The control cluster
probes both clusters every 5 seconds; when Porto's probe fails, KEDA on Lisboa scales podinfo from 1 to
6 (the failover floor in `gitops/failover`).

Why the DNS fronts: Hostman load balancers carry only TCP, and resolvers ask a delegated zone over UDP.
Each site cluster gets a small server running dnsdist that answers UDP and forwards over TCP to its
cluster's Gateway, which also serves the apps, so no extra load balancer is needed.

## Deploy it

You need:

- A Hostman API token.
- A domain on Cloudflare, its zone ID, and an API token for it (Zone → DNS → Edit and Zone → Zone → Read).
- A copy of this repository that Flux can pull without credentials (public), or add a deploy key yourself.
- [OpenTofu](https://opentofu.org/) 1.9 or newer.

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars   # your zone, site name, email, repository URL
export TF_VAR_hm_token=...
export TF_VAR_cloudflare_api_token=...
tofu init
tofu apply                                     # three clusters, Flux, cert-manager, external-dns, KEDA, Chaos Mesh, Prometheus
```

Wait until every cluster's Gateway has a load balancer IP (`gateway-system/cilium-gateway-public`) and
Flux has finished on all three. Then wire them together:

```sh
tofu apply -var second_apply=true              # or set second_apply = true in terraform.tfvars
```

The second apply creates the DNS fronts, points each cluster's K8GB at its own front, sends the site
clusters' metrics to the control cluster, and gives the control cluster's Chaos Mesh access to the site
clusters. A few minutes later the site answers at `site_host`, and Grafana at
`https://grafana.control.<zone>` (`tofu output -raw grafana_admin_password`).

Kubeconfigs for kubectl: `tofu output -json kubeconfigs | jq -r .porto > porto.yaml` (and `lisboa`,
`control`). The commands below assume contexts named `porto`, `lisboa` and `control`.

## Break it

The scenarios run in the control cluster, which forwards them to the site clusters. Each one breaks
podinfo for 5 minutes and then recovers on its own; nothing deletes a cluster.

| Scenario | What happens |
| --- | --- |
| `chaos/porto-down.yaml` | Porto's podinfo fails. K8GB answers with Lisboa; the probe fails, so KEDA scales Lisboa from 1 to 6. |
| `chaos/lisboa-down.yaml` | The same, the other way round. |
| `chaos/porto-slow.yaml` | Porto's podinfo answers 800 ms late. No failover: slow is not down. |

```sh
kubectl --context control create -f chaos/porto-down.yaml
SITE_HOST=kcd.example.com chaos/drop-connections.sh porto lisboa
kubectl --context control -n kcd delete podchaos porto-down   # end it early, or before running it again
```

The scenarios only fail the app, so Porto's Gateway stays up and browsers keep their open connection to
it: they would show "No answer" until that connection closes. A real outage cuts those connections.
`drop-connections.sh` does the same: once public DNS answers with Lisboa, it restarts Porto's Gateway
proxy a few times so clients reconnect and follow DNS.

The same scenarios are also in the Chaos Mesh dashboard (`https://chaos.control.<zone>`) as paused
schedules. Log in with a token: `kubectl --context control -n chaos-mesh create token chaos-admin`.

## Notes

- dnsdist health-checks the Gateway over TCP (`checkTCP`); over UDP it would mark it down.
- Cloudflare's minimum TTL is 60 seconds, so K8GB's `nsRecordTTL` is 60, and the `SITE_HOST` CNAME is
  cached for 60 seconds even though K8GB's own record has a 5-second TTL.
- A recreated Gateway gets a new IP: apply again to update `gslb-vars`. A DNS front's cloud-init changes
  too, which Hostman applies only by rebuilding the server; for a quick fix, edit
  `/etc/dnsdist/dnsdist.conf` on it and restart dnsdist.
- Prometheus and Grafana keep no persistent volumes: 3 days of data, lost when the pod moves.
- No state backend is configured; add one before sharing the stack with others.
