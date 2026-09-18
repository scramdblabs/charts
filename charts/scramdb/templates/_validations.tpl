{{/*
Value checks that run before anything is rendered.

Every message names the value to change and what to change it to. A combination
that would install and then crash-loop is refused here instead, where the reason
is visible; a combination that merely degrades is warned about in NOTES.txt.
*/}}
{{- define "scramdb.validateValues" -}}
{{- $messages := list -}}
{{- $messages = append $messages (include "scramdb.validateValues.architecture" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.license" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.replicationFactor" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.seeds" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.mcp" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.auth" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.persistence" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.clusterOnly" .) -}}
{{- $messages = append $messages (include "scramdb.validateValues.tls" .) -}}
{{- $messages = without $messages "" -}}
{{- if $messages -}}
{{- printf "\n\nVALUES VALIDATION:\n%s" (join "\n" $messages) | fail -}}
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.architecture" -}}
{{- if not (has .Values.architecture (list "standalone" "cluster")) -}}
architecture: must be "standalone" or "cluster", got {{ .Values.architecture | quote }}.
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.license" -}}
{{- if and (include "scramdb.isCluster" .) (not .Values.license.key) (not .Values.license.existingSecret) -}}
license: multi-node clustering is an Enterprise capability. A node with a [cluster] section and no valid key refuses to start, so this install would crash-loop.
    Set license.key, or license.existingSecret, or install with --set architecture=standalone.
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.replicationFactor" -}}
{{- if include "scramdb.isCluster" . -}}
{{- $voters := int (include "scramdb.voterCount" .) -}}
{{- if gt (int .Values.cluster.replicationFactor) $voters -}}
cluster.replicationFactor: {{ .Values.cluster.replicationFactor }} copies cannot be placed on {{ $voters }} voting node(s). Lower cluster.replicationFactor, or add nodes.
{{- end -}}
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.seeds" -}}
{{- if and (include "scramdb.isCluster" .) .Values.cluster.seeds -}}
{{- $expect := int (include "scramdb.bootstrapExpect" .) -}}
{{- if gt $expect (len .Values.cluster.seeds) -}}
cluster.seeds: bootstrap_expect resolves to {{ $expect }} but only {{ len .Values.cluster.seeds }} seed(s) are listed, which the engine refuses at boot.
    Set cluster.bootstrapExpect to the number of voter seeds, or clear cluster.seeds and let DNS discovery find the peers.
{{- end -}}
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.mcp" -}}
{{- if .Values.mcp.enabled -}}
{{- if not (has .Values.mcp.auth (list "basic" "env")) -}}
mcp.auth: must be "basic" or "env", got {{ .Values.mcp.auth | quote }}.
{{- else if and (eq .Values.mcp.auth "env") .Values.service.exposeMcp (has .Values.service.type (list "LoadBalancer" "NodePort")) -}}
mcp.auth: service.type={{ .Values.service.type }} would publish the MCP tool surface on port {{ .Values.service.ports.mcp }} with no authentication at all.
    Set mcp.auth=basic, or service.exposeMcp=false, or service.type=ClusterIP.
{{- end -}}
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.auth" -}}
{{- if not (has .Values.auth.seedMethod (list "file" "env" "random")) -}}
auth.seedMethod: must be "file", "env" or "random", got {{ .Values.auth.seedMethod | quote }}.
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.persistence" -}}
{{- if and .Values.persistence.enabled .Values.persistence.existingClaim (gt (int (include "scramdb.voterCount" .)) 1) -}}
persistence.existingClaim: one claim cannot back {{ include "scramdb.voterCount" . }} nodes, each of which needs its own durable volume. Clear it and let the StatefulSet template a claim per pod.
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.clusterOnly" -}}
{{- if not (include "scramdb.isCluster" .) -}}
{{- if .Values.regions -}}
regions: multi-region pools are a cluster topology. Set architecture=cluster, or clear regions.
{{- else if .Values.learners.enabled -}}
learners.enabled: a learner is a non-voting member of a cluster. Set architecture=cluster, or disable learners.
{{- end -}}
{{- end -}}
{{- end }}

{{- define "scramdb.validateValues.tls" -}}
{{- if and .Values.tls.enabled (not .Values.tls.existingSecret) -}}
tls.existingSecret: required when tls.enabled. A missing or unreadable certificate fails startup rather than falling back to plaintext.
{{- end -}}
{{- if and .Values.cluster.tls.enabled (not .Values.cluster.tls.existingSecret) -}}
cluster.tls.existingSecret: required when cluster.tls.enabled.
{{- end -}}
{{- end }}
