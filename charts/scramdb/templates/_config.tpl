{{/*
The rendered scramdb config.

One function builds both the voter and the learner config, so the two can never
disagree about anything except the one field that distinguishes them. The three
${...} tokens are substituted per pod by the render initContainer; nothing else in
this file is a shell variable.

Every key emitted here is a real field of ScramDbConfig, TundraConfig or
ClusterConfig. Keys the chart does not model are left out entirely, which is
byte-identical to writing them at their defaults, and `config.extraToml` is the
seam for adding them.

Context: dict with `root` (the chart context) and `learner` (bool).
*/}}
{{- define "scramdb.configToml" -}}
{{- $ := .root -}}
{{- $learner := .learner -}}
[general]
jit_enabled = {{ $.Values.config.jitEnabled }}
metrics_port = {{ if $.Values.metrics.enabled }}{{ $.Values.metrics.containerPort }}{{ else }}0{{ end }}
# Bind every interface: a Service cannot reach a loopback listener, and the
# container boundary is the exposure control. Config wins over the CLI default.
pg_address = "0.0.0.0:5432"
{{- if not $.Values.auth.enabled }}
# auth.enabled=false: every connection is trusted with no password check.
pg_no_auth = true
{{- end }}
{{- if or $.Values.hba.rules $.Values.hba.existingConfigMap }}
hba_file = "/etc/scramdb/hba/pg_hba.conf"
{{- end }}
{{- if $.Values.tls.enabled }}
tls_cert = "/etc/scramdb/tls/{{ $.Values.tls.certFilename }}"
tls_key = "/etc/scramdb/tls/{{ $.Values.tls.keyFilename }}"
{{- end }}

[gpu]
# Runtime dlopen with a graceful CPU-only fallback, so this is safe to leave on
# whether or not the node has a device.
enabled = {{ $.Values.config.gpuEnabled }}

[storage]
prod_name = "tundra"
shard_id = 0
basedir = {{ $.Values.persistence.mountPath | quote }}
# 0 means automatic: sized from the container's cgroup memory limit, falling back
# to host RAM, so the same numbers are correct at 2Gi and at 512Gi.
buffer_pool_percent = {{ $.Values.config.bufferPoolPercent }}
buffer_pool_cap = {{ $.Values.config.bufferPoolCap | quote }}
execution_memory_percent = {{ $.Values.config.executionMemoryPercent }}
execution_memory_cap = {{ $.Values.config.executionMemoryCap | quote }}

[storage.wal.archive]
enabled = {{ $.Values.walArchive.enabled }}
{{- if $.Values.walArchive.destination }}
destination = {{ $.Values.walArchive.destination | quote }}
{{- else if $.Values.walArchive.enabled }}
# No walArchive.destination set, so this derives to a node-local path. In a
# cluster each group's log is shipped by whichever node leads the group, so a
# local path scatters each group's history over the nodes that led it and no
# node holds a restorable history. Set an s3://, gs://, az:// or shared file://
# destination before relying on PITR.
{{- end }}
poll_interval = {{ $.Values.walArchive.pollInterval | quote }}
retention = {{ $.Values.walArchive.retention | quote }}
{{- if include "scramdb.isCluster" $ }}

[cluster]
node_name = "${NODE_NAME}"
cluster_listen = "0.0.0.0:7190"
# Interactive and bulk traffic between nodes on their own ports (peers learn them
# from the control connection on 7190).
cluster_interactive_listen = "0.0.0.0:7191"
cluster_bulk_listen = "0.0.0.0:7192"
# Every pod of every pool answers to <pod>.<headless service>, so one template
# line is correct for all of them.
advertise_addr = "${NODE_NAME}.{{ include "scramdb.discoveryDomain" $ }}:7190"
# Empty is unset by design: the engine trims and drops a blank label, so an
# unlabelled deployment never ends up in a region literally named "".
region = "${REGION}"
zone = "${ZONE}"
{{- if $.Values.cluster.seeds }}
seeds = [{{ range $i, $s := $.Values.cluster.seeds }}{{ if $i }}, {{ end }}{{ $s | quote }}{{ end }}]
{{- end }}
# Seedless formation: every node waits for the same number of OTHER voters and
# derives the identical genesis set, so there is no seed list to keep in step
# with the replica count. Derived from the pool replica sum by the chart.
bootstrap_expect = {{ include "scramdb.bootstrapExpect" $ }}
discovery = [{{ range $i, $p := $.Values.cluster.discovery }}{{ if $i }}, {{ end }}{{ $p | quote }}{{ end }}]
dns_name = {{ include "scramdb.discoveryDomain" $ | quote }}
dns_refresh = {{ $.Values.cluster.dnsRefresh | quote }}
replication_factor = {{ $.Values.cluster.replicationFactor }}
group0_bootstrap_timeout = {{ $.Values.cluster.group0BootstrapTimeout | quote }}
fragment_any_replica = {{ $.Values.cluster.fragmentAnyReplica }}
{{- if $learner }}
# A learner hosts replicated data for local reads, owns no buckets and is never
# promoted to a voter.
learner = true
{{- else }}
columnar_replica = {{ include "scramdb.columnarReplica" $ }}
{{- end }}
{{- if $.Values.cluster.tls.enabled }}
tls_cert = "/etc/scramdb/cluster-tls/{{ $.Values.cluster.tls.certFilename }}"
tls_key = "/etc/scramdb/cluster-tls/{{ $.Values.cluster.tls.keyFilename }}"
tls_ca = "/etc/scramdb/cluster-tls/{{ $.Values.cluster.tls.caFilename }}"
{{- end }}
# Consensus ([cluster.consensus], its thread count included), log compaction
# ([cluster.log_compaction]), applying committed writes ([cluster.apply]), the
# commit protocol ([cluster.dilith]), how long a COMMIT waits for it
# ([cluster.transactions]), cluster vector settings ([cluster.vector]), joins
# across nodes ([cluster.distributed_join]) and the row exchange between nodes
# ([cluster.exchange]) run at their defaults unless cluster.extraToml sets them.
{{- with $.Values.cluster.extraToml }}
{{ tpl . $ }}
{{- end }}
{{- end }}
{{- with $.Values.config.extraToml }}

{{ tpl . $ }}
{{- end }}
{{- end }}
