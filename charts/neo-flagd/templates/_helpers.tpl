{{/*
Expand the name of the chart.
*/}}
{{- define "neo-flagd.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "neo-flagd.fullname" -}}
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

{{- define "neo-flagd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "neo-flagd.selectorLabels" -}}
app.kubernetes.io/name: {{ include "neo-flagd.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "neo-flagd.labels" -}}
helm.sh/chart: {{ include "neo-flagd.chart" . }}
{{ include "neo-flagd.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "neo-flagd.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "neo-flagd.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Base JDBC/R2DBC connection target, without the scheme.

Both drivers point at the SAME endpoint; see the comment in configmap.yaml for why neither
of them goes through pgdog. `database.schema` appends ?currentSchema=, which is how this
service shares a database with others instead of taking one of its own.
*/}}
{{- define "neo-flagd.dbTarget" -}}
{{- $target := printf "%s:%v/%s" .Values.database.host .Values.database.port .Values.database.name -}}
{{- if .Values.database.schema -}}
{{- $target = printf "%s?currentSchema=%s" $target .Values.database.schema -}}
{{- end -}}
{{- $target -}}
{{- end }}

{{/*
Spring's OAuth2 registration id. It is NOT cosmetic: the callback path Keycloak must
whitelist is https://<host>/login/oauth2/code/<registrationId>. Change this and the
Valid Redirect URI on the Keycloak client has to change with it.
*/}}
{{- define "neo-flagd.oauthRegistrationId" -}}
{{- default "keycloak" .Values.auth.registrationId -}}
{{- end }}
