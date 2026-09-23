{{/*
One StatefulSet, for a voter pool or for the learner tier.

Voter pools and learners differ in three things: the name, one config key, and
which values supply their scheduling and sizing. Everything else, the container,
the probes, the volumes, the shutdown budget, comes from here, so the two shapes
cannot drift apart.

Context: dict with `root`, `pool` and `learner`.
*/}}
{{- define "scramdb.statefulset" -}}
{{- $ := .root -}}
{{- $pool := .pool -}}
{{- $learner := .learner -}}
{{- $component := ternary "learner" "voter" $learner -}}
{{- $poolName := default "default" $pool.suffix -}}
{{- $name := include "scramdb.fullname" $ -}}
{{- if $pool.suffix -}}
{{- $name = printf "%s-%s" $name $pool.suffix | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- $persistence := merge (deepCopy (default dict $pool.persistence)) (deepCopy $.Values.persistence) -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $name }}
  namespace: {{ include "scramdb.namespace" $ }}
  labels:
    {{- include "scramdb.labels" $ | nindent 4 }}
    app.kubernetes.io/component: {{ $component }}
    scramdb.com/pool: {{ $poolName }}
  {{- with $.Values.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  serviceName: {{ include "scramdb.headlessServiceName" $ }}
  replicas: {{ $pool.replicas }}
  # Parallel, because a node cannot become Ready until its peers exist: serial
  # startup would wait forever on the first pod of a fresh cluster.
  podManagementPolicy: {{ $.Values.podManagementPolicy }}
  updateStrategy:
    {{- toYaml $.Values.updateStrategy | nindent 4 }}
  selector:
    matchLabels:
      {{- include "scramdb.selectorLabels" $ | nindent 6 }}
      app.kubernetes.io/component: {{ $component }}
      scramdb.com/pool: {{ $poolName }}
  template:
    metadata:
      labels:
        {{- include "scramdb.labels" $ | nindent 8 }}
        app.kubernetes.io/component: {{ $component }}
        scramdb.com/pool: {{ $poolName }}
        {{- with $.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        {{- if not $.Values.config.existingConfigMap }}
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") $ | sha256sum }}
        {{- end }}
        {{- with $.Values.commonAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        {{- with $.Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      serviceAccountName: {{ include "scramdb.serviceAccountName" $ }}
      automountServiceAccountToken: {{ $.Values.serviceAccount.automountServiceAccountToken }}
      {{- include "scramdb.imagePullSecrets" $ | nindent 6 }}
      {{- if $.Values.podSecurityContext.enabled }}
      securityContext:
        {{- omit $.Values.podSecurityContext "enabled" | toYaml | nindent 8 }}
      {{- end }}
      # A terminating node hands its bucket ownership and its voter seat back
      # before it exits. That drain, the query drain and the JIT quiesce each get
      # their own budget, so this is deliberately generous: a node killed before
      # it finishes stays a configured voter the cluster still counts, and the
      # next scale-down then costs quorum.
      terminationGracePeriodSeconds: {{ $.Values.terminationGracePeriodSeconds }}
      {{- with $.Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- with $.Values.schedulerName }}
      schedulerName: {{ . }}
      {{- end }}
      {{- with $.Values.runtimeClassName }}
      runtimeClassName: {{ . }}
      {{- end }}
      {{- if $.Values.hostNetwork }}
      hostNetwork: true
      {{- end }}
      {{- with $.Values.dnsPolicy }}
      dnsPolicy: {{ . }}
      {{- end }}
      {{- with $.Values.dnsConfig }}
      dnsConfig:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $.Values.hostAliases }}
      hostAliases:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- $nodeSelector := default $.Values.nodeSelector $pool.nodeSelector }}
      {{- with $nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- $tolerations := default $.Values.tolerations $pool.tolerations }}
      {{- with $tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- $affinity := default $.Values.affinity $pool.affinity }}
      {{- if $affinity }}
      affinity:
        {{- toYaml $affinity | nindent 8 }}
      {{- else if $.Values.podAntiAffinityPreset }}
      affinity:
        podAntiAffinity:
          {{- if eq $.Values.podAntiAffinityPreset "hard" }}
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  {{- include "scramdb.selectorLabels" $ | nindent 18 }}
          {{- else }}
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    {{- include "scramdb.selectorLabels" $ | nindent 20 }}
          {{- end }}
      {{- end }}
      {{- with $.Values.topologySpreadConstraints }}
      topologySpreadConstraints:
        {{- range . }}
        # A constraint without its own labelSelector gets this pool's, so the
        # spread is computed over the nodes it actually governs.
        - {{ toYaml . | nindent 10 | trim }}
          {{- if not (hasKey . "labelSelector") }}
          labelSelector:
            matchLabels:
              {{- include "scramdb.selectorLabels" $ | nindent 14 }}
              app.kubernetes.io/component: {{ $component }}
          {{- end }}
        {{- end }}
      {{- end }}
      initContainers:
        # Renders the node's config from the ConfigMap template, substituting only
        # this pod's own identity and labels. The serving container then runs the
        # binary directly, with no shell of its own.
        - name: render-config
          image: {{ include "scramdb.image" $ }}
          imagePullPolicy: {{ $.Values.image.pullPolicy }}
          {{- if $.Values.containerSecurityContext.enabled }}
          securityContext:
            {{- omit $.Values.containerSecurityContext "enabled" | toYaml | nindent 12 }}
          {{- end }}
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              envsubst '${NODE_NAME} ${REGION} ${ZONE}' \
                < /etc/scramdb/template/{{ ternary "learner-config.toml" "config.toml" $learner }} \
                > /etc/scramdb/rendered/config.toml
              echo "rendered config for node ${NODE_NAME} region=${REGION:-<unset>} zone=${ZONE:-<unset>}"
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: REGION
              value: {{ default "" $pool.region | quote }}
            - name: ZONE
              value: {{ default "" $pool.zone | quote }}
          volumeMounts:
            - name: config-template
              mountPath: /etc/scramdb/template
              readOnly: true
            - name: config-rendered
              mountPath: /etc/scramdb/rendered
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
        {{- with $.Values.initContainers }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      containers:
        - name: scramdb
          image: {{ include "scramdb.image" $ }}
          imagePullPolicy: {{ $.Values.image.pullPolicy }}
          {{- if $.Values.containerSecurityContext.enabled }}
          securityContext:
            {{- omit $.Values.containerSecurityContext "enabled" | toYaml | nindent 12 }}
          {{- end }}
          {{- if $.Values.diagnosticMode.enabled }}
          command: {{ toYaml $.Values.diagnosticMode.command | nindent 12 }}
          args: {{ toYaml $.Values.diagnosticMode.args | nindent 12 }}
          {{- else }}
          command:
            {{- if $.Values.command }}
            {{- toYaml $.Values.command | nindent 12 }}
            {{- else }}
            - scramdb
            {{- end }}
          args:
            {{- if $.Values.args }}
            {{- toYaml $.Values.args | nindent 12 }}
            {{- else }}
            - -c
            - /etc/scramdb/rendered/config.toml
            {{- end }}
          {{- end }}
          env:
            {{- include "scramdb.containerEnv" (dict "root" $ "pool" $pool) | nindent 12 }}
          {{- if $.Values.extraEnvVarsCM }}
          envFrom:
            - configMapRef:
                name: {{ $.Values.extraEnvVarsCM }}
            {{- if $.Values.extraEnvVarsSecret }}
            - secretRef:
                name: {{ $.Values.extraEnvVarsSecret }}
            {{- end }}
          {{- else if $.Values.extraEnvVarsSecret }}
          envFrom:
            - secretRef:
                name: {{ $.Values.extraEnvVarsSecret }}
          {{- end }}
          ports:
            - name: pgwire
              containerPort: 5432
              protocol: TCP
            {{- if include "scramdb.isCluster" $ }}
            - name: cluster
              containerPort: 7190
              protocol: TCP
            - name: interactive
              containerPort: 7191
              protocol: TCP
            - name: bulk
              containerPort: 7192
              protocol: TCP
            {{- end }}
            {{- if $.Values.metrics.enabled }}
            - name: metrics
              containerPort: {{ $.Values.metrics.containerPort }}
              protocol: TCP
            {{- end }}
            {{- if $.Values.mcp.enabled }}
            - name: mcp
              containerPort: {{ $.Values.mcp.containerPort }}
              protocol: TCP
            {{- end }}
          {{- if not $.Values.diagnosticMode.enabled }}
          {{- include "scramdb.probes" $ | nindent 10 }}
          {{- end }}
          {{- if $.Values.lifecycleHooks }}
          lifecycle:
            {{- toYaml $.Values.lifecycleHooks | nindent 12 }}
          {{- else if $.Values.preStopSleepSeconds }}
          lifecycle:
            preStop:
              exec:
                # Buys the listeners a moment to close. The membership hand-back
                # runs afterward, in the shutdown sequence proper, not here.
                command: ["/bin/sh", "-c", "sleep {{ $.Values.preStopSleepSeconds }}"]
          {{- end }}
          resources:
            {{- include "scramdb.resources" (dict "root" $ "pool" $pool) | nindent 12 }}
          volumeMounts:
            {{- include "scramdb.volumeMounts" $ | nindent 12 }}
        {{- with $.Values.sidecars }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      volumes:
        {{- include "scramdb.volumes" $ | nindent 8 }}
  {{- if and $persistence.enabled (not $persistence.existingClaim) }}
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          {{- include "scramdb.selectorLabels" $ | nindent 10 }}
          {{- with $persistence.labels }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
        {{- with $persistence.annotations }}
        annotations:
          {{- toYaml . | nindent 10 }}
        {{- end }}
      spec:
        accessModes:
          {{- toYaml $persistence.accessModes | nindent 10 }}
        resources:
          requests:
            storage: {{ $persistence.size | quote }}
        {{- $class := include "scramdb.storageClass" $ }}
        {{- if $class }}
        storageClassName: {{ $class | quote }}
        {{- end }}
        {{- with $persistence.selector }}
        selector:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with $persistence.dataSource }}
        dataSource:
          {{- toYaml . | nindent 10 }}
        {{- end }}
  {{- end }}
{{- end }}
