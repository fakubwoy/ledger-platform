{{- define "ledger.dbSecret" -}}
{{ .Values.db.existingSecret | default (printf "%s-db" .Release.Name) }}
{{- end }}
{{- define "ledger.labels" -}}
app.kubernetes.io/name: ledger
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
