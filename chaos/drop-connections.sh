#!/bin/sh
# Usage: SITE_HOST=kcd.example.com drop-connections.sh <failed cluster> <other cluster>
# (the clusters are kubectl context names)
#
# The experiments only fail the app: the failed cluster's Gateway stays up, so a phone keeps its open
# connection to it (the page polls every 2 s) and never looks DNS up again. It would show the failed
# cluster until that connection closes, minutes later. A real outage cuts those connections.
# This waits until public DNS sends SITE_HOST to the other cluster, then restarts the failed
# cluster's Gateway proxy (cilium-envoy, back in seconds), three times: phones reconnect and follow DNS.
set -eu
failed=$1 other=$2
host=${SITE_HOST:?set SITE_HOST to the site address, for example kcd.example.com}

ip=$(kubectl --request-timeout=10s --context "$other" -n gateway-system get svc cilium-gateway-public \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
[ -n "$ip" ] || { echo "no Gateway address for $other" >&2; exit 1; }

answer() {  # DNS over HTTPS: venue and home routers rewrite plain DNS
  curl -s -m 3 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$host&type=A" |
    jq -r '[.Answer[]? | select(.type == 1) | .data] | last // empty' 2>/dev/null || true
}

i=0
until [ "$(answer)" = "$ip" ]; do  # up to 2 minutes
  i=$((i + 1))
  [ $i -lt 60 ] || { echo "DNS did not move to $other within 2 minutes: left $failed's connections alone" >&2; exit 1; }
  sleep 2
done

# Drop at 5 s (the record's TTL), 20 s and 45 s after the switch: some phones or carrier resolvers keep
# the old answer longer than the TTL, reconnect to the failed cluster, and need another drop.
for wait in 5 15 25; do
  sleep $wait
  # the failed cluster's own K8GB can lag a reconcile (30 s) behind, so public DNS may flip back for a while
  j=0
  until [ "$(answer)" = "$ip" ]; do
    j=$((j + 1))
    [ $j -lt 30 ] || { echo "DNS answers $failed again for a minute: stopped dropping"; exit 0; }
    sleep 2
  done
  kubectl --request-timeout=20s --context "$failed" -n kube-system delete pod -l k8s-app=cilium-envoy --wait=false >/dev/null
  echo "$failed: Gateway proxy restarted, open connections dropped (DNS answers $other)"
done
