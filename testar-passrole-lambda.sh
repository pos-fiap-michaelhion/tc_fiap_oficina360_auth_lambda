#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ROLE_NAME="${ROLE_NAME:-LabRole}"
ROLE_ARN="${ROLE_ARN:-}"
FUNCTION_NAME="${FUNCTION_NAME:-oficina360-passrole-test}"
KEEP_FUNCTION="${KEEP_FUNCTION:-false}"
REPORT="${REPORT:-teste-passrole-lambda.txt}"

log() { printf '%s\n' "[INFO] $*"; }
ok() { printf '%s\n' "[OK] $*"; }
warn() { printf '%s\n' "[AVISO] $*" >&2; }
fail() { printf '%s\n' "[ERRO] $*" >&2; exit 1; }

for command_name in aws python3 jq; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name nao encontrado"
done

WORK_DIR="$(mktemp -d)"
ZIP_FILE="$WORK_DIR/function.zip"
AWS_ERROR="$WORK_DIR/aws-error.txt"
CREATED=false

cleanup() {
  if [[ "$CREATED" == "true" && "$KEEP_FUNCTION" != "true" ]]; then
    aws lambda delete-function \
      --function-name "$FUNCTION_NAME" \
      --region "$AWS_REGION" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

exec > >(tee "$REPORT") 2>&1

printf '%s\n' "===== IDENTIDADE AWS ====="
IDENTITY_JSON="$(aws sts get-caller-identity --output json)" || fail "Credenciais AWS ausentes ou expiradas"
ACCOUNT_ID="$(jq -r '.Account' <<< "$IDENTITY_JSON" 2>/dev/null || python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<< "$IDENTITY_JSON")"
CALLER_ARN="$(jq -r '.Arn' <<< "$IDENTITY_JSON" 2>/dev/null || python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])' <<< "$IDENTITY_JSON")"

echo "Account: $ACCOUNT_ID"
echo "Caller: $CALLER_ARN"
echo "Region: $AWS_REGION"

if [[ -z "$ROLE_ARN" ]]; then
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
fi

echo "Role testada: $ROLE_ARN"
echo "Funcao temporaria: $FUNCTION_NAME"

printf '\n%s\n' "===== PREPARANDO PACOTE MINIMO ====="
cat > "$WORK_DIR/lambda_function.py" <<'PY'
def handler(event, context):
    return {"statusCode": 200, "body": "passrole-ok"}
PY
python3 - "$WORK_DIR/lambda_function.py" "$ZIP_FILE" <<'PYZIP'
from pathlib import Path
import sys
import zipfile
source = Path(sys.argv[1])
target = Path(sys.argv[2])
with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    archive.write(source, arcname="lambda_function.py")
PYZIP
ok "Pacote temporario criado"

printf '\n%s\n' "===== LIMPANDO TESTE ANTERIOR ====="
if aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  warn "Funcao de teste anterior encontrada; tentando remover"
  aws lambda delete-function \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION" || fail "Nao foi possivel remover a funcao de teste anterior"
  sleep 3
else
  ok "Nenhuma funcao de teste anterior"
fi

printf '\n%s\n' "===== TESTE REAL DE CREATE FUNCTION E PASSROLE ====="
set +e
CREATE_OUTPUT="$(
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --handler lambda_function.handler \
    --role "$ROLE_ARN" \
    --zip-file "fileb://$ZIP_FILE" \
    --timeout 3 \
    --memory-size 128 \
    --region "$AWS_REGION" \
    --output json 2>"$AWS_ERROR"
)"
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  CREATED=true
  ok "iam:PassRole e lambda:CreateFunction foram aceitos para $ROLE_ARN"
  echo "$CREATE_OUTPUT"

  printf '\n%s\n' "===== AGUARDANDO FUNCAO ====="
  if aws lambda wait function-active-v2 \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION"; then
    ok "Funcao temporaria ficou ativa; a trust policy da role e compativel com Lambda"
  else
    warn "A API aceitou a role, mas a funcao nao ficou ativa. Consulte LastUpdateStatusReason."
    aws lambda get-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --region "$AWS_REGION" \
      --query '{State:State,StateReason:StateReason,LastUpdateStatus:LastUpdateStatus,LastUpdateStatusReason:LastUpdateStatusReason,Role:Role}' \
      --output json || true
  fi

  if [[ "$KEEP_FUNCTION" == "true" ]]; then
    warn "KEEP_FUNCTION=true: a funcao temporaria sera preservada"
    CREATED=false
  else
    aws lambda delete-function \
      --function-name "$FUNCTION_NAME" \
      --region "$AWS_REGION"
    CREATED=false
    ok "Funcao temporaria removida"
  fi

  printf '\n%s\n' "===== RESULTADO ====="
  echo "PASSROLE_TEST=PASS"
  echo "ROLE_ARN=$ROLE_ARN"
  exit 0
fi

ERROR_TEXT="$(cat "$AWS_ERROR")"
printf '%s\n' "$ERROR_TEXT"

printf '\n%s\n' "===== CLASSIFICACAO ====="
if grep -qi 'iam:PassRole' <<< "$ERROR_TEXT"; then
  echo "PASSROLE_TEST=DENIED"
  echo "A sessao nao pode passar esta role para Lambda."
  echo "Nenhuma alteracao em SAM ou CloudFormation corrige um explicit deny de iam:PassRole."
elif grep -qiE 'cannot be assumed by Lambda|The role defined for the function cannot be assumed' <<< "$ERROR_TEXT"; then
  echo "PASSROLE_TEST=TRUST_POLICY_INVALID"
  echo "A role foi aceita para passagem, mas nao confia em lambda.amazonaws.com."
elif grep -qi 'lambda:CreateFunction' <<< "$ERROR_TEXT"; then
  echo "PASSROLE_TEST=CREATE_FUNCTION_DENIED"
  echo "A sessao nao possui lambda:CreateFunction."
elif grep -qiE 'InvalidParameterValueException|ValidationException' <<< "$ERROR_TEXT"; then
  echo "PASSROLE_TEST=INVALID_ROLE_OR_PARAMETER"
  echo "A role pode nao existir, possuir path diferente, ou nao ser valida para Lambda."
else
  echo "PASSROLE_TEST=UNKNOWN_FAILURE"
  echo "Falha nao classificada automaticamente."
fi

echo "ROLE_ARN=$ROLE_ARN"
exit 1
