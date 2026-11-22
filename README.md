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

## How the bootstrap works

A script does only the two things Git cannot do: install Argo CD, and give it one starting Application. From there,
Argo CD reads this repo and builds everything else itself, in order.

`./scripts/bootstrap.sh` is the single documented command the assignment asks for: on a clean cluster it brings up
Argo CD, the platform and both environments. It can be run on its own against any cluster reachable as context
`kind-release-notes`. `./scripts/up.sh` only adds creating that kind cluster first, so one command works from an
empty machine too.

```
up.sh
├─ create-cluster.sh   kind cluster "release-notes", host :80 -> node :30080
└─ bootstrap.sh        1. helm install Argo CD (wrapper chart in workloads/platform/argocd)
                       2. kubectl apply -f bootstrap/root.yaml ──┐
                       3. wait until every Application is Synced/Healthy
                                                                 ▼
   Application/root (project default) ── syncs bootstrap/ from Git, recursively
     ├─ wave -1  AppProject platform, AppProject release-notes
     ├─ wave  0  argocd (adopts the Helm install), gateway-api (CRDs), metrics-server
     ├─ wave  1  traefik (GatewayClass + Gateway "web")
     └─ wave  2  release-notes-dev, release-notes-prod
```

1. `create-cluster.sh` creates the kind cluster from `kind/cluster.yaml`. That file maps host port 80 to node port
   30080, which is how `dev.localhost` and `prod.localhost` reach Traefik. An existing cluster is kept.
2. `bootstrap.sh` installs Argo CD once with Helm. Argo CD cannot install itself, so this is the first of only two
   imperative steps.
3. It then applies `bootstrap/root.yaml`, the second and last imperative step. `root` is an Application that syncs
   the `bootstrap/` folder: two AppProjects and one Application per file in `bootstrap/apps/`. `root.yaml` is inside
   that folder, so root manages itself from Git too.
4. Argo CD creates the children in sync waves, and each wave starts only when the previous one is Healthy:

   | Wave | Creates | Why this order |
   |---|---|---|
   | -1 | AppProjects `platform`, `release-notes` | Every Application below belongs to one of them |
   | 0 | `argocd`, `gateway-api`, `metrics-server` | Gateway API CRDs before Traefik uses them; metrics-server before the HPA |
   | 1 | `traefik` | The Gateway that the app routes attach to |
   | 2 | `release-notes-dev`, `release-notes-prod` | Need the Gateway and the metrics in place |

   Argo CD does not check an Application's health by default. The health check in
   `workloads/platform/argocd/values.yaml` makes the waves wait.
5. The `argocd` Application uses the same chart, release name and namespace as the Helm install, so Argo CD adopts
   its own install. From then on an Argo CD change is a commit, not a `helm upgrade`.
6. `bootstrap.sh` waits until root and every Application in `bootstrap/apps/` is Synced and Healthy (up to 15
   minutes), then prints the URLs. A new file in `bootstrap/apps/` is picked up with no script change.

After the bootstrap, every change is a commit: self-heal reverts a hand edit in the cluster, and prune removes an
Application whose file is deleted. The database password never goes in Git: the release-notes chart creates Secret
`release-notes-db` in the cluster with a random password, only if it is missing (release-notes ADR-0011).

Request path:

```
http://prod.localhost ─► host :80 ─► kind node :30080 ─► Traefik ─► Gateway "web"
  ─► HTTPRoute (host prod.localhost) ─► Service ─► one of the prod pods
```

## release-notes

The [release-notes](https://github.com/asaf-refaeli/release-notes) app runs in **two environments**, dev and prod,
**without duplicating manifests**: one Helm chart, published by the app's CI to `ghcr.io/asaf-refaeli/charts`, and
two Application files (`bootstrap/apps/release-notes-dev.yaml`, `release-notes-prod.yaml`) that differ only in name,
namespace and values file.

- **Separate settings** live only in `workloads/apps/release-notes/values-dev.yaml` and `values-prod.yaml`. Each
  Application reads the chart from GHCR (pinned by version) and its values file from this repo (`ref: values`).
- **Same build** in both: the values files pin the same image tag and digest, and CI updates both in one commit.
- **Configuration** comes from the values files; the chart's schema rejects unknown keys.
- **Secrets** are never in Git: the chart creates the database password Secret in the cluster on first sync.
- **Probes and resource limits** come from the chart; **scaling** differs per environment (table below).
- **Single command** from a clean machine: `./scripts/up.sh`.
- **One-command way back**: `./scripts/rollback.sh` reverts the last deploy commit through a PR
  ([proof](https://github.com/asaf-refaeli/release-notes/blob/main/docs/verification.md)).
- Project `release-notes` allows only the two namespaces, both on the Pod Security `restricted` profile. Dev is at
  `http://dev.localhost`, prod at `http://prod.localhost`.

| | dev | prod |
|---|---|---|
| Namespace | `release-notes-dev` | `release-notes-prod` |
| Replicas | 1, no HPA | HPA 2 to 4 on CPU |
| PodDisruptionBudget | off | `maxUnavailable: 1` |
| Log level | DEBUG | INFO |
| Postgres volume | 1Gi | 2Gi |
| Hostname | `dev.localhost` | `prod.localhost` |

Each namespace stands in for a separate cluster. In production only the Application's `destination.server` would
change.

```bash
kubectl --context kind-release-notes -n argocd get applications release-notes-dev release-notes-prod   # Synced / Healthy
kubectl --context kind-release-notes -n release-notes-prod get pods,svc,httproute
curl http://prod.localhost/api/version
```

## How a change ships

| Change | Where | What happens |
|---|---|---|
| New app version | `image.tag` + `image.digest` in `values-dev.yaml` / `values-prod.yaml` | Written by the release-notes CI. Argo CD syncs the new image. |
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
