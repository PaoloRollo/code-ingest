{{- define "code-ingest.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "code-ingest.fullname" -}}
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

{{- define "code-ingest.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "code-ingest.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels for one component: pass (dict "root" $ "component" "mcp"). */}}
{{- define "code-ingest.selectorLabels" -}}
app.kubernetes.io/name: {{ include "code-ingest.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "code-ingest.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "code-ingest.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image reference for one component: pass (dict "root" $ "component" "mcp"). */}}
{{- define "code-ingest.image" -}}
{{- $image := index .root.Values.images .component }}
{{- $tag := required (printf "images.%s.tag is required (sha-<short>@sha256:<digest> from CI)" .component) $image.tag }}
{{- printf "%s:%s" $image.repository $tag }}
{{- end }}

{{- define "code-ingest.reposCacheClaim" -}}
{{- default (printf "%s-repos" (include "code-ingest.fullname" .)) .Values.ingest.reposCache.existingClaim }}
{{- end }}

{{/* Env shared by both workloads. */}}
{{- define "code-ingest.commonEnv" -}}
- name: QDRANT_URL
  value: {{ .Values.qdrant.url | quote }}
{{- if .Values.qdrant.apiKeySecret.name }}
- name: QDRANT_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.qdrant.apiKeySecret.name }}
      key: {{ .Values.qdrant.apiKeySecret.key }}
{{- end }}
- name: EMBEDDING_MODEL
  value: {{ .Values.embeddingModel | quote }}
- name: LOG_LEVEL
  value: {{ .Values.logLevel | quote }}
{{- end }}

{{- define "code-ingest.envFrom" -}}
{{- if .Values.envSecretName -}}
envFrom:
  - secretRef:
      name: {{ .Values.envSecretName }}
{{- end }}
{{- end }}

{{- define "code-ingest.spcVolumeMount" -}}
{{- if .Values.secretProviderClass.name -}}
- name: spc
  mountPath: {{ .Values.secretProviderClass.mountPath | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "code-ingest.spcVolume" -}}
{{- if .Values.secretProviderClass.name -}}
- name: spc
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ .Values.secretProviderClass.name | quote }}
{{- end }}
{{- end }}
