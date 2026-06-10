set shell := ["bash", "-uc"]

LAN_IP := `ip -4 addr show | awk '/inet / && $2 !~ /^127/ {print $2}' | cut -d/ -f1 | head -n1`
CLUSTER := "canary-poc"
KUBE_CONTEXT := "kind-canary-poc"
GATEWAY_API_VERSION := "v1.2.1"

default:
    @just --list

# Internal: refuse to proceed unless current kube-context matches KUBE_CONTEXT.
# Every recipe that touches the cluster depends on this.
_require-context:
    @current=$(kubectl config current-context 2>/dev/null || echo "<none>"); \
     if [ "$current" != "{{KUBE_CONTEXT}}" ]; then \
       echo "ERROR: current kube-context is '$current', expected '{{KUBE_CONTEXT}}'."; \
       echo "Run: kubectl config use-context {{KUBE_CONTEXT}}"; \
       exit 1; \
     fi

# === cluster lifecycle ===

up:
    kind create cluster --config bootstrap/kind-cluster.yaml
    kubectl config use-context {{KUBE_CONTEXT}}

down:
    -pkill -f cloud-provider-kind
    kind delete cluster --name {{CLUSTER}}

# Run cloud-provider-kind in the background so LoadBalancer Services get
# external IPs AND their ports get mapped to the host.
lb-up:
    @if pidof cloud-provider-kind >/dev/null; then \
       echo "cloud-provider-kind already running (pid $(pidof cloud-provider-kind))"; \
     else \
       nohup cloud-provider-kind --enable-lb-port-mapping >/tmp/cpk-canary-poc.log 2>&1 & \
       echo "cloud-provider-kind started (pid $!), logs in /tmp/cpk-canary-poc.log"; \
     fi
    @sleep 5

# === platform install (run in order, or use `just bootstrap`) ===

install-gateway-crds: _require-context
    kubectl --context {{KUBE_CONTEXT}} apply --server-side --validate=false -f https://github.com/kubernetes-sigs/gateway-api/releases/download/{{GATEWAY_API_VERSION}}/standard-install.yaml
    kubectl --context {{KUBE_CONTEXT}} apply --server-side --validate=false -f https://github.com/kubernetes-sigs/gateway-api/releases/download/{{GATEWAY_API_VERSION}}/experimental-install.yaml

install-cilium: _require-context
    helm repo add cilium https://helm.cilium.io 2>/dev/null || true
    helm repo update cilium
    helm --kube-context {{KUBE_CONTEXT}} upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      -f bootstrap/cilium-values.yaml \
      --wait --timeout 5m
    kubectl --context {{KUBE_CONTEXT}} -n kube-system rollout status ds/cilium

install-namespaces: _require-context
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/app-namespaces.yaml
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/gateway/namespace.yaml

install-gateway: _require-context lb-up
    # Tell Cilium to render the gateway's Service as LoadBalancer (default is ClusterIP).
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/gateway/gatewayclassconfig.yaml
    kubectl --context {{KUBE_CONTEXT}} patch gatewayclass cilium --type=merge -p '{"spec":{"parametersRef":{"group":"cilium.io","kind":"CiliumGatewayClassConfig","name":"lb","namespace":"default"}}}'
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/gateway/gateway.yaml
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/gateway/referencegrants.yaml
    kubectl --context {{KUBE_CONTEXT}} -n gateway wait --for=condition=Programmed gateway/shared --timeout=3m

install-argocd: _require-context
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/argocd/namespace.yaml
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/argocd/values.yaml > /tmp/argocd-values.yaml
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update argo
    helm --kube-context {{KUBE_CONTEXT}} upgrade --install argocd argo/argo-cd \
      --namespace argocd \
      -f /tmp/argocd-values.yaml \
      --wait --timeout 5m
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/argocd/httproute.yaml | kubectl --context {{KUBE_CONTEXT}} apply -f -

install-rollouts: _require-context
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/argo-rollouts/namespace.yaml
    helm --kube-context {{KUBE_CONTEXT}} upgrade --install argo-rollouts argo/argo-rollouts \
      --namespace argo-rollouts \
      -f bootstrap/argo-rollouts/values.yaml \
      --wait --timeout 5m
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/argo-rollouts/gateway-plugin-rbac.yaml
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/argo-rollouts/httproute.yaml | kubectl --context {{KUBE_CONTEXT}} apply -f -
    kubectl --context {{KUBE_CONTEXT}} -n argo-rollouts rollout restart deploy/argo-rollouts
    kubectl --context {{KUBE_CONTEXT}} -n argo-rollouts rollout status deploy/argo-rollouts

install-cert-manager: _require-context
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack
    helm --kube-context {{KUBE_CONTEXT}} upgrade --install cert-manager jetstack/cert-manager \
      --namespace cert-manager --create-namespace \
      --set crds.enabled=true \
      --wait --timeout 5m

install-kargo: _require-context install-cert-manager
    kubectl --context {{KUBE_CONTEXT}} apply -f bootstrap/kargo/namespace.yaml
    helm --kube-context {{KUBE_CONTEXT}} upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
      --namespace kargo \
      -f bootstrap/kargo/values.yaml \
      --wait --timeout 5m
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/kargo/httproute.yaml | kubectl --context {{KUBE_CONTEXT}} apply -f -

install-platform: install-gateway-crds install-cilium install-namespaces install-gateway install-argocd install-rollouts install-kargo

# === Kargo credentials ===

# Apply Kargo git credentials. Requires env var: K8S_CANARY_PAT.
# Assumes the canary-poc namespace has already been created by Kargo
# (via the Project CR synced by install-apps). Polls up to 60s for it.
install-kargo-credentials: _require-context
    @test -n "${K8S_CANARY_PAT:-}" || (echo "set K8S_CANARY_PAT to your PAT"; exit 1)
    @echo "waiting for namespace canary-poc (created by Kargo Project sync)..."
    @for i in $(seq 1 30); do \
       kubectl --context {{KUBE_CONTEXT}} get ns canary-poc >/dev/null 2>&1 && break; \
       sleep 2; \
     done
    @kubectl --context {{KUBE_CONTEXT}} get ns canary-poc >/dev/null 2>&1 || (echo "canary-poc namespace did not appear; run 'just install-apps' first"; exit 1)
    PAT="${K8S_CANARY_PAT}" envsubst < bootstrap/kargo/credentials.template.yaml | kubectl --context {{KUBE_CONTEXT}} apply -f -

# === apps (Argo CD app-of-apps + Kargo project) ===

install-apps: _require-context
    kubectl --context {{KUBE_CONTEXT}} apply -f argocd-apps/app-of-apps.yaml

# === ergonomics ===

urls: _require-context
    @LB_PORT=$(docker ps --format '{{{{.Names}}}} {{{{.Ports}}}}' | awk '/^kindccm/ {for (i=1; i<=NF; i++) if ($i ~ /->80\/tcp/) {split($i,a,":"); split(a[2],b,"->"); print b[1]; exit}}'); \
     PORT_SUFFIX=$([ "$LB_PORT" = "80" ] && echo "" || echo ":$LB_PORT"); \
     echo "LAN IP: {{LAN_IP}}    Gateway host port: $LB_PORT"; \
     echo "  Argo CD:    http://argocd.{{LAN_IP}}.nip.io$PORT_SUFFIX   (admin / $(kubectl --context {{KUBE_CONTEXT}} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"; \
     echo "  Kargo:      http://kargo.{{LAN_IP}}.nip.io$PORT_SUFFIX     (admin / canary-poc-admin)"; \
     echo "  Rollouts:   http://rollouts.{{LAN_IP}}.nip.io$PORT_SUFFIX"; \
     echo "  app1 dev:   http://app1-dev.{{LAN_IP}}.nip.io$PORT_SUFFIX"; \
     echo "  app1 stage: http://app1-stage.{{LAN_IP}}.nip.io$PORT_SUFFIX"; \
     echo "  app1 prod:  http://app1-prod.{{LAN_IP}}.nip.io$PORT_SUFFIX"; \
     echo "  app2 dev:   http://app2-dev.{{LAN_IP}}.nip.io$PORT_SUFFIX"; \
     echo "  app2 stage: http://app2-stage.{{LAN_IP}}.nip.io$PORT_SUFFIX"; \
     echo "  app2 prod:  http://app2-prod.{{LAN_IP}}.nip.io$PORT_SUFFIX"; \
     echo "  global:     http://global.{{LAN_IP}}.nip.io$PORT_SUFFIX"

bootstrap: up lb-up install-platform install-apps install-kargo-credentials urls

# === demo helpers ===

watch-rollout: _require-context
    kubectl --context {{KUBE_CONTEXT}} -n global get rollout global-controller -w

abort-rollout: _require-context
    kubectl-argo-rollouts --context {{KUBE_CONTEXT}} -n global abort global-controller

promote-rollout: _require-context
    kubectl-argo-rollouts --context {{KUBE_CONTEXT}} -n global promote global-controller
