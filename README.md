# k8s-canary

Cluster bootstrap + GitOps config for the canary POC.

- `bootstrap/` — k3d cluster, Cilium, Gateway API CRDs, Argo CD, Argo Rollouts, Kargo, shared Gateway.
- `kargo/` — Kargo Project, Warehouse, Stages (dev → stage → prod) for the location apps.
- `apps/` — per-env Helm values files. Kargo rewrites `apps/location/*/values.yaml`
  image tags on promotion; the `canary-app` CI rewrites `apps/global/values.yaml`
  on global tag pushes.
- `argocd-apps/` — Argo CD `Application`s. Multi-source: charts from
  [`mwdomino/canary-app`](https://github.com/mwdomino/canary-app), values from this repo.
- `Justfile` — bootstrap and demo recipes.

See `.superpowers/specs/2026-06-10-canary-poc-design.md` in the workspace
parent for the full design.
