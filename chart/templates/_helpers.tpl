{{- define "peithos.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "peithos.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "peithos.labels" -}}
app.kubernetes.io/name: {{ include "peithos.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "peithos.selectorLabels" -}}
app.kubernetes.io/name: {{ include "peithos.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
