#!/usr/bin/env bash
set -uo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-oficina360-auth}"
DB_IDENTIFIER="${DB_IDENTIFIER:-oficina360-lab-postgres}"
DB_PORT="${DB_PORT:-5432}"
REPORT="${REPORT:-validacao-lambda-rds-v2.txt}"

OK=0
WARN=0
ERR=0
section() { printf '\n===== %s =====\n' "$1"; }
ok() { OK=$((OK+1)); printf '[OK] %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '[AVISO] %s\n' "$1"; }
err() { ERR=$((ERR+1)); printf '[ERRO] %s\n' "$1"; }

for cmd in aws jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ERRO] $cmd nao encontrado"; exit 2; }
done

exec > >(tee "$REPORT") 2>&1

section "IDENTIDADE AWS"
IDENTITY="$(aws sts get-caller-identity --output json 2>&1)"
if jq -e '.Account and .Arn' >/dev/null 2>&1 <<< "$IDENTITY"; then
  echo "Account: $(jq -r '.Account' <<< "$IDENTITY")"
  echo "Caller: $(jq -r '.Arn' <<< "$IDENTITY")"
  ok "Credenciais AWS validas"
else
  echo "$IDENTITY"
  err "Credenciais AWS invalidas"
  exit 1
fi

section "LAMBDA"
LAMBDA_JSON="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --region "$AWS_REGION" --output json 2>&1)"
if ! jq -e '.FunctionName' >/dev/null 2>&1 <<< "$LAMBDA_JSON"; then
  echo "$LAMBDA_JSON"
  err "Nao foi possivel consultar a Lambda"
  exit 1
fi

L_STATE="$(jq -r '.State // ""' <<< "$LAMBDA_JSON")"
L_UPDATE="$(jq -r '.LastUpdateStatus // ""' <<< "$LAMBDA_JSON")"
L_ROLE="$(jq -r '.Role // ""' <<< "$LAMBDA_JSON")"
L_VPC="$(jq -r '.VpcConfig.VpcId // ""' <<< "$LAMBDA_JSON")"
L_SUBNETS="$(jq -r '.VpcConfig.SubnetIds // [] | join(",")' <<< "$LAMBDA_JSON")"
L_SGS="$(jq -r '.VpcConfig.SecurityGroupIds // [] | join(",")' <<< "$LAMBDA_JSON")"
DB_URL="$(jq -r '.Environment.Variables.DB_URL // ""' <<< "$LAMBDA_JSON")"

echo "State: $L_STATE"
echo "LastUpdateStatus: $L_UPDATE"
echo "Role: $L_ROLE"
echo "VpcId: $L_VPC"
echo "Subnets: $L_SUBNETS"
echo "SecurityGroups: $L_SGS"
echo "DB_URL: $DB_URL"

[[ "$L_STATE" == "Active" ]] && ok "Lambda ativa" || err "Lambda nao ativa"
[[ "$L_UPDATE" == "Successful" ]] && ok "Atualizacao da Lambda bem-sucedida" || warn "LastUpdateStatus=$L_UPDATE"
[[ -n "$L_VPC" ]] && ok "Lambda associada a VPC" || err "Lambda sem VPC"
[[ "$L_ROLE" == */LabRole ]] && ok "Lambda usa LabRole" || warn "Lambda nao usa LabRole"

DB_URL_HOST=""
DB_URL_PORT=""
if [[ "$DB_URL" =~ ^jdbc:postgresql://([^/:]+):([0-9]+)/([^/?]+)$ ]]; then
  DB_URL_HOST="${BASH_REMATCH[1]}"
  DB_URL_PORT="${BASH_REMATCH[2]}"
  ok "DB_URL valida"
else
  err "DB_URL invalida"
fi

section "RDS"
RDS_JSON="$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --region "$AWS_REGION" --query 'DBInstances[0]' --output json 2>&1)"
if ! jq -e '.DBInstanceIdentifier' >/dev/null 2>&1 <<< "$RDS_JSON"; then
  echo "$RDS_JSON"
  err "Nao foi possivel consultar o RDS"
  exit 1
fi

R_STATUS="$(jq -r '.DBInstanceStatus // ""' <<< "$RDS_JSON")"
R_ENDPOINT="$(jq -r '.Endpoint.Address // ""' <<< "$RDS_JSON")"
R_PORT="$(jq -r '.Endpoint.Port // ""' <<< "$RDS_JSON")"
R_VPC="$(jq -r '.DBSubnetGroup.VpcId // ""' <<< "$RDS_JSON")"
R_SUBNETS="$(jq -r '.DBSubnetGroup.Subnets | map(.SubnetIdentifier) | join(",")' <<< "$RDS_JSON")"
R_SGS="$(jq -r '.VpcSecurityGroups | map(.VpcSecurityGroupId) | join(",")' <<< "$RDS_JSON")"

echo "Status: $R_STATUS"
echo "Endpoint: $R_ENDPOINT"
echo "Port: $R_PORT"
echo "VpcId: $R_VPC"
echo "Subnets: $R_SUBNETS"
echo "SecurityGroups: $R_SGS"

[[ "$R_STATUS" == "available" ]] && ok "RDS disponivel" || err "RDS nao disponivel"
[[ "$R_PORT" == "$DB_PORT" ]] && ok "Porta do RDS correta" || err "Porta do RDS divergente"
[[ "$L_VPC" == "$R_VPC" ]] && ok "Lambda e RDS na mesma VPC" || err "Lambda e RDS em VPCs diferentes"
[[ "$DB_URL_HOST" == "$R_ENDPOINT" ]] && ok "DB_URL aponta para RDS atual" || err "DB_URL aponta para host diferente"
[[ "$DB_URL_PORT" == "$R_PORT" ]] && ok "DB_URL usa porta atual" || err "DB_URL usa porta diferente"

section "SECURITY GROUPS"
INGRESS=false
IFS=',' read -r -a RDS_SG_LIST <<< "$R_SGS"
IFS=',' read -r -a LAMBDA_SG_LIST <<< "$L_SGS"

for rsg in "${RDS_SG_LIST[@]}"; do
  [[ -n "$rsg" ]] || continue
  RULES="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$rsg" --region "$AWS_REGION" --output json 2>&1)"
  if ! jq -e '.SecurityGroupRules' >/dev/null 2>&1 <<< "$RULES"; then
    echo "$RULES"
    warn "Nao foi possivel consultar regras de $rsg"
    continue
  fi
  for lsg in "${LAMBDA_SG_LIST[@]}"; do
    [[ -n "$lsg" ]] || continue
    if jq -e --arg src "$lsg" --argjson port "$DB_PORT" '.SecurityGroupRules[] | select(.IsEgress == false and .IpProtocol == "tcp" and .FromPort <= $port and .ToPort >= $port and .ReferencedGroupInfo.GroupId == $src)' >/dev/null <<< "$RULES"; then
      ok "Ingress $rsg permite TCP $DB_PORT da Lambda SG $lsg"
      INGRESS=true
    fi
  done
done
[[ "$INGRESS" == "true" ]] || err "Ingress do RDS nao permite os SGs da Lambda"

EGRESS=false
for lsg in "${LAMBDA_SG_LIST[@]}"; do
  [[ -n "$lsg" ]] || continue
  RULES="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$lsg" --region "$AWS_REGION" --output json 2>&1)"
  if jq -e --argjson port "$DB_PORT" '.SecurityGroupRules[] | select(.IsEgress == true and (.IpProtocol == "-1" or (.IpProtocol == "tcp" and .FromPort <= $port and .ToPort >= $port)))' >/dev/null 2>&1 <<< "$RULES"; then
    ok "Egress $lsg permite TCP $DB_PORT"
    EGRESS=true
  fi
done
[[ "$EGRESS" == "true" ]] || err "Egress da Lambda nao permite TCP $DB_PORT"

section "SUBNETS E NACL"
ALL_SUBNETS="$(printf '%s\n%s\n' "${L_SUBNETS//,/\n}" "${R_SUBNETS//,/\n}" | sed '/^$/d' | sort -u)"
while IFS= read -r subnet; do
  [[ -n "$subnet" ]] || continue
  SUBNET_JSON="$(aws ec2 describe-subnets --subnet-ids "$subnet" --region "$AWS_REGION" --query 'Subnets[0].{VpcId:VpcId,AZ:AvailabilityZone,Cidr:CidrBlock}' --output json 2>&1)"
  echo "$subnet: $SUBNET_JSON"
  NACL_JSON="$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$subnet" --region "$AWS_REGION" --output json 2>&1)"
  if jq -e '.NetworkAcls[] | select(.IsDefault == true)' >/dev/null 2>&1 <<< "$NACL_JSON"; then
    ok "$subnet usa NACL default"
  else
    warn "$subnet usa NACL customizada ou consulta foi bloqueada"
    echo "$NACL_JSON"
  fi
done <<< "$ALL_SUBNETS"

section "LOGS RECENTES"
LOGS="$(aws logs tail "/aws/lambda/$FUNCTION_NAME" --region "$AWS_REGION" --since 5m --format short 2>&1)"
echo "$LOGS" | tail -n 100
if grep -q 'SocketTimeoutException: Connect timed out' <<< "$LOGS"; then
  err "Timeout TCP com PostgreSQL persiste"
elif grep -qi 'password authentication failed' <<< "$LOGS"; then
  err "Rede funciona, mas senha do PostgreSQL falhou"
elif grep -qi 'relation .* does not exist' <<< "$LOGS"; then
  err "Rede funciona, mas faltam tabelas ou schema"
else
  ok "Nenhum erro conhecido nos ultimos 5 minutos"
fi

section "DIAGNOSTICO"
if [[ "$L_VPC" != "$R_VPC" ]]; then
  echo "CORRECAO: alinhar VPC da Lambda e do RDS."
elif [[ "$INGRESS" != "true" ]]; then
  echo "CORRECAO: adicionar ingress TCP $DB_PORT no SG do RDS com origem no SG da Lambda."
elif [[ "$EGRESS" != "true" ]]; then
  echo "CORRECAO: liberar egress TCP $DB_PORT no SG da Lambda."
elif grep -q 'SocketTimeoutException: Connect timed out' <<< "$LOGS"; then
  echo "CORRECAO: SG e VPC estao consistentes; revisar NACLs e as subnets efetivas do DB subnet group."
else
  echo "Conectividade aparente correta. Refaça o curl e consulte logs novos."
fi

section "RESUMO"
echo "OK=$OK"
echo "AVISOS=$WARN"
echo "ERROS=$ERR"
echo "Relatorio=$REPORT"
[[ "$ERR" -eq 0 ]]
