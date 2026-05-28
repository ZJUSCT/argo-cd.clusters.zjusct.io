{{/*
Expand the name of the chart.
*/}}
{{- define "new-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "new-api.fullname" -}}
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
{{- define "new-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "new-api.labels" -}}
helm.sh/chart: {{ include "new-api.chart" . }}
{{ include "new-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "new-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "new-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "new-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "new-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate database DSN based on type
*/}}
{{- define "new-api.databaseDSN" -}}
{{- if eq .Values.database.type "postgresql" }}
{{- printf "postgresql://%s:%s@%s:%v/%s" .Values.database.username .Values.database.password .Values.database.host .Values.database.port .Values.database.name }}
{{- else if eq .Values.database.type "mysql" }}
{{- printf "%s:%s@tcp(%s:%v)/%s" .Values.database.username .Values.database.password .Values.database.host .Values.database.port .Values.database.name }}
{{- end }}
{{- end }}

{{/*
Generate Redis connection string
*/}}
{{- define "new-api.redisConnString" -}}
{{- if .Values.redis.password }}
{{- printf "redis://:%s@%s:%v/%v" .Values.redis.password .Values.redis.host .Values.redis.port .Values.redis.db }}
{{- else }}
{{- printf "redis://%s:%v/%v" .Values.redis.host .Values.redis.port .Values.redis.db }}
{{- end }}
{{- end }}

{{/*
Get full image name
*/}}
{{- define "new-api.image" -}}
{{- if .Values.image.registry }}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository .Values.image.tag }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end }}
{{- end }}
