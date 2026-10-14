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

{{/*
Component-scoped helpers take (dict "root" $ "component" "mcp"|"ingest").
*/}}

{{- define "code-ingest.selectorLabels" -}}
app.kubernetes.io/name: {{ include "code-ingest.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "code-ingest.serviceAccountName" -}}
{{- if .root.Values.serviceAccount.create }}
{{- printf "%s-%s" (include "code-ingest.fullname" .root) .component }}
{{- else }}
{{- "default" }}
{{- end }}
{{- end }}

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
- name: EMBEDDING_MODEL
  value: {{ .Values.embeddingModel | quote }}
- name: LOG_LEVEL
  value: {{ .Values.logLevel | quote }}
# Read-only root filesystem: git and Python get their writable scratch in /tmp.
- name: HOME
  value: /tmp
- name: PYTHONDONTWRITEBYTECODE
  value: "1"
{{- end }}

{{/*
<VAR>_FILE env for each secretFiles entry. A secretFiles entry without a
SecretProviderClass would point at a file that never exists: fail the render.
*/}}
{{- define "code-ingest.secretFileEnv" -}}
{{- $values := index .root.Values .component }}
{{- if and $values.secretFiles (not $values.secretProviderClass) }}
{{- fail (printf "%s.secretFiles is set but %s.secretProviderClass is empty" .component .component) }}
{{- end }}
{{- range $var, $object := $values.secretFiles }}
- name: {{ printf "%s_FILE" $var }}
  value: {{ printf "/mnt/secrets-store/%s" $object | quote }}
{{- end }}
{{- end }}

{{- define "code-ingest.spcVolumeMount" -}}
{{- if (index .root.Values .component).secretProviderClass -}}
- name: secrets
  mountPath: /mnt/secrets-store
  readOnly: true
{{- end }}
{{- end }}

{{- define "code-ingest.spcVolume" -}}
{{- with (index .root.Values .component).secretProviderClass -}}
- name: secrets
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ . | quote }}
{{- end }}
{{- end }}
