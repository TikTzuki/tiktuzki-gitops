{{- define "x-hrm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "x-hrm.fullname" -}}
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

{{- define "x-hrm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "x-hrm.labels" -}}
helm.sh/chart: {{ include "x-hrm.chart" . }}
{{ include "x-hrm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "x-hrm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "x-hrm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "x-hrm.secretName" -}}
{{- default (printf "%s-secret" (include "x-hrm.fullname" .)) .Values.secret.name }}
{{- end }}

{{/*
Environment shared by the app container and the migrate initContainer, so the two can never
disagree about which database they talk to.
*/}}
{{- define "x-hrm.env" -}}
- name: ENV
  value: {{ .Values.app.env | quote }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "x-hrm.secretName" . }}
      key: {{ .Values.secret.databaseUrlKey }}
- name: MIGRATE_DB_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "x-hrm.secretName" . }}
      key: {{ .Values.secret.migrateDbUrlKey }}
      optional: true
- name: SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "x-hrm.secretName" . }}
      key: {{ .Values.secret.secretKeyKey }}
- name: ANTHROPIC_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "x-hrm.secretName" . }}
      key: {{ .Values.secret.anthropicApiKeyKey }}
      optional: true
- name: GOOGLE_CLIENT_ID
  value: {{ required "app.googleClientId is required — Google SSO is the only login" .Values.app.googleClientId | quote }}
- name: ROOT_USER_EMAIL
  value: {{ required "app.rootUserEmail is required — the one account that is always HR_ADMIN" .Values.app.rootUserEmail | quote }}
- name: ALLOWED_EMAIL_DOMAIN
  value: {{ .Values.app.allowedEmailDomain | quote }}
- name: TOKEN_TTL_HOURS
  value: {{ .Values.app.tokenTtlHours | quote }}
- name: MAX_UPLOAD_MB
  value: {{ .Values.app.maxUploadMb | quote }}
- name: AI_PROVIDER
  value: {{ .Values.app.aiProvider | quote }}
{{- with .Values.app.anthropicModel }}
- name: ANTHROPIC_MODEL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.app.anthropicBaseUrl }}
- name: ANTHROPIC_BASE_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.app.corsOrigins }}
- name: CORS_ORIGINS
  value: {{ . | quote }}
{{- end }}
{{- with .Values.app.metabase }}
{{- if .siteUrl }}
# Embedded Metabase dashboards (/analytics). The signing key is Metabase's "embedding secret
# key" — the same value as `embedding-secret-key` in demo/metabase-secret.
- name: METABASE_SITE_URL
  value: {{ .siteUrl | quote }}
- name: METABASE_DASHBOARDS
  value: {{ .dashboards | toJson | quote }}
- name: METABASE_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "x-hrm.secretName" $ }}
      key: {{ $.Values.secret.metabaseSecretKeyKey }}
      optional: true
{{- end }}
{{- end }}
# Inside the volume mounted at /data — anywhere else is not writable by uid 10001 and is
# lost on restart.
- name: UPLOAD_DIR
  value: /data/uploads
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
