{{/*
Expand the name of the chart.
*/}}
{{- define "gzctf.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "gzctf.fullname" -}}
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
{{- define "gzctf.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "gzctf.labels" -}}
helm.sh/chart: {{ include "gzctf.chart" . }}
{{ include "gzctf.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "gzctf.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gzctf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "gzctf.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "gzctf.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
PostgreSQL fullname
*/}}
{{- define "gzctf.postgresql.fullname" -}}
{{- printf "%s-postgresql" (include "gzctf.fullname" .) -}}
{{- end }}

{{/*
PostgreSQL labels
*/}}
{{- define "gzctf.postgresql.labels" -}}
helm.sh/chart: {{ include "gzctf.chart" . }}
{{ include "gzctf.postgresql.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: database
{{- end }}

{{/*
PostgreSQL selector labels
*/}}
{{- define "gzctf.postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gzctf.name" . }}-postgresql
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Garnet fullname
*/}}
{{- define "gzctf.garnet.fullname" -}}
{{- printf "%s-garnet" (include "gzctf.fullname" .) -}}
{{- end }}

{{/*
Garnet labels
*/}}
{{- define "gzctf.garnet.labels" -}}
helm.sh/chart: {{ include "gzctf.chart" . }}
{{ include "gzctf.garnet.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: cache
{{- end }}

{{/*
Garnet selector labels
*/}}
{{- define "gzctf.garnet.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gzctf.name" . }}-garnet
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Database connection string
*/}}
{{- define "gzctf.databaseConnectionString" -}}
{{- if .Values.gzctf.config.database.host -}}
{{- printf "Host=%s;Database=%s;Username=%s;Password=%s" .Values.gzctf.config.database.host .Values.gzctf.config.database.name .Values.gzctf.config.database.username .Values.gzctf.config.database.password -}}
{{- else -}}
{{- printf "Host=%s:5432;Database=%s;Username=%s;Password=%s" (include "gzctf.postgresql.fullname" .) .Values.gzctf.config.database.name .Values.gzctf.config.database.username .Values.gzctf.config.database.password -}}
{{- end -}}
{{- end }}

{{/*
Redis connection string
*/}}
{{- define "gzctf.redisConnectionString" -}}
{{- if .Values.gzctf.config.redis.host -}}
{{- printf "%s,abortConnect=%t" .Values.gzctf.config.redis.host .Values.gzctf.config.redis.abortConnect -}}
{{- else -}}
{{- printf "%s:6379,abortConnect=%t" (include "gzctf.garnet.fullname" .) .Values.gzctf.config.redis.abortConnect -}}
{{- end -}}
{{- end }}
