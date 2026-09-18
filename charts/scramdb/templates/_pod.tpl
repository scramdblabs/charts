{{/*
Container environment, probes and volumes. Shared by every pool.
*/}}

{{- define "scramdb.containerEnv" -}}
{{- $ := .root -}}
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
# Set explicitly because a runAsUser override detaches the process from the
# image user's passwd entry, which is where HOME would otherwise come from.
- name: HOME
  value: /home/scramdb
- name: SCRAMDB_LOG
  value: {{ $.Values.logLevel | quote }}
{{- with $.Values.logFormat }}
- name: SCRAMDB_LOG_FORMAT
  value: {{ . | quote }}
{{- end }}
{{- with $.Values.maxCores }}
- name: SCRAMDB_MAX_CORES
  value: {{ . | quote }}
{{- end }}
{{- if include "scramdb.isCluster" $ }}
# Cluster mode is Enterprise gated: a node whose license resolves to Community
# refuses to start. A missing Secret holds the pod at CreateContainerConfigError
# with an event naming it, which is loud and fixable, never a silent crash-loop.
- name: SCRAMDB_LICENSE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "scramdb.licenseSecretName" $ }}
      key: {{ $.Values.license.secretKeys.licenseKey }}
{{- end }}
{{- if $.Values.auth.enabled }}
{{- if eq $.Values.auth.seedMethod "file" }}
# Read once at first boot, and never present in the pod spec or
# /proc/<pid>/environ the way a literal value would be. Exactly one of the three
# seeding variables may be set; the engine refuses to start on more than one.
- name: SCRAMDB_INITIAL_PASSWORD_FILE
  value: /etc/scramdb/auth/{{ $.Values.auth.secretKeys.passwordKey }}
{{- else if eq $.Values.auth.seedMethod "env" }}
- name: SCRAMDB_INITIAL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "scramdb.authSecretName" $ }}
      key: {{ $.Values.auth.secretKeys.passwordKey }}
{{- else }}
- name: SCRAMDB_RANDOM_INITIAL_PASSWORD
  value: "yes"
{{- end }}
{{- end }}
{{- if $.Values.mcp.enabled }}
- name: MCP_AUTH
  value: {{ $.Values.mcp.auth | quote }}
- name: MCP_PORT
  value: {{ $.Values.mcp.containerPort | quote }}
{{- end }}
{{- with $.Values.extraEnvVars }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Probes.

pg_isready is the honest readiness signal: it proves this node accepts client
connections, which in cluster mode only happens after the cluster has formed.
The startup probe exists for exactly that reason, since a fresh cluster can spend
group0_bootstrap_timeout waiting for its peers before any listener binds.
*/}}
{{- define "scramdb.probeCommand" -}}
["pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", {{ .Values.auth.username | quote }}, "-d", {{ .Values.auth.database | quote }}]
{{- end }}

{{- define "scramdb.probes" -}}
{{- if .Values.customStartupProbe }}
startupProbe:
  {{- toYaml .Values.customStartupProbe | nindent 2 }}
{{- else if .Values.startupProbe.enabled }}
startupProbe:
  exec:
    command: {{ include "scramdb.probeCommand" . }}
  {{- omit .Values.startupProbe "enabled" | toYaml | nindent 2 }}
{{- end }}
{{- if .Values.customReadinessProbe }}
readinessProbe:
  {{- toYaml .Values.customReadinessProbe | nindent 2 }}
{{- else if .Values.readinessProbe.enabled }}
readinessProbe:
  exec:
    command: {{ include "scramdb.probeCommand" . }}
  {{- omit .Values.readinessProbe "enabled" | toYaml | nindent 2 }}
{{- end }}
{{- if .Values.customLivenessProbe }}
livenessProbe:
  {{- toYaml .Values.customLivenessProbe | nindent 2 }}
{{- else if .Values.livenessProbe.enabled }}
livenessProbe:
  exec:
    command: {{ include "scramdb.probeCommand" . }}
  {{- omit .Values.livenessProbe "enabled" | toYaml | nindent 2 }}
{{- end }}
{{- end }}

{{- define "scramdb.volumes" -}}
- name: config-template
  configMap:
    name: {{ default (include "scramdb.fullname" .) .Values.config.existingConfigMap }}
- name: config-rendered
  emptyDir: {}
# Scratch for anything outside the data volume. Everything the engine itself
# writes (data, WAL, spill, compiled-artifact cache, UDF cache) lives under
# storage.basedir; these two cover a lazily fetched UDF runtime extra, and are
# what lets the root filesystem stay read-only.
- name: tmp
  emptyDir: {}
- name: home
  emptyDir: {}
{{- if and .Values.auth.enabled (eq .Values.auth.seedMethod "file") }}
- name: auth
  secret:
    secretName: {{ include "scramdb.authSecretName" . }}
    defaultMode: 0400
    items:
      - key: {{ .Values.auth.secretKeys.passwordKey }}
        path: {{ .Values.auth.secretKeys.passwordKey }}
{{- end }}
{{- if or .Values.hba.rules .Values.hba.existingConfigMap }}
- name: hba
  configMap:
    name: {{ default (include "scramdb.fullname" .) .Values.hba.existingConfigMap }}
    items:
      - key: pg_hba.conf
        path: pg_hba.conf
{{- end }}
{{- if .Values.tls.enabled }}
- name: tls
  secret:
    secretName: {{ .Values.tls.existingSecret }}
    defaultMode: 0400
{{- end }}
{{- if .Values.cluster.tls.enabled }}
- name: cluster-tls
  secret:
    secretName: {{ .Values.cluster.tls.existingSecret }}
    defaultMode: 0400
{{- end }}
{{- if not .Values.persistence.enabled }}
- name: data
  emptyDir: {}
{{- else if .Values.persistence.existingClaim }}
- name: data
  persistentVolumeClaim:
    claimName: {{ .Values.persistence.existingClaim }}
{{- end }}
{{- with .Values.extraVolumes }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{- define "scramdb.volumeMounts" -}}
- name: config-rendered
  mountPath: /etc/scramdb/rendered
  readOnly: true
- name: data
  mountPath: {{ .Values.persistence.mountPath }}
- name: tmp
  mountPath: /tmp
- name: home
  mountPath: /home/scramdb
{{- if and .Values.auth.enabled (eq .Values.auth.seedMethod "file") }}
- name: auth
  mountPath: /etc/scramdb/auth
  readOnly: true
{{- end }}
{{- if or .Values.hba.rules .Values.hba.existingConfigMap }}
- name: hba
  mountPath: /etc/scramdb/hba
  readOnly: true
{{- end }}
{{- if .Values.tls.enabled }}
- name: tls
  mountPath: /etc/scramdb/tls
  readOnly: true
{{- end }}
{{- if .Values.cluster.tls.enabled }}
- name: cluster-tls
  mountPath: /etc/scramdb/cluster-tls
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{- toYaml . }}
{{- end }}
{{- end }}
