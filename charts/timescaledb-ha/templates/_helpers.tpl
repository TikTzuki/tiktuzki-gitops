{{/*
Expand the name of the chart.
*/}}
{{- define "tsha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "tsha.fullname" -}}
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
{{- define "tsha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "tsha.labels" -}}
helm.sh/chart: {{ include "tsha.chart" . }}
{{ include "tsha.selectorLabels" . }}
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
{{- define "tsha.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tsha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
cluster-name: {{ .Values.scope }}
{{- end }}

{{/*
Headless service — gives each Patroni pod a stable DNS record:
  {{ fullname }}-{ordinal}.{{ fullname }}-headless.{namespace}.svc.cluster.local
Patroni advertises this as its connect_address, so replicas keep finding the leader across
pod restarts (a pod IP would not survive one).
*/}}
{{- define "tsha.headlessServiceName" -}}
{{- printf "%s-headless" (include "tsha.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Stable FQDN of one Patroni pod, by ordinal. Used to build pgdog's [[databases]] list and
HAProxy's server lines — both need to address individual nodes, not a load-balanced Service.
*/}}
{{- define "tsha.podFqdn" -}}
{{- printf "%s-%d.%s.%s.svc.cluster.local" (include "tsha.fullname" .ctx) (int .ordinal) (include "tsha.headlessServiceName" .ctx) .ctx.Release.Namespace -}}
{{- end }}

{{/*
Name of the Secret holding every password this chart consumes.
*/}}
{{- define "tsha.secretName" -}}
{{- .Values.auth.existingSecret | required "auth.existingSecret is required — this chart never takes an inline password (see infra/sealed-secrets)" -}}
{{- end }}

{{- define "tsha.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "tsha.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
pgdog sub-component naming.
*/}}
{{- define "tsha.pgdog.fullname" -}}
{{- printf "%s-pgdog" (include "tsha.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "tsha.pgdog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tsha.name" . }}-pgdog
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "tsha.pgdog.labels" -}}
helm.sh/chart: {{ include "tsha.chart" . }}
{{ include "tsha.pgdog.selectorLabels" . }}
app.kubernetes.io/component: pgdog
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
HAProxy sub-component naming.
*/}}
{{- define "tsha.haproxy.fullname" -}}
{{- printf "%s-haproxy" (include "tsha.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "tsha.haproxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tsha.name" . }}-haproxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "tsha.haproxy.labels" -}}
helm.sh/chart: {{ include "tsha.chart" . }}
{{ include "tsha.haproxy.selectorLabels" . }}
app.kubernetes.io/component: haproxy
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
