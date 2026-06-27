{{/*
Expand the name of the chart.
*/}}
{{- define "kafka.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kafka.fullname" -}}
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
{{- define "kafka.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kafka.labels" -}}
helm.sh/chart: {{ include "kafka.chart" . }}
{{ include "kafka.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kafka.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Headless service name — gives the pod a stable DNS record:
  {{ fullname }}-{ordinal}.{{ fullname }}-headless.{namespace}.svc.cluster.local
used for the advertised PLAINTEXT listener and the KRaft controller quorum voter.
*/}}
{{- define "kafka.headlessServiceName" -}}
{{- printf "%s-headless" (include "kafka.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kafka.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kafka.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
KAFKA_LISTENERS — bind addresses for each listener.
*/}}
{{- define "kafka.listeners" -}}
{{- $l := printf "PLAINTEXT://:%v,CONTROLLER://:%v" .Values.kafka.clientPort .Values.kafka.controllerPort -}}
{{- if .Values.external.enabled -}}
{{- $l = printf "%s,EXTERNAL://:%v" $l .Values.external.port -}}
{{- end -}}
{{- $l -}}
{{- end }}

{{/*
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP — all PLAINTEXT in this homelab setup.
*/}}
{{- define "kafka.protocolMap" -}}
{{- $m := "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT" -}}
{{- if .Values.external.enabled -}}
{{- $extProto := ternary "SASL_PLAINTEXT" "PLAINTEXT" .Values.auth.enabled -}}
{{- $m = printf "%s,EXTERNAL:%s" $m $extProto -}}
{{- end -}}
{{- $m -}}
{{- end }}

{{/*
Name of the secret holding the SCRAM admin password.
*/}}
{{- define "kafka.auth.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "kafka.fullname" . -}}
{{- end -}}
{{- end }}

{{/*
Kafka UI (kafbat/kafka-ui) — a separate web Deployment fronting the broker.
*/}}
{{- define "kafka.ui.fullname" -}}
{{- printf "%s-ui" (include "kafka.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kafka.ui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kafka.name" . }}-ui
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "kafka.ui.labels" -}}
helm.sh/chart: {{ include "kafka.chart" . }}
{{ include "kafka.ui.selectorLabels" . }}
app.kubernetes.io/component: kafka-ui
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
