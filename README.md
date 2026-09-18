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
