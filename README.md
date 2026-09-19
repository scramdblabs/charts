# ScramDB Helm Charts

Official Helm charts for [ScramDB](https://scramdb.com), the programmable
distributed hyperscale UTAP SQL database.

```bash
helm repo add scramdb https://charts.scramdb.com
helm repo update
helm install scramdb scramdb/scramdb
```

That gives you one Community node, no license needed. A cluster is one flag and a
license:

```bash
helm install scramdb scramdb/scramdb \
  --set architecture=cluster \
  --set replicaCount=3 \
  --set license.key="$SCRAMDB_LICENSE_KEY"
```

Charts are also published as OCI artifacts:

```bash
helm install scramdb oci://registry-1.docker.io/scramdb/scramdb --version 1.0.0
```

## Deploying the Community edition

Community is the full engine on one node: the same storage, the same JIT compiled
execution, the same MVCC transactions and the same PostgreSQL wire protocol a
cluster node runs. There is no licence gate on it and no separate build. What it
does not do is span machines; multi-node clustering is the Enterprise capability.

Install it, wait for it, and connect:

```bash
helm repo add scramdb https://charts.scramdb.com
helm repo update

helm install scramdb scramdb/scramdb --namespace scramdb --create-namespace --wait
```

The chart turns authentication on and seeds the bootstrap superuser's password at
first boot, so read it back before connecting:

```bash
kubectl get secret --namespace scramdb scramdb-auth \
  -o jsonpath="{.data.password}" | base64 -d
```

```bash
kubectl port-forward --namespace scramdb svc/scramdb 5432:5432
psql "host=127.0.0.1 port=5432 user=scramdb dbname=scramdb"
```

Any PostgreSQL client works: the same URL shape serves an application inside the
cluster.

```
postgresql://scramdb@scramdb.scramdb.svc.cluster.local:5432/scramdb
```

### Size it before you load anything

The default is `resourcesPreset: dev`, which is 1 CPU and 2Gi. That is chosen so a
first install schedules on any cluster, not to serve a workload: a single statement
writing a few hundred thousand rows will exhaust its execution memory pool and fail,
loudly and by name, rather than silently degrade.

```bash
helm upgrade scramdb scramdb/scramdb --namespace scramdb --reuse-values \
  --set resourcesPreset=small
```

| Preset | CPU | Memory | For |
|-|-|-|-|
| `dev` | 1 | 2Gi | the default, so a first install always schedules |
| `small` | 4 | 8Gi | development and light workloads |
| `medium` | 16 | 32Gi | the reference production shape |
| `large` | 32 | 64Gi | larger single-node production |

### Choose the volume size at install time

Storage defaults to a 100Gi volume on the cluster's default StorageClass, which is
what lets one values file work on EKS, GKE, AKS and on-prem alike.

Pick the size when you install, because Kubernetes will not let you change it
afterwards. A StatefulSet's volume claim template is immutable, so a later
`--set persistence.size=...` fails the upgrade outright:

```text
Forbidden: updates to statefulset spec for fields other than 'replicas',
'ordinals', 'template', 'updateStrategy', 'revisionHistoryLimit',
'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

```bash
helm install scramdb scramdb/scramdb --namespace scramdb --create-namespace \
  --set persistence.size=500Gi --wait
```

Growing an existing volume is a StorageClass concern rather than a chart one: if
yours sets `allowVolumeExpansion: true`, edit the PersistentVolumeClaim directly.
 NVMe backed
classes are strongly recommended: the default I/O backend uses direct I/O and
rewards sequential throughput. Everything the engine writes, including the WAL and
the spill directory, lives on that one volume, so the data survives a pod being
replaced.

### Going further

```bash
helm test scramdb --namespace scramdb    # proves the database answers and auth is enforced
helm uninstall scramdb --namespace scramdb
```

`helm uninstall` leaves the PersistentVolumeClaim behind on purpose. Delete it
yourself when you actually want the data gone.

It does not leave the Secret behind, and that asymmetry has a sharp edge. The
password lives in two places: the generated Secret, and the database itself, which
is on the retained volume. Reinstalling over that volume generates a *new* Secret
while the database keeps the credential it already had, so the password the chart
hands you no longer opens it. Keep the password, or supply it on the way back in:

```bash
helm install scramdb scramdb/scramdb --namespace scramdb \
  --set auth.existingSecret=my-saved-secret
```

The same rule is what protects you in the other direction: once you set a password
with `ALTER ROLE`, nothing the chart does can reset it. Rotating or deleting the
Secret does not, and neither does redeploying the pod. The seeded password only
ever applies while the superuser has no credential at all.

Note that the built-in host rules trust `127.0.0.1` outright, so a `kubectl exec`
into the pod and a `psql` to localhost never ask for a password. That is a
convenience for administration, not a hole: every connection arriving over the
Service is password checked.

Nothing about a Community deployment has to be undone to grow out of it. The same
release becomes a cluster with a licence and a replica count, and your SQL, drivers
and isolation guarantees do not change:

```bash
helm upgrade scramdb scramdb/scramdb --namespace scramdb --reuse-values \
  --set architecture=cluster \
  --set replicaCount=3 \
  --set license.existingSecret=scramdb-license
```

Every value is documented inline in [values.yaml](charts/scramdb/values.yaml), and
the [chart reference](charts/scramdb/README.md) covers TLS, network policy,
observability and multi-region.

## Charts

| Chart | Description |
|-|-|
| [scramdb](charts/scramdb) | ScramDB, single node or a multi-node cluster. |

## Documentation

- [Kubernetes deployment guide](https://scramdb.com/docs/deployment/kubernetes)
- [Chart reference](charts/scramdb/README.md)
- [ScramDB documentation](https://scramdb.com/docs)

## Development

```bash
make lint       # helm lint plus the chart-testing linter
make test       # helm unittest
make template   # render every values matrix and check the output parses
make all        # everything above
```

`make test` needs the [helm-unittest](https://github.com/helm-unittest/helm-unittest)
plugin:

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest
```

Every pull request runs the same checks. A merge to `main` publishes any chart
whose version changed, to both the Helm repository and the OCI registry.

## License

Apache 2.0. See [LICENSE](LICENSE).
