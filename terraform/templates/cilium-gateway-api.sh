# Wait for Flux to install the Gateway API CRDs (gitops/cluster/gateway-api.yaml).
until kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io tcproutes.gateway.networking.k8s.io >/dev/null 2>&1; do sleep 10; done
helm repo add cilium https://helm.cilium.io >/dev/null
version=$(helm list -n kube-system -f '^cilium$' -o json | jq -r '.[0].chart' | sed 's/^cilium-//')
helm upgrade cilium cilium/cilium -n kube-system --version "$version" --reuse-values --set gatewayAPI.enabled=true
kubectl -n kube-system rollout restart deploy/cilium-operator ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=10m
