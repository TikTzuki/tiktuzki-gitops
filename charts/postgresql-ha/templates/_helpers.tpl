{{/*
Expand the name of the chart.
*/}}
{{- define "pgha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pgha.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pgha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pgha.labels" -}}
helm.sh/chart: {{ include "pgha.chart" . }}
{{ include "pgha.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for the Patroni pods.

`cluster-name` is NOT decoration — it is the label Patroni itself filters on (scope_label in
patroni.yaml) to find its peers. Removing it, or letting it drift from .Values.scope, makes
every node think it is alone and each one bootstraps its own single-node cluster.
*/}}
{{- define "pgha.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
cluster-name: {{ .Values.scope }}
{{- end }}

{{/*
Headless service — gives each Patroni pod a stable DNS record:
  {{ fullname }}-{ordinal}.{{ fullname }}-headless.{namespace}.svc.cluster.local
Patroni advertises this as its connect_address, so replicas keep finding the leader across
pod restarts (a pod IP would not survive one).
*/}}
{{- define "pgha.headlessServiceName" -}}
{{- printf "%s-headless" (include "pgha.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Stable FQDN of one Patroni pod, by ordinal. Used to build pgdog's [[databases]] list and
HAProxy's server lines — both need to address individual nodes, not a load-balanced Service.
*/}}
{{- define "pgha.podFqdn" -}}
{{- printf "%s-%d.%s.%s.svc.cluster.local" (include "pgha.fullname" .ctx) (int .ordinal) (include "pgha.headlessServiceName" .ctx) .ctx.Release.Namespace -}}
{{- end }}

{{/*
Name of the Secret holding every password this chart consumes.
*/}}
{{- define "pgha.secretName" -}}
{{- .Values.auth.existingSecret | required "auth.existingSecret is required — this chart never takes an inline password (see infra/sealed-secrets)" -}}
{{- end }}

{{- define "pgha.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pgha.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
pgdog sub-component naming.
*/}}
{{- define "pgha.pgdog.fullname" -}}
{{- printf "%s-pgdog" (include "pgha.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "pgha.pgdog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgha.name" . }}-pgdog
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "pgha.pgdog.labels" -}}
helm.sh/chart: {{ include "pgha.chart" . }}
{{ include "pgha.pgdog.selectorLabels" . }}
app.kubernetes.io/component: pgdog
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
HAProxy sub-component naming.
*/}}
{{- define "pgha.haproxy.fullname" -}}
{{- printf "%s-haproxy" (include "pgha.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "pgha.haproxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgha.name" . }}-haproxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "pgha.haproxy.labels" -}}
helm.sh/chart: {{ include "pgha.chart" . }}
{{ include "pgha.haproxy.selectorLabels" . }}
app.kubernetes.io/component: haproxy
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
The body of SPILO_CONFIGURATION.

The timescaledb-ha chart ships this as a patroni.yaml ConfigMap, because that image's
entrypoint is literally `patroni <file>`. Spilo's is `/bin/sh /launch.sh init`, which
GENERATES patroni.yaml from the environment and then execs Patroni — so the same content has
to arrive as an env var that launch.sh deep-merges, rather than as a file.

Only the sections Spilo does not already build from its own env are set here. `restapi`,
`scope`, `name` and the connect addresses come from launch.sh and the PATRONI_* vars in
statefulset.yaml; duplicating them here would just create two places to be wrong.
*/}}
{{- define "pgha.spiloConfiguration" -}}
kubernetes:
  # ConfigMaps rather than Endpoints. Endpoints mode needs a selector-less Service whose
  # Endpoints object Patroni owns, and the endpoint controller will fight you for it if the
  # Service ever grows a selector.
  use_endpoints: false
  # Pinned explicitly rather than inherited: the default leader value changed between Patroni
  # majors (master -> primary), and the primary/replica Services select on it. Inheriting it
  # would silently break both Services on an image bump.
  role_label: role
  leader_label_value: master
  follower_label_value: replica
  standby_leader_label_value: master
  # While a pod is starting or is not a valid endpoint, Patroni parks it here instead of
  # `role`, which keeps it out of both Services.
  tmp_role_label: noloadbalance
bootstrap:
  # Leader only, straight after initdb, with the superuser conn string as $1. Replicas are
  # cloned with pg_basebackup, so its effects replicate on their own.
  post_init: /etc/patroni/scripts/post-init.sh
  dcs:
    # Leader-lease TTL dominates failover time. Patroni enforces ttl >= loop_wait + 2*retry_timeout.
    ttl: {{ .Values.patroni.ttl }}
    loop_wait: {{ .Values.patroni.loopWait }}
    retry_timeout: {{ .Values.patroni.retryTimeout }}
    # int64, not the raw value: Helm renders a bare 33554432 as 3.3554432e+07, which Patroni
    # reads as a float and rejects.
    maximum_lag_on_failover: {{ .Values.patroni.maximumLagOnFailover | int64 }}
    {{- if .Values.patroni.synchronousMode }}
    synchronous_mode: true
    synchronous_mode_strict: {{ .Values.patroni.synchronousModeStrict }}
    {{- end }}
    {{- with .Values.patroni.slots }}
    # Declaring a slot here is what stops Patroni DELETING it — it drops any slot it does not
    # recognise, so a slot Debezium created for itself is removed within seconds, recreated,
    # and the pair fight in a loop until the leader lease expires. The key must match the
    # consumer's slot name exactly.
    slots:
      {{- range $name, $cfg := . }}
      {{ $name }}:
        {{- toYaml $cfg | nindent 8 }}
      {{- end }}
    {{- end }}
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        {{- range $k, $v := .Values.patroni.parameters }}
        {{ $k }}: {{ $v | quote }}
        {{- end }}
      pg_hba:
        {{- range .Values.patroni.pgHba }}
        - {{ . | quote }}
        {{- end }}
  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    # Cheap on modern hardware, and the only way corruption is noticed before it replicates.
    - data-checksums
    - auth-host: scram-sha-256
    - auth-local: trust
postgresql:
  # patronictl and the post-init hook connect over the unix socket, which `local all all trust`
  # in pg_hba admits without a password.
  use_unix_socket: true
  pgpass: /tmp/pgpass
  basebackup:
    # Cap the clone's bandwidth so re-seeding a replica does not starve the leader's WAL
    # shipping on a shared node.
    - max-rate: 100M
    - checkpoint: fast
tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
{{- end }}
