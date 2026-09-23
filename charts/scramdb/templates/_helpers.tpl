{{/*
Naming, labels, image and the derived cluster values.

Every derivation the chart makes lives here, so a template and the NOTES can
never disagree about what was rendered.
*/}}

{{- define "scramdb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "scramdb.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "scramdb.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{- define "scramdb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Deliberately free of any pool identity: the headless Service
selects every pod of every region pool and the learner tier alike, which is what
makes one flat cluster out of several StatefulSets.
*/}}
{{- define "scramdb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "scramdb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "scramdb.labels" -}}
helm.sh/chart: {{ include "scramdb.chart" . }}
{{ include "scramdb.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: scramdb
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "scramdb.headlessServiceName" -}}
{{- printf "%s-headless" (include "scramdb.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The name peers dial. Fully qualified so a node's advertised address resolves
identically from any namespace.
*/}}
{{- define "scramdb.discoveryDomain" -}}
{{- printf "%s.%s.svc.%s" (include "scramdb.headlessServiceName" .) (include "scramdb.namespace" .) .Values.clusterDomain }}
{{- end }}

{{- define "scramdb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "scramdb.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "scramdb.image" -}}
{{- $registry := default .Values.image.registry .Values.global.imageRegistry -}}
{{- if .Values.image.digest -}}
{{- printf "%s/%s@%s" $registry .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
{{- end }}

{{- define "scramdb.imagePullSecrets" -}}
{{- $secrets := concat .Values.global.imagePullSecrets .Values.image.pullSecrets -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{- define "scramdb.storageClass" -}}
{{- $class := .Values.persistence.storageClass -}}
{{- if not $class -}}
{{- $class = default "" .Values.global.defaultStorageClass -}}
{{- end -}}
{{- if not $class -}}
{{- $class = default "" (get .Values.global "storageClass") -}}
{{- end -}}
{{- $class -}}
{{- end }}

{{/* ---------------------------------------------------------------------- */}}
{{/* Secrets                                                                 */}}
{{/* ---------------------------------------------------------------------- */}}

{{- define "scramdb.authSecretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-auth" (include "scramdb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
The superuser password. Read from the live Secret when one exists, so an upgrade
never rotates a working credential; generated once otherwise. Materialized in
exactly one place (the Secret template): calling this twice would produce two
different random values.
*/}}
{{- define "scramdb.authPassword" -}}
{{- if .Values.auth.password -}}
{{- .Values.auth.password -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" (include "scramdb.namespace" .) (printf "%s-auth" (include "scramdb.fullname" .)) -}}
{{- if and $existing (index $existing.data .Values.auth.secretKeys.passwordKey) -}}
{{- index $existing.data .Values.auth.secretKeys.passwordKey | b64dec -}}
{{- else -}}
{{- randAlphaNum 24 -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "scramdb.createAuthSecret" -}}
{{- if and .Values.auth.enabled (not .Values.auth.existingSecret) (ne .Values.auth.seedMethod "random") -}}true{{- end -}}
{{- end }}

{{- define "scramdb.licenseSecretName" -}}
{{- if .Values.license.existingSecret -}}
{{- .Values.license.existingSecret -}}
{{- else -}}
{{- printf "%s-license" (include "scramdb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "scramdb.createLicenseSecret" -}}
{{- if and .Values.license.key (not .Values.license.existingSecret) -}}true{{- end -}}
{{- end }}

{{/* ---------------------------------------------------------------------- */}}
{{/* Topology derivations                                                    */}}
{{/* ---------------------------------------------------------------------- */}}

{{- define "scramdb.isCluster" -}}
{{- if eq .Values.architecture "cluster" -}}true{{- end -}}
{{- end }}

{{/*
The voter pools, as JSON. One unlabelled pool by default; one per `regions` entry
when that list is set. Standalone is always exactly one pod.
*/}}
{{- define "scramdb.voterPools" -}}
{{- $root := . -}}
{{- $pools := list -}}
{{- if not (include "scramdb.isCluster" .) -}}
  {{- $pools = append $pools (dict "suffix" "" "replicas" 1 "region" "" "zone" "" "nodeSelector" dict "tolerations" list "affinity" dict "resources" dict "resourcesPreset" "" "persistence" dict) -}}
{{- else if .Values.regions -}}
  {{- range .Values.regions -}}
    {{- $pools = append $pools (dict
        "suffix" (required "every entry in `regions` needs a `name`" .name)
        "replicas" (int (default $root.Values.replicaCount .replicas))
        "region" .name
        "zone" (default "" .zone)
        "nodeSelector" (default dict .nodeSelector)
        "tolerations" (default list .tolerations)
        "affinity" (default dict .affinity)
        "resources" (default dict .resources)
        "resourcesPreset" (default "" .resourcesPreset)
        "persistence" (default dict .persistence)) -}}
  {{- end -}}
{{- else -}}
  {{- $pools = append $pools (dict "suffix" "" "replicas" (int .Values.replicaCount) "region" "" "zone" "" "nodeSelector" dict "tolerations" list "affinity" dict "resources" dict "resourcesPreset" "" "persistence" dict) -}}
{{- end -}}
{{- $pools | toJson -}}
{{- end }}

{{/*
Every node name the pods of this release announce (their pod names, which
`node_name = "${NODE_NAME}"` makes them), comma separated: each voter pool's and
the learners'. The one cluster TLS certificate must carry all of them.
*/}}
{{- define "scramdb.clusterTlsNames" -}}
{{- $fullname := include "scramdb.fullname" . -}}
{{- $names := list -}}
{{- range (include "scramdb.voterPools" . | fromJsonArray) -}}
{{- $set := $fullname -}}
{{- if .suffix -}}
{{- $set = printf "%s-%s" $fullname .suffix | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- range $i := until (int .replicas) -}}
{{- $names = append $names (printf "%s-%d" $set $i) -}}
{{- end -}}
{{- end -}}
{{- if and (include "scramdb.isCluster" .) .Values.learners.enabled -}}
{{- $set := printf "%s-learner" $fullname | trunc 63 | trimSuffix "-" -}}
{{- range $i := until (int .Values.learners.replicas) -}}
{{- $names = append $names (printf "%s-%d" $set $i) -}}
{{- end -}}
{{- end -}}
{{- join "," $names -}}
{{- end }}

{{/* Total voting nodes across every pool. Learners never count. */}}
{{- define "scramdb.voterCount" -}}
{{- $total := 0 -}}
{{- range (include "scramdb.voterPools" . | fromJsonArray) -}}
{{- $total = add $total .replicas -}}
{{- end -}}
{{- $total -}}
{{- end }}

{{/*
How many OTHER voters a node waits for before founding the cluster. Derived from
the real replica sum, so it cannot drift from the topology the way a hand written
number does.
*/}}
{{- define "scramdb.bootstrapExpect" -}}
{{- if ne (toString .Values.cluster.bootstrapExpect) "<nil>" -}}
{{- .Values.cluster.bootstrapExpect -}}
{{- else -}}
{{- sub (int (include "scramdb.voterCount" .)) 1 -}}
{{- end -}}
{{- end }}

{{/*
Hybrid nodes. At three voters or fewer every node mirrors its own committed
entries, because there is no smaller topology to dedicate an analytics tier out
of; above that a learner tier buys real resource isolation instead.
*/}}
{{- define "scramdb.columnarReplica" -}}
{{- if ne (toString .Values.cluster.columnarReplica) "<nil>" -}}
{{- .Values.cluster.columnarReplica -}}
{{- else if le (int (include "scramdb.voterCount" .)) 3 -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/* ---------------------------------------------------------------------- */}}
{{/* Resource presets                                                        */}}
{{/* ---------------------------------------------------------------------- */}}

{{/*
`medium` is the reference production shape: 16 vCPU and 32 GiB, the c6a.4xlarge
the engine's published benchmarks run on. Requests equal to limits give
Guaranteed QoS, which is what lets a kubelet on the `static` CPU manager policy
pin exclusive cores per node.
*/}}
{{- define "scramdb.resourcesPreset" -}}
{{- $presets := dict
  "dev"    (dict "requests" (dict "cpu" "1"  "memory" "2Gi")  "limits" (dict "cpu" "1"  "memory" "2Gi"))
  "small"  (dict "requests" (dict "cpu" "4"  "memory" "8Gi")  "limits" (dict "cpu" "4"  "memory" "8Gi"))
  "medium" (dict "requests" (dict "cpu" "16" "memory" "32Gi") "limits" (dict "cpu" "16" "memory" "32Gi"))
  "large"  (dict "requests" (dict "cpu" "32" "memory" "64Gi") "limits" (dict "cpu" "32" "memory" "64Gi"))
  "xlarge" (dict "requests" (dict "cpu" "64" "memory" "128Gi") "limits" (dict "cpu" "64" "memory" "128Gi"))
  "none"   dict
-}}
{{- $name := .name -}}
{{- if not (hasKey $presets $name) -}}
{{- fail (printf "resourcesPreset %q is not one of dev, small, medium, large, xlarge, none" $name) -}}
{{- end -}}
{{- get $presets $name | toYaml -}}
{{- end }}

{{/* Explicit `resources` wins over any preset. Context: dict with `root` and `pool`. */}}
{{- define "scramdb.resources" -}}
{{- $pool := .pool -}}
{{- $root := .root -}}
{{- if $pool.resources -}}
{{- toYaml $pool.resources -}}
{{- else if $root.Values.resources -}}
{{- toYaml $root.Values.resources -}}
{{- else -}}
{{- include "scramdb.resourcesPreset" (dict "name" (default $root.Values.resourcesPreset $pool.resourcesPreset)) -}}
{{- end -}}
{{- end }}

{{/* Renders a value that may itself contain template syntax. */}}
{{- define "scramdb.tplvalues" -}}
{{- if typeIs "string" .value -}}
{{- tpl .value .context -}}
{{- else -}}
{{- tpl (.value | toYaml) .context -}}
{{- end -}}
{{- end }}
