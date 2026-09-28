{{/*
Namespace чарта нигде не хардкодится — везде используется .Release.Namespace
(helm install -n <ns> ...), стандартная практика Helm.

Имена K8s Service ЗАФИКСИРОВАНЫ и равны именам сервисов
backend/docker-compose.yml (postgres, redis, seaweedfs, keycloak, api,
caddy, web, sms-gateway-mock) — без обычного для Helm Release-префикса.
Причина: и переменные окружения (S3_ENDPOINT_URL=http://seaweedfs:8333,
SMS_GATEWAY_URL=http://sms-gateway-mock:8090 и т.п.), и Caddyfile в
configmap-caddy.yaml используют эти хосты напрямую как есть, буквально
скопированные из backend. Чтобы не переписывать их в чарте, для
единообразия ВСЕ объекты чарта (не только Service) названы этими же
плоскими именами, включая Secret/ConfigMap/Job.
*/}}

{{- define "rtk-crm.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Общие лейблы (без селекторных) — на объект целиком. */}}
{{- define "rtk-crm.labels" -}}
helm.sh/chart: {{ include "rtk-crm.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rtk-crm
{{- end -}}

{{/*
Лейблы конкретного компонента (postgres/api/caddy/...). Вызывается как
{{ include "rtk-crm.componentLabels" (dict "ctx" $ "name" "api") | nindent 4 }}
*/}}
{{- define "rtk-crm.componentLabels" -}}
{{ include "rtk-crm.labels" .ctx }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/component: {{ .name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/* Селекторные лейблы — должны быть неизменны между релизами одного объекта. */}}
{{- define "rtk-crm.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/* Единственный Secret чарта (см. templates/secret.yaml). */}}
{{- define "rtk-crm.secretName" -}}
rtk-crm-secrets
{{- end -}}

{{- define "rtk-crm.imagePullSecrets" -}}
{{- if .Values.images.pullSecrets }}
imagePullSecrets:
{{- range .Values.images.pullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Образ api — используют api/worker/migrate/seed/sms-gateway-mock (один и тот же образ, разная команда). */}}
{{- define "rtk-crm.apiImage" -}}
{{ .Values.images.registry }}/{{ .Values.images.api.repository }}:{{ .Values.images.api.tag }}{{ if .Values.images.api.digest }}@{{ .Values.images.api.digest }}{{ end }}
{{- end -}}

{{- define "rtk-crm.webImage" -}}
{{ .Values.images.registry }}/{{ .Values.images.web.repository }}:{{ .Values.images.web.tag }}{{ if .Values.images.web.digest }}@{{ .Values.images.web.digest }}{{ end }}
{{- end -}}

{{/* Внешние образы — пин по digest, без тега (см. ../../images.yaml). Вызов: include "rtk-crm.externalImage" .Values.images.postgres */}}
{{- define "rtk-crm.externalImage" -}}
{{ .repository }}@{{ .digest }}
{{- end -}}

{{/*
Общий whitelist переменных окружения для api/worker/migrate/seed — 1:1
перенос anchor'а x-api-env из backend/docker-compose.yml. Используется как
{{ include "rtk-crm.apiEnv" . | nindent N }} под ключом `env:` контейнера.
Caller может ДОПОЛНИТЬ список после include (WAIT_FOR_*, UVICORN_WORKERS)
или ПЕРЕОПРЕДЕЛИТЬ отдельную запись, указав её ЕЩЁ РАЗ ниже — Kubernetes
берёт последнее вхождение переменной с тем же именем в списке `env:` (тот
же приём, что `migrate` делает в исходном docker-compose.yml, переопределяя
DATABASE_URL после `<<: *api-env`).

Порядок ниже НЕ совпадает 1:1 с порядком в x-api-env: CRM_APP_PASSWORD и
POSTGRES_PASSWORD объявлены в начале, потому что Kubernetes разворачивает
$(VAR)-подстановку в поле `value:` только для переменных, уже объявленных
РАНЬШЕ в том же списке контейнера (в docker-compose ${...} разворачивается
при чтении compose-файла на хосте, до контейнера — этого ограничения там
нет). Сам список переменных внутри контейнера идентичен x-api-env, с ОДНИМ
дополнением: POSTGRES_PASSWORD (см. комментарий у неё) нужен только как
строительный блок для KC_DATABASE_URL и не самостоятельная настройка
приложения — Settings/x-api-env в backend такой переменной не знают.
*/}}
{{- define "rtk-crm.apiEnv" -}}
- name: CRM_APP_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: crm-app-password } }
- name: POSTGRES_PASSWORD
  # Только чтобы собрать KC_DATABASE_URL ниже через $(...): Keycloak
  # подключается суперпользователем postgres, не ролью crm_app (см.
  # комментарий у KC_DATABASE_URL в backend/docker-compose.yml). Значение —
  # то же, что POSTGRES_PASSWORD у StatefulSet postgres и KC_DB_PASSWORD у Keycloak.
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: postgres-password } }
- name: APP_PROFILE
  value: {{ .Values.env.appProfile | quote }}
- name: DATABASE_URL
  value: postgresql+asyncpg://crm_app:$(CRM_APP_PASSWORD)@postgres:5432/{{ .Values.env.postgresDb }}
- name: KC_DATABASE_URL
  value: postgresql+asyncpg://{{ .Values.env.postgresUser }}:$(POSTGRES_PASSWORD)@postgres:5432/keycloak
- name: REDIS_URL
  value: redis://redis:6379/0
- name: BASE_URL
  value: {{ .Values.env.baseURL | quote }}
- name: KEYCLOAK_URL
  value: {{ .Values.env.keycloakPublicURL | quote }}
- name: KEYCLOAK_INTERNAL_URL
  value: http://keycloak:8080/auth
- name: KEYCLOAK_REALM
  value: {{ .Values.env.keycloakRealm | quote }}
- name: KEYCLOAK_CLIENT_ID
  value: {{ .Values.env.keycloakClientId | quote }}
- name: KEYCLOAK_CLIENT_SECRET
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: keycloak-client-secret } }
- name: KEYCLOAK_ADMIN_CLIENT_ID
  value: {{ .Values.env.keycloakAdminClientId | quote }}
- name: KEYCLOAK_ADMIN_CLIENT_SECRET
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: keycloak-admin-client-secret } }
- name: KEYCLOAK_VERIFY_AUDIENCE
  value: {{ .Values.env.keycloakVerifyAudience | quote }}
- name: ALLOW_BEARER_AUTH
  value: {{ .Values.env.allowBearerAuth | quote }}
- name: S3_ENDPOINT_URL
  value: http://seaweedfs:8333
- name: S3_PUBLIC_ENDPOINT_URL
  value: {{ .Values.env.s3PublicEndpointURL | quote }}
- name: S3_ACCESS_KEY
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: s3-access-key } }
- name: S3_SECRET_KEY
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: s3-secret-key } }
- name: SIGNATURE_SERVER_SECRET
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: signature-server-secret } }
- name: NTP_HOST
  value: ntp
- name: SMS_GATEWAY_URL
  value: http://sms-gateway-mock:8090
- name: LOG_LEVEL
  value: {{ .Values.env.logLevel | quote }}
- name: LOG_JSON
  value: {{ .Values.env.logJson | quote }}
- name: WORKER_METRICS_PORT
  value: {{ .Values.env.workerMetricsPort | quote }}
- name: CMS_WEBHOOK_SECRET_REF
  value: {{ .Values.env.cmsWebhookSecretRef | quote }}
- name: LMS_BASE_URL
  value: {{ .Values.env.lmsBaseURL | quote }}
- name: LMS_AUTH_REF
  value: {{ .Values.env.lmsAuthRef | quote }}
- name: BITRIX_CONNECTOR_ENABLED
  value: {{ .Values.env.bitrixConnectorEnabled | quote }}
- name: BITRIX_WEBHOOK_URL_REF
  value: {{ .Values.env.bitrixWebhookUrlRef | quote }}
- name: INTEGRATION_WEBHOOK_RATE_LIMIT_PER_MIN
  value: {{ .Values.env.integrationWebhookRateLimitPerMin | quote }}
- name: CMS_WEBHOOK_SECRET
  value: {{ .Values.env.cmsWebhookSecret | quote }}
- name: BITRIX_WEBHOOK_URL
  value: {{ .Values.env.bitrixWebhookUrl | quote }}
- name: BITRIX_SOURCE_ID
  value: {{ .Values.env.bitrixSourceId | quote }}
- name: ALLOWED_FILE_EXTENSIONS
  value: {{ .Values.env.allowedFileExtensions | quote }}
- name: SIGNATURE_EXPOSE_DEBUG_OTP
  value: {{ .Values.env.signatureExposeDebugOtp | quote }}
# Ключ HMAC цепочки аудита (хэш v3) и ключ шифрования секретных системных настроек: пусто — функции
# выключены (как в backend/.env.example), непусто — только через Secret, не values.yaml открытым текстом.
- name: AUDIT_HMAC_KEY
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: audit-hmac-key } }
- name: SETTINGS_ENCRYPTION_KEY
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: settings-encryption-key } }
# Почта (ссылки подписантам, email-уведомления): без SMTP_HOST письма остаются в очереди.
- name: SMTP_HOST
  value: {{ .Values.env.smtpHost | quote }}
- name: SMTP_PORT
  value: {{ .Values.env.smtpPort | quote }}
- name: SMTP_USER
  value: {{ .Values.env.smtpUser | quote }}
- name: SMTP_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ include "rtk-crm.secretName" . }}, key: smtp-password } }
- name: SMTP_FROM
  value: {{ .Values.env.smtpFrom | quote }}
- name: SMTP_STARTTLS
  value: {{ .Values.env.smtpStarttls | quote }}
{{- end -}}

{{/*
initContainer, ожидающий готовности postgres — переиспользует уже
запиненный образ postgres (pg_isready) вместо добавления нового
generic-образа. Переводит compose'овский `depends_on: condition:
service_healthy` в K8s-нативный механизм (см. также WAIT_FOR_POSTGRES —
entrypoint.sh делает свой TCP-poll ДОПОЛНИТЕЛЬНО, не вместо этого).
*/}}
{{- define "rtk-crm.waitForPostgres" -}}
- name: wait-for-postgres
  image: "{{ include "rtk-crm.externalImage" .Values.images.postgres }}"
  imagePullPolicy: {{ .Values.images.pullPolicy }}
  command:
    - sh
    - -c
    - until pg_isready -h postgres -p 5432 -U "$POSTGRES_USER"; do echo "ожидание postgres..."; sleep 2; done
  env:
    - name: POSTGRES_USER
      value: {{ .Values.env.postgresUser | quote }}
  resources:
    requests: { cpu: 10m, memory: 16Mi }
    limits: { cpu: 100m, memory: 32Mi }
{{- end -}}

{{/* Аналогично — ожидание redis, переиспользует образ redis (redis-cli ping). */}}
{{- define "rtk-crm.waitForRedis" -}}
- name: wait-for-redis
  image: "{{ include "rtk-crm.externalImage" .Values.images.redis }}"
  imagePullPolicy: {{ .Values.images.pullPolicy }}
  command:
    - sh
    - -c
    - until redis-cli -h redis -p 6379 ping; do echo "ожидание redis..."; sleep 2; done
  resources:
    requests: { cpu: 10m, memory: 16Mi }
    limits: { cpu: 100m, memory: 32Mi }
{{- end -}}

{{/*
Ожидание keycloak (используется только у api — там это жёсткая
зависимость service_healthy, у caddy в compose она "мягкая", см.
comment в caddy-deployment.yaml). Переиспользует образ keycloak и тот же
приём health-проверки, что healthcheck сервиса keycloak в
backend/docker-compose.yml (в образе нет ни curl, ни wget).
*/}}
{{- define "rtk-crm.waitForKeycloak" -}}
- name: wait-for-keycloak
  image: "{{ include "rtk-crm.externalImage" .Values.images.keycloak }}"
  imagePullPolicy: {{ .Values.images.pullPolicy }}
  command:
    - bash
    - -c
    - |
      until (exec 3<>/dev/tcp/keycloak/9000 \
          && printf 'GET /auth/health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 \
          && grep -q '"UP"' <&3); do
        echo "ожидание keycloak..."
        sleep 3
      done
  resources:
    requests: { cpu: 10m, memory: 64Mi }
    limits: { cpu: 200m, memory: 128Mi }
{{- end -}}
