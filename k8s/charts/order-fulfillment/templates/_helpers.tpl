{{/*
Common labels
*/}}
{{- define "order-fulfillment.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Image helper
*/}}
{{- define "order-fulfillment.image" -}}
{{- $registry := .Values.global.registry -}}
{{- $image := .image -}}
{{- $tag := .Values.global.imageTag -}}
{{- printf "%s/%s:%s" $registry $image $tag -}}
{{- end }}