#!/usr/bin/env bash
set -uo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-oficina360-auth}"
DB_IDENTIFIER="${DB_IDENTIFIER:-oficina360-lab-postgres}"
EXPECTED_DB_PORT="${EXPECTED_DB_PORT:-5432}"
REPORT="${REPORT:-validacao-lambda-rds.txt}"
INVOKE_LAMBDA="${INVOKE_LAMBDA:-false}"
DOCUMENT="${DOCUMENT:-529.982.247-25}"
LOG_SINCE="${LOG_SINCE:-10m}"

OK_COUNT=0
WARN_COUNT=0
ERROR_COUNT=0

section() { printf '\n===== %s =====\n' "$1"; }
ok() { OK_COUNT=$((OK_COUNT + 1)); printf '[OK] %s\n' "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[AVISO] %s\n' "$1"; }
error() { ERROR_COUNT=$((ERROR_COUNT + 1)); printf '[ERRO] %s\n' "$1"; }

for command_name in aws jq python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "[ERRO] $command_name nao encontrado" >&2
    exit 2
  }
done

exec > >(tee "$REPORT") 2>&1

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

section "IDENTIDADE AWS"
if aws sts get-caller-identity --output json > "$WORK_DIR/identity.json" 2> "$WORK_DIR/identity.err"; then
  ACCOUNT_ID="$(jq -r '.Account' "$WORK_DIR/identity.json")"
  CALLER_ARN="$(jq -r '.Arn' "$WORK_DIR/identity.json")"
  echo "Account: $ACCOUNT_ID"
  echo "Caller: $CALLER_ARN"
  echo "Region: $AWS_REGION"
  ok "Credenciais AWS validas"
else
  cat "$WORK_DIR/identity.err"
  error "Credenciais AWS ausentes ou expiradas"
  exit 1
fi

section "CONFIGURACAO DA LAMBDA"
if aws lambda get-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --output json > "$WORK_DIR/lambda.json" 2> "$WORK_DIR/lambda.err"; then

  LAMBDA_STATE="$(jq -r '.State // ""' "$WORK_DIR/lambda.json")"
  LAMBDA_UPDATE_STATUS="$(jq -r '.LastUpdateStatus // ""' "$WORK_DIR/lambda.json")"
  LAMBDA_ROLE="$(jq -r '.Role // ""' "$WORK_DIR/lambda.json")"
  LAMBDA_VPC_ID="$(jq -r '.VpcConfig.VpcId // ""' "$WORK_DIR/lambda.json")"
  LAMBDA_SGS="$(jq -r '.VpcConfig.SecurityGroupIds // [] | join(",")' "$WORK_DIR/lambda.json")"
  LAMBDA_SUBNETS="$(jq -r '.VpcConfig.SubnetIds // [] | join(",")' "$WORK_DIR/lambda.json")"
  DB_URL="$(jq -r '.Environment.Variables.DB_URL // ""' "$WORK_DIR/lambda.json")"
  ENV_KEYS="$(jq -r '.Environment.Variables // {} | keys | join(",")' "$WORK_DIR/lambda.json")"

  echo "State: $LAMBDA_STATE"
  echo "LastUpdateStatus: $LAMBDA_UPDATE_STATUS"
  echo "Role: $LAMBDA_ROLE"
  echo "VpcId: $LAMBDA_VPC_ID"
  echo "Subnets: $LAMBDA_SUBNETS"
  echo "SecurityGroups: $LAMBDA_SGS"
  echo "Environment keys: $ENV_KEYS"
  echo "DB_URL: $DB_URL"

  [[ "$LAMBDA_STATE" == "Active" ]] && ok "Lambda esta ativa" || error "Lambda nao esta ativa: $LAMBDA_STATE"
  [[ "$LAMBDA_UPDATE_STATUS" == "Successful" ]] && ok "Ultima atualizacao da Lambda foi bem-sucedida" || warn "LastUpdateStatus=$LAMBDA_UPDATE_STATUS"
  [[ -n "$LAMBDA_VPC_ID" ]] && ok "Lambda esta associada a uma VPC" || error "Lambda nao esta associada a uma VPC"
  [[ -n "$LAMBDA_SUBNETS" ]] && ok "Lambda possui subnets" || error "Lambda nao possui subnets"
  [[ -n "$LAMBDA_SGS" ]] && ok "Lambda possui Security Group" || error "Lambda nao possui Security Group"

  if [[ "$DB_URL" =~ ^jdbc:postgresql://([^/:]+):([0-9]+)/([^/?]+)$ ]]; then
    DB_URL_HOST="${BASH_REMATCH[1]}"
    DB_URL_PORT="${BASH_REMATCH[2]}"
    DB_URL_NAME="${BASH_REMATCH[3]}"
    ok "DB_URL possui formato JDBC valido"
  else
    DB_URL_HOST=""
    DB_URL_PORT=""
    DB_URL_NAME=""
    error "DB_URL ausente ou invalida"
  fi
else
  cat "$WORK_DIR/lambda.err"
  error "Nao foi possivel consultar a Lambda $FUNCTION_NAME"
  exit 1
fi

section "CONFIGURACAO DO RDS"
if aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION" \
  --query 'DBInstances[0]' \
  --output json > "$WORK_DIR/rds.json" 2> "$WORK_DIR/rds.err"; then

  RDS_STATUS="$(jq -r '.DBInstanceStatus // ""' "$WORK_DIR/rds.json")"
  RDS_ENDPOINT="$(jq -r '.Endpoint.Address // ""' "$WORK_DIR/rds.json")"
  RDS_PORT="$(jq -r '.Endpoint.Port // ""' "$WORK_DIR/rds.json")"
  RDS_VPC_ID="$(jq -r '.DBSubnetGroup.VpcId // ""' "$WORK_DIR/rds.json")"
  RDS_SGS="$(jq -r '.VpcSecurityGroups // [] | map(.VpcSecurityGroupId) | join(",")' "$WORK_DIR/rds.json")"
  RDS_SUBNETS="$(jq -r '.DBSubnetGroup.Subnets // [] | map(.SubnetIdentifier) | join(",")' "$WORK_DIR/rds.json")"
  RDS_PUBLIC="$(jq -r '.PubliclyAccessible // false' "$WORK_DIR/rds.json")"

  echo "Status: $RDS_STATUS"
  echo "Endpoint: $RDS_ENDPOINT"
  echo "Port: $RDS_PORT"
  echo "VpcId: $RDS_VPC_ID"
  echo "Subnets: $RDS_SUBNETS"
  echo "SecurityGroups: $RDS_SGS"
  echo "PubliclyAccessible: $RDS_PUBLIC"

  [[ "$RDS_STATUS" == "available" ]] && ok "RDS esta disponivel" || error "RDS nao esta disponivel: $RDS_STATUS"
  [[ "$RDS_PORT" == "$EXPECTED_DB_PORT" ]] && ok "RDS usa a porta esperada $EXPECTED_DB_PORT" || error "RDS usa porta $RDS_PORT, esperado $EXPECTED_DB_PORT"
else
  cat "$WORK_DIR/rds.err"
  error "Nao foi possivel consultar o RDS $DB_IDENTIFIER"
  exit 1
fi

section "CONSISTENCIA LAMBDA E RDS"
[[ "$LAMBDA_VPC_ID" == "$RDS_VPC_ID" ]] \
  && ok "Lambda e RDS estao na mesma VPC: $RDS_VPC_ID" \
  || error "VPC divergente: Lambda=$LAMBDA_VPC_ID RDS=$RDS_VPC_ID"

[[ "$DB_URL_HOST" == "$RDS_ENDPOINT" ]] \
  && ok "DB_URL usa o endpoint atual do RDS" \
  || error "DB_URL host=$DB_URL_HOST, RDS endpoint=$RDS_ENDPOINT"

[[ "$DB_URL_PORT" == "$RDS_PORT" ]] \
  && ok "DB_URL usa a porta atual do RDS" \
  || error "DB_URL port=$DB_URL_PORT, RDS port=$RDS_PORT"

COMMON_SGS="$(
  python3 - "$LAMBDA_SGS" "$RDS_SGS" <<'PY'
import sys
left = {x for x in sys.argv[1].split(',') if x}
right = {x for x in sys.argv[2].split(',') if x}
print(','.join(sorted(left & right)))
PY
)"

if [[ -n "$COMMON_SGS" ]]; then
  ok "Lambda e RDS compartilham Security Group: $COMMON_SGS"
else
  warn "Lambda e RDS usam Security Groups diferentes; a regra do RDS deve referenciar o SG da Lambda"
fi

section "DNS DO ENDPOINT RDS"
if python3 - "$RDS_ENDPOINT" <<'PY'
import socket
import sys
host = sys.argv[1]
addresses = sorted({item[4][0] for item in socket.getaddrinfo(host, 5432, type=socket.SOCK_STREAM)})
print("Enderecos resolvidos:", ", ".join(addresses))
PY
then
  ok "Endpoint RDS resolve por DNS a partir da maquina local"
else
  error "Endpoint RDS nao resolveu por DNS localmente"
fi

section "REGRAS DOS SECURITY GROUPS"
IFS=',' read -r -a RDS_SG_ARRAY <<< "$RDS_SGS"
IFS=',' read -r -a LAMBDA_SG_ARRAY <<< "$LAMBDA_SGS"

INGRESS_FOUND=false
for rds_sg in "${RDS_SG_ARRAY[@]}"; do
  [[ -n "$rds_sg" ]] || continue

  if aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$rds_sg" \
    --region "$AWS_REGION" \
    --output json > "$WORK_DIR/rules-$rds_sg.json" 2> "$WORK_DIR/rules-$rds_sg.err"; then

    echo "Regras de $rds_sg:"
    jq -r '.SecurityGroupRules[] | [.IsEgress, .IpProtocol, (.FromPort // ""), (.ToPort // ""), (.ReferencedGroupInfo.GroupId // ""), (.CidrIpv4 // "")] | @tsv' "$WORK_DIR/rules-$rds_sg.json"

    for lambda_sg in "${LAMBDA_SG_ARRAY[@]}"; do
      [[ -n "$lambda_sg" ]] || continue
      if jq -e \
        --arg source "$lambda_sg" \
        --argjson port "$EXPECTED_DB_PORT" \
        '.SecurityGroupRules[] | select(
          .IsEgress == false and
          .IpProtocol == "tcp" and
          .FromPort <= $port and
          .ToPort >= $port and
          .ReferencedGroupInfo.GroupId == $source
        )' "$WORK_DIR/rules-$rds_sg.json" >/dev/null; then
        ok "RDS SG $rds_sg permite TCP $EXPECTED_DB_PORT a partir do Lambda SG $lambda_sg"
        INGRESS_FOUND=true
      fi
    done
  else
    cat "$WORK_DIR/rules-$rds_sg.err"
    warn "Nao foi possivel consultar regras de $rds_sg"
  fi
done

[[ "$INGRESS_FOUND" == "true" ]] || error "Nenhuma regra ingress do RDS permite TCP $EXPECTED_DB_PORT a partir dos SGs da Lambda"

EGRESS_FOUND=false
for lambda_sg in "${LAMBDA_SG_ARRAY[@]}"; do
  [[ -n "$lambda_sg" ]] || continue
  RULE_FILE="$WORK_DIR/rules-$lambda_sg.json"
  if [[ ! -f "$RULE_FILE" ]]; then
    aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=$lambda_sg" \
      --region "$AWS_REGION" \
      --output json > "$RULE_FILE" 2>/dev/null || true
  fi

  if [[ -s "$RULE_FILE" ]] && jq -e \
    --argjson port "$EXPECTED_DB_PORT" \
    '.SecurityGroupRules[] | select(
      .IsEgress == true and
      (
        .IpProtocol == "-1" or
        (.IpProtocol == "tcp" and .FromPort <= $port and .ToPort >= $port)
      )
    )' "$RULE_FILE" >/dev/null; then
    ok "Lambda SG $lambda_sg possui egress compativel com TCP $EXPECTED_DB_PORT"
    EGRESS_FOUND=true
  fi
done

[[ "$EGRESS_FOUND" == "true" ]] || error "Nenhum SG da Lambda possui egress compativel com TCP $EXPECTED_DB_PORT"

section "SUBNETS E NETWORK ACLS"
ALL_SUBNETS="$LAMBDA_SUBNETS,$RDS_SUBNETS"
UNIQUE_SUBNETS="$(
  python3 - "$ALL_SUBNETS" <<'PY'
import sys
print('\n'.join(sorted({x for x in sys.argv[1].split(',') if x})))
PY
)"

while IFS= read -r subnet_id; do
  [[ -n "$subnet_id" ]] || continue
  echo "--- $subnet_id ---"

  aws ec2 describe-subnets \
    --subnet-ids "$subnet_id" \
    --region "$AWS_REGION" \
    --query 'Subnets[0].{VpcId:VpcId,AZ:AvailabilityZone,Cidr:CidrBlock,Available:AvailableIpAddressCount}' \
    --output json || warn "Nao foi possivel consultar $subnet_id"

  if aws ec2 describe-network-acls \
    --filters "Name=association.subnet-id,Values=$subnet_id" \
    --region "$AWS_REGION" \
    --output json > "$WORK_DIR/nacl-$subnet_id.json" 2> "$WORK_DIR/nacl-$subnet_id.err"; then

    NACL_COUNT="$(jq '.NetworkAcls | length' "$WORK_DIR/nacl-$subnet_id.json")"
    if [[ "$NACL_COUNT" -eq 0 ]]; then
      warn "Nenhuma NACL encontrada para $subnet_id"
    else
      jq -r '.NetworkAcls[] | "NACL=\(.NetworkAclId) Default=\(.IsDefault)", (.Entries[] | [.RuleNumber,.Egress,.Protocol,.RuleAction,(.PortRange.From // ""),(.PortRange.To // ""),.CidrBlock] | @tsv)' "$WORK_DIR/nacl-$subnet_id.json"
      if jq -e '.NetworkAcls[] | select(.IsDefault == true)' "$WORK_DIR/nacl-$subnet_id.json" >/dev/null; then
        ok "$subnet_id usa NACL default"
      else
        warn "$subnet_id usa NACL customizada; revise TCP 5432 e portas 1024-65535 nos dois sentidos"
      fi
    fi
  else
    cat "$WORK_DIR/nacl-$subnet_id.err"
    warn "Nao foi possivel consultar NACL de $subnet_id"
  fi
done <<< "$UNIQUE_SUBNETS"

section "ROLES E ESTADO DA VPC DA LAMBDA"
echo "Role: $LAMBDA_ROLE"
if [[ "$LAMBDA_ROLE" == *'/LabRole' ]]; then
  ok "Lambda usa LabRole validada anteriormente"
else
  warn "Lambda usa role diferente de LabRole"
fi

section "LOGS RECENTES DA LAMBDA"
if aws logs tail "/aws/lambda/$FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --since "$LOG_SINCE" \
  --format short > "$WORK_DIR/logs.txt" 2> "$WORK_DIR/logs.err"; then

  tail -n 120 "$WORK_DIR/logs.txt"

  if grep -q 'SocketTimeoutException: Connect timed out' "$WORK_DIR/logs.txt"; then
    error "Logs recentes ainda mostram timeout TCP com o PostgreSQL"
  elif grep -qi 'password authentication failed' "$WORK_DIR/logs.txt"; then
    error "Rede funciona, mas a autenticacao PostgreSQL falhou"
  elif grep -qiE 'relation .* does not exist|does not exist' "$WORK_DIR/logs.txt"; then
    error "Rede e autenticacao funcionam, mas falta schema ou tabela"
  elif grep -qiE 'PSQLException|RuntimeException|ERROR' "$WORK_DIR/logs.txt"; then
    warn "Existem erros recentes na Lambda; revise o bloco de logs"
  else
    ok "Nenhum erro conhecido encontrado nos logs recentes"
  fi
else
  cat "$WORK_DIR/logs.err"
  warn "Nao foi possivel consultar logs da Lambda"
fi

section "INVOCACAO DIRETA OPCIONAL"
if [[ "$INVOKE_LAMBDA" == "true" ]]; then
  python3 - "$WORK_DIR/event.json" "$DOCUMENT" <<'PY'
import json
import sys
path, document = sys.argv[1], sys.argv[2]
event = {
    "resource": "/auth",
    "path": "/auth",
    "httpMethod": "POST",
    "headers": {"Content-Type": "application/json"},
    "requestContext": {"stage": "Prod"},
    "body": json.dumps({"document": document}),
    "isBase64Encoded": False,
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(event, stream)
PY

  if aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --region "$AWS_REGION" \
    --cli-binary-format raw-in-base64-out \
    --payload "file://$WORK_DIR/event.json" \
    "$WORK_DIR/response.json" > "$WORK_DIR/invoke-meta.json" 2> "$WORK_DIR/invoke.err"; then

    echo "Invoke metadata:"
    cat "$WORK_DIR/invoke-meta.json"
    echo
    echo "Response:"
    cat "$WORK_DIR/response.json"
    echo

    FUNCTION_ERROR="$(jq -r '.FunctionError // ""' "$WORK_DIR/invoke-meta.json")"
    [[ -z "$FUNCTION_ERROR" ]] && ok "Invocacao direta concluida sem FunctionError" || error "Invocacao direta retornou FunctionError=$FUNCTION_ERROR"
  else
    cat "$WORK_DIR/invoke.err"
    error "Falha ao invocar a Lambda diretamente"
  fi
else
  echo "Invocacao desativada. Para testar: INVOKE_LAMBDA=true bash $0"
fi

section "DIAGNOSTICO"
if [[ "$LAMBDA_VPC_ID" != "$RDS_VPC_ID" ]]; then
  echo "Causa provavel: Lambda e RDS estao em VPCs diferentes."
elif [[ "$INGRESS_FOUND" != "true" ]]; then
  echo "Causa provavel: falta ingress TCP $EXPECTED_DB_PORT do SG da Lambda para o SG do RDS."
elif [[ "$EGRESS_FOUND" != "true" ]]; then
  echo "Causa provavel: falta egress TCP $EXPECTED_DB_PORT no SG da Lambda."
elif grep -q 'SocketTimeoutException: Connect timed out' "$WORK_DIR/logs.txt" 2>/dev/null; then
  echo "SGs e VPC parecem coerentes, mas o timeout persiste. Revise NACLs, subnets reais do DB subnet group e rotas locais da VPC."
else
  echo "Nao foi identificado bloqueio de rede evidente. Use INVOKE_LAMBDA=true para testar o handler diretamente."
fi

section "RESUMO"
echo "OK=$OK_COUNT"
echo "AVISOS=$WARN_COUNT"
echo "ERROS=$ERROR_COUNT"
echo "Relatorio=$REPORT"

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  exit 1
fi
