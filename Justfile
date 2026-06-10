set shell := ["bash", "-uc"]

LAN_IP := `ip -4 addr show | awk '/inet / && $2 !~ /^127/ {print $2}' | cut -d/ -f1 | head -n1`
CLUSTER := "canary-poc"
GATEWAY_API_VERSION := "v1.2.1"

default:
    @just --list

# === cluster lifecycle ===

up:
    k3d cluster create --config bootstrap/k3d-cluster.yaml

down:
    k3d cluster delete {{CLUSTER}}

# === platform install (run in order, or use `just bootstrap`) ===

install-gateway-crds:
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/{{GATEWAY_API_VERSION}}/standard-install.yaml
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/{{GATEWAY_API_VERSION}}/experimental-install.yaml

install-cilium:
    helm repo add cilium https://helm.cilium.io >/dev/null
    helm repo update cilium
    helm upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      -f bootstrap/cilium-values.yaml \
      --wait --timeout 5m
    kubectl -n kube-system rollout status ds/cilium

install-namespaces:
    kubectl apply -f bootstrap/app-namespaces.yaml
    kubectl apply -f bootstrap/gateway/namespace.yaml

install-gateway:
    kubectl apply -f bootstrap/gateway/gateway.yaml
    kubectl apply -f bootstrap/gateway/referencegrants.yaml
    kubectl -n gateway wait --for=condition=Programmed gateway/shared --timeout=3m

install-argocd:
    kubectl apply -f bootstrap/argocd/namespace.yaml
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/argocd/values.yaml > /tmp/argocd-values.yaml
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
    helm repo update argo
    helm upgrade --install argocd argo/argo-cd \
      --namespace argocd \
      -f /tmp/argocd-values.yaml \
      --wait --timeout 5m
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/argocd/httproute.yaml | kubectl apply -f -

install-rollouts:
    kubectl apply -f bootstrap/argo-rollouts/namespace.yaml
    helm upgrade --install argo-rollouts argo/argo-rollouts \
      --namespace argo-rollouts \
      -f bootstrap/argo-rollouts/values.yaml \
      --wait --timeout 5m
    kubectl apply -f bootstrap/argo-rollouts/gateway-plugin-rbac.yaml
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/argo-rollouts/httproute.yaml | kubectl apply -f -
    kubectl -n argo-rollouts rollout restart deploy/argo-rollouts
    kubectl -n argo-rollouts rollout status deploy/argo-rollouts

install-kargo:
    kubectl apply -f bootstrap/kargo/namespace.yaml
    helm repo add kargo https://charts.kargo.io >/dev/null
    helm repo update kargo
    helm upgrade --install kargo kargo/kargo \
      --namespace kargo \
      -f bootstrap/kargo/values.yaml \
      --wait --timeout 5m
    sed "s/__LAN_IP__/{{LAN_IP}}/g" bootstrap/kargo/httproute.yaml | kubectl apply -f -

install-platform: install-gateway-crds install-cilium install-namespaces install-gateway install-argocd install-rollouts install-kargo

# === Kargo credentials ===

# Apply Kargo git credentials. Requires env var: K8S_CANARY_PAT
install-kargo-credentials:
    @test -n "${K8S_CANARY_PAT:-}" || (echo "set K8S_CANARY_PAT to your PAT"; exit 1)
    kubectl create namespace canary-poc --dry-run=client -o yaml | kubectl apply -f -
    PAT="${K8S_CANARY_PAT}" envsubst < bootstrap/kargo/credentials.template.yaml | kubectl apply -f -

# === apps (Argo CD app-of-apps + Kargo project) ===

install-apps:
    kubectl apply -f argocd-apps/app-of-apps.yaml

# === ergonomics ===

urls:
    @echo "LAN IP: {{LAN_IP}}"
    @echo "  Argo CD:    http://argocd.{{LAN_IP}}.nip.io   (admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"
    @echo "  Kargo:      http://kargo.{{LAN_IP}}.nip.io     (admin / canary-poc-admin)"
    @echo "  Rollouts:   http://rollouts.{{LAN_IP}}.nip.io"
    @echo "  app1 dev:   http://app1-dev.{{LAN_IP}}.nip.io"
    @echo "  app1 stage: http://app1-stage.{{LAN_IP}}.nip.io"
    @echo "  app1 prod:  http://app1-prod.{{LAN_IP}}.nip.io"
    @echo "  app2 dev:   http://app2-dev.{{LAN_IP}}.nip.io"
    @echo "  app2 stage: http://app2-stage.{{LAN_IP}}.nip.io"
    @echo "  app2 prod:  http://app2-prod.{{LAN_IP}}.nip.io"
    @echo "  global:     http://global.{{LAN_IP}}.nip.io"

bootstrap: up install-platform install-kargo-credentials install-apps urls

# === demo helpers ===

watch-rollout:
    kubectl -n global get rollout global-controller -w

abort-rollout:
    kubectl-argo-rollouts -n global abort global-controller

promote-rollout:
    kubectl-argo-rollouts -n global promote global-controller
