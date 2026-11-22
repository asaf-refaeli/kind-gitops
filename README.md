# kind-gitops

GitOps repository for the [release-notes](https://github.com/asaf-refaeli/release-notes)
service. One command creates a local kind cluster, installs Argo CD and
deploys two environments, `dev` and `prod`, from this repo. After that,
Argo CD is the only thing that changes the cluster: change Git and it
reconciles.

## Quick start

Needs Docker (running), kind, kubectl and helm.

```bash
./scripts/up.sh
```

It ends when every Argo CD Application is Synced and Healthy (up to 15
minutes on a first run, mostly image pulls). Then:

| Environment | URL |
|---|---|
| dev | http://dev.localhost |
| prod | http://prod.localhost |

Browsers resolve `*.localhost` to 127.0.0.1, so no `/etc/hosts` entry is
needed. Argo CD's UI is not exposed through the Gateway; `up.sh` prints the
port-forward command and how to read the admin password.

```bash
./scripts/down.sh     # delete the cluster; ./scripts/up.sh rebuilds the same state
```

Re-running `up.sh` is safe: the cluster, the Argo CD install and the database
passwords are kept. Argo CD is installed with Helm only on the first run; after
that the `argocd` Application owns it, so Argo CD changes are commits to
`workloads/platform/argocd/`.

## How it works

```
up.sh
├─ create-cluster.sh   kind cluster "release-notes", host :80 -> node :30080
└─ bootstrap.sh        helm install Argo CD (wrapper chart in workloads/platform/argocd)
                       kubectl apply -f bootstrap/root.yaml ──┐
                                                              ▼
   Application/root (project default) ── syncs bootstrap/ from Git, recursively
     ├─ wave -1  AppProject platform, AppProject release-notes
     ├─ wave  0  argocd (adopts the Helm install), gateway-api (CRDs), metrics-server
     ├─ wave  1  traefik (GatewayClass + Gateway "web")
     └─ wave  2  release-notes-dev, release-notes-prod
```

- Each wave starts only when the previous one is Healthy. Argo CD does not
  check the health of an Application by default; the health check added in
  `workloads/platform/argocd/values.yaml` makes the waves wait.
- `root.yaml` sits inside the path it syncs, so root is managed from Git too.
- Argo CD manages itself: the `argocd` Application renders the same wrapper
  chart as `bootstrap.sh`, with the same release name, so an Argo CD upgrade is
  a commit.
- The only imperative steps are the Argo CD install and applying `root.yaml`.
- The DB password never goes in Git. Argo CD creates the app namespaces, and
  the release-notes chart creates Secret `release-notes-db` with a random
  password in a PreSync Job, only if it is missing (release-notes ADR-0011).

Request path:

```
http://prod.localhost ─► host :80 ─► kind node :30080 ─► Traefik ─► Gateway "web"
  ─► HTTPRoute (host prod.localhost) ─► Service ─► one of the prod pods
```

## Environments

Both environments run the same chart (published by the release-notes CI to
`ghcr.io/asaf-refaeli/charts`, pinned by version) and the same image. The two Application files differ only in name, namespace
and values file; every other difference is in the values files:

| | dev | prod |
|---|---|---|
| Namespace | `release-notes-dev` | `release-notes-prod` |
| Replicas | 1, no HPA | HPA 2 to 4 on CPU |
| PodDisruptionBudget | off | `maxUnavailable: 1` |
| Log level | DEBUG | INFO |
| Postgres volume | 1Gi | 2Gi |
| Hostname | `dev.localhost` | `prod.localhost` |

Each namespace stands in for a separate cluster; in production only the
Application's `destination.server` would change. Project `release-notes`
allows only these two namespaces, and Argo CD labels both with the Pod
Security `restricted` profile.

## How a change ships

| Change | Where | What happens |
|---|---|---|
| New app version | `image.tag` + `image.digest` in `values-dev.yaml` / `values-prod.yaml` | Written by the release-notes CI (by hand until that pipeline exists). Argo CD syncs the new image. |
| Chart change | `targetRevision` (chart version) of the OCI chart source in `bootstrap/apps/release-notes-*.yaml` | Written by the release-notes CI on each chart release. Argo CD pulls `ghcr.io/asaf-refaeli/charts/release-notes:<version>`; the registry is registered in `workloads/platform/argocd/values.yaml`. |
| Env setting | `workloads/apps/release-notes/values-*.yaml` | Commit; Argo CD applies it (polls every ~3 min). |
| Platform | `workloads/platform/<name>/` | Commit; same. A chart bump is a `version` change in `Chart.yaml` plus a new `Chart.lock` (`helm dependency update`). |

Rollback is `git revert` of the change. A hand edit in the cluster is reverted
by self-heal.

## Layout

```
kind/cluster.yaml                 node image (tag + digest), port mapping 80 -> 30080
scripts/
├── up.sh                         create-cluster.sh, then bootstrap.sh
├── create-cluster.sh             kind only; keeps an existing cluster
├── bootstrap.sh                  Argo CD, root, wait until Healthy
└── down.sh                       delete the cluster
bootstrap/                        what Argo CD knows about; root syncs it
├── root.yaml                     the GitOps seed
├── projects/
│   ├── platform.yaml             this repo, namespaces argocd/traefik/kube-system,
│   │                               explicit list of cluster-scoped kinds
│   └── release-notes.yaml        two repos, two namespaces, Namespace only
└── apps/                         one Application per file; file name = Application name
    ├── argocd.yaml               wave 0
    ├── gateway-api.yaml          wave 0
    ├── traefik.yaml              wave 1
    ├── metrics-server.yaml       wave 0
    ├── release-notes-dev.yaml    wave 2
    └── release-notes-prod.yaml   wave 2
workloads/                        what gets deployed
├── platform/
│   ├── argocd/                   [helm] wrapper: argo-cd 10.18.2 (Argo CD v3.6.2)
│   ├── gateway-api/              [kustomize] upstream standard-install v1.6.3
│   ├── traefik/                  [helm] wrapper: traefik 42.4.1 (Traefik v3.7.19)
│   └── metrics-server/           [helm] wrapper: metrics-server 3.14.0 (v0.9.0)
└── apps/release-notes/
    ├── values-dev.yaml
    └── values-prod.yaml
```

Wrapper charts pin the upstream chart in `Chart.yaml` and `Chart.lock`, so
every Application's source is this repo. Argo CD's repo-server runs
`helm dependency build` itself; the downloaded `charts/` folders are
gitignored.

## Break-glass: Argo CD itself is broken

If a bad commit to `workloads/platform/argocd/` stops Argo CD, nothing is left to
apply the fix. Revert the commit in Git, then apply the good values by hand once:

```bash
helm --kube-context kind-release-notes upgrade argo-cd workloads/platform/argocd \
  -n argocd --force-conflicts
```

`--force-conflicts` takes the fields back from Argo CD's field manager. Once Argo
CD runs again, it syncs from Git and owns them again.

## Troubleshooting

```bash
kubectl --context kind-release-notes -n argocd get applications
kubectl --context kind-release-notes -n argocd describe application <name>   # sync errors, conditions
kubectl --context kind-release-notes -n release-notes-prod get httproute     # Accepted by the Gateway?
```

- `not permitted in project`: the Application targets a namespace or a
  cluster-scoped kind its AppProject does not allow.
- 404 from Traefik: no HTTPRoute matches the hostname.
- `create-cluster.sh` fails on a missing port mapping: the cluster was created
  without `kind/cluster.yaml`. Run `./scripts/down.sh && ./scripts/up.sh`.
