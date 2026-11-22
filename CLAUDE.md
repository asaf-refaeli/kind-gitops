# CLAUDE.md

Guidance for Claude Code in this repo.

## What this repo is

GitOps repo for the release-notes service on a local kind cluster. Argo CD
deploys everything from here: platform components (Argo CD itself, Gateway
API CRDs, Traefik, metrics-server) and the app in two environments (dev,
prod). The app's Helm chart lives in the release-notes repo (`chart/`) and is
published by its CI to `ghcr.io/asaf-refaeli/charts` (OCI); this repo pins its
version and holds only the per-environment values. See README.md for the layout.

## Rules

- **Cluster access:** only context `kind-release-notes`. Every `kubectl` call
  uses `--context kind-release-notes`, every `helm` call `--kube-context
  kind-release-notes`. The kubeconfig holds other clusters; never touch them.
  Show state-changing commands before running them.
- **GitOps only:** change Git, not the cluster. The only imperative steps are
  in `scripts/bootstrap.sh` (Argo CD install, root apply).
- **No secrets in Git.** The DB password Secret is created in the cluster by
  the release-notes chart (a PreSync Job), only if it is missing.
- **Environments differ only in** `workloads/apps/release-notes/values-dev.yaml`
  and `values-prod.yaml`. The two Application files differ only in name,
  namespace and values file. Values files use only keys that exist in the
  chart's `values.yaml` (the chart's schema rejects unknown keys).
- **File name = Application name** in `bootstrap/apps/`. `bootstrap.sh` builds
  its list of apps to wait for from the file names.
- **Plain Application files**, no ApplicationSets (the ApplicationSet
  controller is scaled to zero).
- **Pin everything:** chart versions in `Chart.yaml` + committed `Chart.lock`,
  the Gateway API manifest by release tag, the kind node image by tag + digest.
  Never commit `workloads/platform/*/charts/`.
- **The `argocd` Application** keeps release name `argo-cd` (same as
  `bootstrap.sh`) and has no resources-finalizer, so deleting it never deletes
  Argo CD.
- **New cluster-scoped kinds** need an entry in the AppProject's
  `clusterResourceWhitelist`, or the sync fails.

## Style

- Every file has short comments that explain why, not what.
- Plain, concise English. No "we" / "our": a single developer wrote it.
- Never write "step N" (plan step numbers) in any repo file; name the thing
  instead (chart, CI, rollout).
- Scripts start with `set -euo pipefail` and `cd "$(dirname "$0")/.."`.
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).

## Validate before committing (no cluster needed)

```bash
for f in scripts/*.sh; do bash -n "$f"; done
shellcheck scripts/*.sh                       # if installed
# dependency build needs each Chart.lock repository registered locally
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update
for c in argocd traefik metrics-server; do
  helm dependency build workloads/platform/$c && helm template $c workloads/platform/$c >/dev/null
done
kubectl kustomize workloads/platform/gateway-api >/dev/null
```
