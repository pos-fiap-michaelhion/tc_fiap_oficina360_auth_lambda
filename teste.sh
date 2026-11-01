#!/usr/bin/env bash
set -Eeuo pipefail

APPLY="${APPLY:-false}"
AWS_REGION="${AWS_REGION:-us-east-1}"
RDS_IDENTIFIER="${RDS_IDENTIFIER:-oficina360-lab-postgres}"

LAMBDA_REPO="${LAMBDA_REPO:-pos-fiap-michaelhion/tc_fiap_oficina360_auth_lambda}"
APP_REPO="${APP_REPO:-pos-fiap-michaelhion/tc_fiap_oficina360_k8s_infra}"
UPDATE_APP_REPO="${UPDATE_APP_REPO:-true}"

fail() {
  printf '[ERRO] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[INFO] %s\n' "$*"
}

ok() {
  printf '[OK] %s\n' "$*"
}

mask() {
  # ::add-mask:: so deve ser emitido dentro do GitHub Actions.
  # Em terminal local, o comando exibiria o proprio valor sensivel.
  if [[ "${GITHUB_ACTIONS:-false}" == "true" && -n "${1:-}" ]]; then
    printf '::add-mask::%s\n' "$1"
  fi
}

for command_name in aws gh jq; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name nao encontrado"
done

aws sts get-caller-identity --output json >/dev/null 2>&1 ||
  fail "Credenciais AWS invalidas ou expiradas"

gh auth status >/dev/null 2>&1 ||
  fail "GitHub CLI nao autenticado"

DB_JSON="$(
  aws rds describe-db-instances \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --region "$AWS_REGION" \
    --output json
)"

DB_STATUS="$(jq -r '.DBInstances[0].DBInstanceStatus // empty' <<< "$DB_JSON")"
DB_ENDPOINT="$(jq -r '.DBInstances[0].Endpoint.Address // empty' <<< "$DB_JSON")"
DB_PORT="$(jq -r '.DBInstances[0].Endpoint.Port // empty' <<< "$DB_JSON")"
DB_NAME="$(jq -r '.DBInstances[0].DBName // empty' <<< "$DB_JSON")"
DB_USERNAME_FROM_RDS="$(jq -r '.DBInstances[0].MasterUsername // empty' <<< "$DB_JSON")"
RDS_SECRET_ARN="$(jq -r '.DBInstances[0].MasterUserSecret.SecretArn // empty' <<< "$DB_JSON")"
RDS_SECRET_STATUS="$(jq -r '.DBInstances[0].MasterUserSecret.SecretStatus // empty' <<< "$DB_JSON")"
DATABASE_ACCESS_SECURITY_GROUP_ID="$(
  jq -r '.DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId // empty' <<< "$DB_JSON"
)"

SUBNET_IDS="$(
  jq -r '
    [.DBInstances[0].DBSubnetGroup.Subnets[]?.SubnetIdentifier]
    | unique
    | join(",")
  ' <<< "$DB_JSON"
)"

[[ "$DB_STATUS" == "available" ]] ||
  fail "RDS nao esta available. Status atual: ${DB_STATUS:-desconhecido}"

[[ -n "$DB_ENDPOINT" ]] || fail "Endpoint do RDS nao encontrado"
[[ "$DB_PORT" =~ ^[0-9]+$ ]] || fail "Porta do RDS invalida"
[[ -n "$DB_NAME" ]] || fail "Nome do banco nao encontrado"
[[ -n "$RDS_SECRET_ARN" ]] || fail "RDS nao possui MasterUserSecret gerenciado"
[[ "$RDS_SECRET_STATUS" == "active" ]] ||
  fail "Segredo gerenciado do RDS nao esta active: ${RDS_SECRET_STATUS:-desconhecido}"
[[ "$DATABASE_ACCESS_SECURITY_GROUP_ID" =~ ^sg-[0-9a-f]+$ ]] ||
  fail "Security Group do RDS invalido"
[[ "$SUBNET_IDS" =~ ^subnet-[0-9a-f]+(,subnet-[0-9a-f]+)+$ ]] ||
  fail "O RDS precisa possuir pelo menos duas subnets validas"

DATABASE_URL="jdbc:postgresql://${DB_ENDPOINT}:${DB_PORT}/${DB_NAME}"

mask "$DB_ENDPOINT"
mask "$RDS_SECRET_ARN"
mask "$DATABASE_ACCESS_SECURITY_GROUP_ID"
mask "$SUBNET_IDS"
mask "$DATABASE_URL"

IFS=',' read -r -a SUBNET_ARRAY <<< "$SUBNET_IDS"
for subnet_id in "${SUBNET_ARRAY[@]}"; do
  mask "$subnet_id"
done

SECRET_JSON="$(
  aws secretsmanager get-secret-value \
    --secret-id "$RDS_SECRET_ARN" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text
)"

DB_USERNAME="$(jq -r '.username // empty' <<< "$SECRET_JSON")"
DB_PASSWORD="$(jq -r '.password // empty' <<< "$SECRET_JSON")"
unset SECRET_JSON

[[ -n "$DB_USERNAME" ]] || fail "Username ausente no segredo do RDS"
[[ -n "$DB_PASSWORD" ]] || fail "Password ausente no segredo do RDS"

if [[ -n "$DB_USERNAME_FROM_RDS" && "$DB_USERNAME" != "$DB_USERNAME_FROM_RDS" ]]; then
  fail "Username do segredo diverge do MasterUsername do RDS"
fi

mask "$DB_USERNAME"
mask "$DB_PASSWORD"

printf '===== PLANO DE SINCRONIZACAO =====\n'
printf 'RDS: disponivel\n'
printf 'Segredo gerenciado: ativo\n'
printf 'Subnets: %s\n' "${#SUBNET_ARRAY[@]}"
printf 'Repositorio Lambda: configurado\n'

if [[ "$UPDATE_APP_REPO" == "true" ]]; then
  printf 'Repositorio da aplicacao: configurado\n'
else
  printf 'Repositorio da aplicacao: ignorado\n'
fi

if [[ "$APPLY" != "true" ]]; then
  printf '\n[DRY-RUN] Nenhuma GitHub Variable ou Secret foi alterada.\n'
  printf 'Para aplicar: APPLY=true bash %s\n' "$0"
  exit 0
fi

set_repo_variable() {
  local repository="$1"
  local name="$2"
  local value="$3"

  # A versao instalada do gh le o valor do stdin quando --body nao e informado.
  printf '%s' "$value" |
    gh variable set "$name" \
      --repo "$repository" \
      >/dev/null
}

set_repo_secret() {
  local repository="$1"
  local name="$2"
  local value="$3"

  printf '%s' "$value" |
    gh secret set "$name" \
      --repo "$repository" \
      >/dev/null
}

info "Atualizando configuracao do repositorio Lambda"
set_repo_variable "$LAMBDA_REPO" DATABASE_URL "$DATABASE_URL"
set_repo_variable "$LAMBDA_REPO" RDS_SECRET_ARN "$RDS_SECRET_ARN"
set_repo_variable "$LAMBDA_REPO" LAMBDA_SECURITY_GROUP_ID "$DATABASE_ACCESS_SECURITY_GROUP_ID"
set_repo_variable "$LAMBDA_REPO" LAMBDA_SUBNET_IDS "$SUBNET_IDS"
set_repo_secret "$LAMBDA_REPO" DB_USERNAME "$DB_USERNAME"
set_repo_secret "$LAMBDA_REPO" DB_PASSWORD "$DB_PASSWORD"
ok "Repositorio Lambda sincronizado"

if [[ "$UPDATE_APP_REPO" == "true" ]]; then
  info "Atualizando configuracao do repositorio da aplicacao"
  set_repo_variable "$APP_REPO" DATABASE_URL "$DATABASE_URL"
  set_repo_secret "$APP_REPO" DB_USERNAME "$DB_USERNAME"
  set_repo_secret "$APP_REPO" DB_PASSWORD "$DB_PASSWORD"
  ok "Repositorio da aplicacao sincronizado"
fi

unset DB_USERNAME DB_PASSWORD DATABASE_URL RDS_SECRET_ARN

printf '\n[OK] Configuracoes atuais do RDS sincronizadas com o GitHub.\n'
printf 'Execute novamente os deploys da aplicacao e da Lambda.\n'

