# ScramDB

[ScramDB](https://scramdb.com) is a programmable distributed hyperscale UTAP SQL
database: transactions, analytics and AI run on one live copy of your data,
behind the PostgreSQL wire protocol.

This chart runs it two ways from one values file. `architecture: standalone` is a
single Community node with no license gate. `architecture: cluster` is a
serializable multi-node database, which is an Enterprise capability.

```bash
helm repo add scramdb https://charts.scramdb.com
helm repo update
helm install scramdb scramdb/scramdb
```

## A cluster

Cluster nodes need no seed list. Every pod waits for the same number of peers and
discovers them through the headless Service's DNS plus SWIM gossip, so the only
thing that has to match the replica count is derived by the chart, not typed by
you.

```bash
kubectl create secret generic scramdb-license \
  --from-literal=license-key="<your Enterprise or Trial token>"

helm install scramdb scramdb/scramdb \
  --set architecture=cluster \
  --set replicaCount=3 \
  --set license.existingSecret=scramdb-license \
  --set resourcesPreset=medium \
  --set persistence.size=500Gi \
  --set walArchive.destination=s3://your-bucket/scramdb-wal
```

Without a valid key a node with a `[cluster]` section refuses to start, so the
chart refuses to render that combination rather than shipping a crash loop.

## Connect

Every node is an equal peer serving the same consistent database, so any pod is a
correct endpoint and the Service load balances across all of them.

```bash
kubectl get secret scramdb-auth -o jsonpath="{.data.password}" | base64 -d

kubectl port-forward svc/scramdb 5432:5432
psql "host=127.0.0.1 port=5432 user=scramdb dbname=scramdb"
```

## Sizing

`resourcesPreset` picks a shape; `resources` overrides it outright.

| Preset | CPU | Memory |
|-|-|-|
| `dev` (default) | 1 | 2Gi |
| `small` | 4 | 8Gi |
| `medium` | 16 | 32Gi |
| `large` | 32 | 64Gi |
| `xlarge` | 64 | 128Gi |
| `none` | unset | unset |

`medium` is the reference production shape: 16 vCPU and 32 GiB, matching the
c6a.4xlarge instance the engine's published benchmarks are measured on. Requests
equal to limits give the pod Guaranteed QoS, which is what lets a kubelet running
the `static` CPU manager policy pin exclusive cores. Under the default CPU manager
policy the engine still resolves the right worker count from the CFS quota.

Memory needs no chart-side arithmetic: `buffer_pool_percent` and
`execution_memory_percent` are left at 0, which means the engine sizes both from
the container's own cgroup limit.

## Multi-region

One StatefulSet per region entry, all sharing one headless Service, forming one
flat cluster. A table created through a node labelled `eu` keeps its replicas in
`eu` and commits at region-local quorum latency.

```yaml
architecture: cluster
regions:
  - name: eu
    zone: eu-central-1a
    replicas: 3
    nodeSelector:
      topology.kubernetes.io/region: eu-central-1
  - name: us
    zone: us-east-1a
    replicas: 3
    nodeSelector:
      topology.kubernetes.io/region: us-east-1
```

`ALTER TABLE t SET (home_region = 'us')` re-homes a table live.

## Learners

A learner is a permanently non-voting member: it hosts replicated data for local
analytical reads, owns no write-serving buckets and never joins the quorum. The
honest recommendation scales with node count. At three nodes leave
`cluster.columnarReplica` on its derived `true`, so every voter answers analytics
locally with no hop. At five or more, the chart derives it to `false` and a
learner tier is the better answer, because a dedicated node buys real resource
isolation where a hybrid node shares one machine between both workloads.

```yaml
learners:
  enabled: true
  replicas: 2
```

## Scaling

Adding a node needs no configuration change: a new pod finds the formed cluster
through DNS and joins as a non-voting member, promoted once it has caught up.

```bash
helm upgrade scramdb scramdb/scramdb --reuse-values --set replicaCount=5
```

Removing one is safe too. A terminating pod hands its bucket ownership and its
voter seat back before it exits, which is why `terminationGracePeriodSeconds`
defaults to 120: the membership drain, the query drain and the JIT quiesce each
get their own budget, and a pod killed before it finishes stays a configured voter
the cluster still counts. To drain a node explicitly first:

```sql
ALTER CLUSTER DRAIN 'scramdb-2';
```

Changing the replica count re-derives `bootstrap_expect`, so the pods roll once.
That is real reconfiguration work rather than a no-op, and it is the price of a
value that cannot go stale.

## Security

| Value | Default | What it does |
|-|-|-|
| `auth.enabled` | `true` | Seeds the bootstrap superuser's password at first boot and turns SCRAM authentication on. `false` runs the node with `--pg-no-auth`, which trusts every connection. |
| `auth.seedMethod` | `file` | `file` mounts the Secret and the value never enters the pod spec. `env` is the literal value, visible in `kubectl describe pod`. `random` lets the engine generate one and log it once. |
| `mcp.auth` | `basic` | The MCP tool surface maps HTTP Basic credentials to a real database role. `env` leaves it unauthenticated, and the chart then refuses to publish it through a LoadBalancer or NodePort. |
| `tls.enabled` | `false` | Server-side TLS on pgwire, from `tls.existingSecret`. A missing or mismatched certificate fails startup rather than falling back to plaintext. |
| `cluster.tls.enabled` | `false` | Mutual TLS between nodes on the cluster transport, from `cluster.tls.existingSecret`. The one shared certificate must carry every node name (the pod names) and the pods' stable DNS names (`*.<headless service>.<namespace>.svc.<clusterDomain>`), never their IPs; the install notes print the exact list and the command that makes it. |
| `hba.rules` | `""` | A `pg_hba.conf` style rule file. Empty uses the built-in default: trust from localhost, password everywhere else. |
| `networkPolicy.enabled` | `false` | The cluster transport is always restricted to this chart's own pods; the client and MCP ports follow `allowExternal`. |

The seeded password applies only while the superuser has no credential, so
redeploying a pod or rotating the Secret can never reset a password you set with
`ALTER ROLE`, and never locks anyone out.

The container security context satisfies the restricted Pod Security Standard.
Its `runAsUser`/`runAsGroup` of 1001 must match the image's own user: an image
built before the UID was pinned declares that user by name, which a kubelet cannot
verify, so set `containerSecurityContext.runAsNonRoot=false` and clear the two IDs
when running one of those.

## Ports

Every port a node opens is published on the headless Service, and `service.*`
decides which of them the client Service carries.

| Port | Name | What listens |
|-|-|-|
| 5432 | pgwire | The PostgreSQL wire protocol. |
| 7190 | cluster | The cluster transport's control traffic, in cluster mode only. |
| 7191 | interactive | The cluster transport's interactive traffic, in cluster mode only. |
| 7192 | bulk | The cluster transport's bulk traffic, in cluster mode only. |
| 9090 | metrics | `/metrics` and `/health` on one HTTP listener. |
| 9191 | mcp | The Semantic AI MCP server, started in-process by the engine. |

## Observability

`metrics.serviceMonitor.enabled` scrapes every node as its own Prometheus target
through the headless Service. `metrics.prometheusRule.enabled` adds alerts for the
failures that have a counter: a quarantined shard group, WAL archiving falling
behind, peers flapping, an expiring license, execution-memory stalls. An absent
metric on this endpoint means not measured, never zero, so nothing alerts on
absence.

## Persistence

| Value | Default |
|-|-|
| `persistence.size` | `100Gi` |
| `persistence.storageClass` | `""`, the cluster's default class |
| `persistence.accessModes` | `[ReadWriteOnce]` |

NVMe backed classes are strongly recommended: the default I/O backend uses direct
I/O and rewards sequential throughput. Everything the engine writes, including the
WAL, the spill directory, the compiled-artifact cache and the UDF cache, lives
under this one volume.

Set `walArchive.destination` to storage every node can reach. Only the current
leader ships WAL segments and a new leader resumes from the destination's own
listing, so a node-local archive leaves no node holding a complete point-in-time
history after a failover. The chart warns about this at install time rather than
silently shipping a broken recovery story.

The archive removes segments older than `walArchive.retention` (default `168h`, seven
days) once they also lie before the latest base backup; set a longer duration to keep
more point-in-time history.

## Full values

Every value is documented inline in [values.yaml](values.yaml), and
[values.schema.json](values.schema.json) rejects an invalid combination before the
release is created.

## Documentation

- [Kubernetes deployment](https://scramdb.com/docs/deployment/kubernetes)
- [Distributed cluster](https://scramdb.com/docs/deployment/clustering)
- [Observability](https://scramdb.com/docs/tuning/observability)
