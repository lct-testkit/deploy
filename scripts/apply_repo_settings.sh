#!/usr/bin/env bash
# Применяет к репозиториям организации настройки, которые нельзя закоммитить:
# защита main (ruleset), обязательные проверки, secret scanning, права Actions.
#
#   bash scripts/apply_repo_settings.sh            # dry-run: только печатает, что будет сделано
#   bash scripts/apply_repo_settings.sh --apply    # применить
#   bash scripts/apply_repo_settings.sh --apply backend deploy   # только выбранные репозитории
#
# Нужны: gh (GitHub CLI) с правами администратора организации (`gh auth login`,
# scope repo + admin:org) и jq. Идемпотентен: существующий ruleset с тем же именем
# обновляется, а не дублируется. Описание и обоснование — docs/REPO-SETTINGS.md.
set -euo pipefail

ORG="lct-testkit"
RULESET_NAME="protect-main"
# Сколько одобрений нужно для слияния PR (0 — только обязательные проверки).
REQUIRED_APPROVALS="${REQUIRED_APPROVALS:-1}"
APPLY=0
REPOS=()
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) REPOS+=("$arg") ;;
  esac
done
[[ ${#REPOS[@]} -eq 0 ]] && REPOS=(backend frontend rt-ui deploy)

command -v gh >/dev/null || { echo "нужен gh (https://cli.github.com)" >&2; exit 1; }
command -v jq >/dev/null || { echo "нужен jq" >&2; exit 1; }

# Имена job'ов CI, которые обязаны быть зелёными для слияния в main. Имена должны
# совпадать с `name:` job'ов в .github/workflows/*.yml.
checks_for() {
  case "$1" in
    backend)
      printf '%s\n' "lint · types · architecture · contract" "pytest + миграции (Postgres)" "зависимости · секреты · Dockerfile" ;;
    frontend)
      printf '%s\n' "lint · check · test · build" "контракт API · Dockerfile · секреты" ;;
    rt-ui)
      printf '%s\n' "lint · types · tests" "build · package · visual" ;;
    deploy)
      printf '%s\n' "yamllint" "actionlint" "images.yaml" "hadolint" "docker compose config" "shellcheck" \
                    "helm lint + kubeconform" "trivy fs" "compose · chart · копии конфигов vs images.yaml" ;;
  esac
}

run() {
  if [[ "${APPLY}" == 1 ]]; then
    "$@"
  else
    printf '[dry-run] %q ' "$@"; echo
  fi
}

ruleset_json() {
  local repo="$1" contexts_json bypass
  contexts_json="$(checks_for "${repo}" | jq -R '{context: .}' | jq -s '.')"
  # Администраторы репозитория (роль 5) могут смержить PR, минуя обязательное одобрение, —
  # иначе в команде из одного человека PR не смержить вовсе (автор не может одобрить свой PR).
  # deploy: бот (GitHub Actions, integration 15368) дополнительно пишет images.yaml прямо в main.
  if [[ "${repo}" == "deploy" ]]; then
    bypass='[{"actor_id": 15368, "actor_type": "Integration", "bypass_mode": "always"},
             {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}]'
  else
    bypass='[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}]'
  fi
  jq -n --arg name "${RULESET_NAME}" --arg approvals "${REQUIRED_APPROVALS}" --argjson contexts "${contexts_json}" --argjson bypass "${bypass}" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    bypass_actors: $bypass,
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    rules: [
      { type: "deletion" },
      { type: "non_fast_forward" },
      { type: "required_linear_history" },
      { type: "pull_request", parameters: {
          required_approving_review_count: ($approvals | tonumber),
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: true } },
      { type: "required_status_checks", parameters: {
          strict_required_status_checks_policy: true,
          required_status_checks: $contexts } }
    ]
  }'
}

for repo in "${REPOS[@]}"; do
  echo "== ${ORG}/${repo}"

  # 1. Ruleset защиты main (создать или обновить).
  existing="$(gh api "repos/${ORG}/${repo}/rulesets" --jq ".[] | select(.name==\"${RULESET_NAME}\") | .id" 2>/dev/null || true)"
  payload="$(ruleset_json "${repo}")"
  if [[ -n "${existing}" ]]; then
    run gh api -X PUT "repos/${ORG}/${repo}/rulesets/${existing}" --input - <<<"${payload}"
  else
    run gh api -X POST "repos/${ORG}/${repo}/rulesets" --input - <<<"${payload}"
  fi

  # 2. Secret scanning + push protection, Dependabot alerts.
  run gh api -X PATCH "repos/${ORG}/${repo}" --input - <<<'{
    "delete_branch_on_merge": true,
    "allow_squash_merge": true,
    "allow_merge_commit": false,
    "allow_rebase_merge": false,
    "security_and_analysis": {
      "secret_scanning": {"status": "enabled"},
      "secret_scanning_push_protection": {"status": "enabled"}
    }
  }'
  run gh api -X PUT "repos/${ORG}/${repo}/vulnerability-alerts"
  run gh api -X PUT "repos/${ORG}/${repo}/automated-security-fixes"

  # 3. Права Actions по умолчанию — только чтение; Actions не может одобрять PR.
  run gh api -X PUT "repos/${ORG}/${repo}/actions/permissions/workflow" --input - <<<'{
    "default_workflow_permissions": "read",
    "can_approve_pull_request_reviews": false
  }'
done

# 4. deploy хранит общий reusable-workflow (docker-publish.yml): разрешить вызов из других репозиториев организации.
if [[ " ${REPOS[*]} " == *" deploy "* ]]; then
  echo "== ${ORG}/deploy: доступ к reusable workflow"
  run gh api -X PUT "repos/${ORG}/deploy/actions/permissions/access" --input - <<<'{"access_level": "organization"}'
fi

echo
if [[ "${APPLY}" == 1 ]]; then echo "применено"; else echo "dry-run: ничего не изменено (добавьте --apply)"; fi
