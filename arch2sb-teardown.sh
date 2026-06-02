#!/bin/bash
# =============================================================
# arch2sb-teardown.sh - Limpieza completa del stack cafe
# =============================================================
# Orden de operaciones:
#   TODO: 0. Borrar el ALB para poder borrar luego los TGs
#   1. Vaciar bucket S3 de reportes y web (antes de borrar el stack)
#   2. Borrar el stack CloudFormation y esperar
#   3. Borrar los Target Groups huérfanos (DeletionPolicy: Retain)
# =============================================================
set -e

STACK_NAME="arch2sb"
REGION="us-east-1"
ALB_NAME="cafe-shared-alb"

echo "============================================="
echo " Cafe Adaptacion Sandbox - Teardown"
echo "============================================="

# ---------------------------------------------
# Helpers
# ---------------------------------------------
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text \
    --region "$REGION" 2>/dev/null
}

# ---------------------------------------------
# Comprobar que el stack existe
# ---------------------------------------------
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].StackStatus" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  echo "El stack '$STACK_NAME' no existe. Nada que borrar."
  exit 0
fi

echo "Stack encontrado en estado: $STACK_STATUS"

# ---------------------------------------------
# 0. Borrar el ALB compartido
# ---------------------------------------------
echo ""
echo ">>> Eliminando ALB compartido..."

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[].ListenerArn" \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

  if [ -n "$LISTENER_ARNS" ] && [ "$LISTENER_ARNS" != "None" ]; then
    for LISTENER_ARN in $LISTENER_ARNS; do
      aws elbv2 delete-listener \
        --listener-arn "$LISTENER_ARN" \
        --region "$REGION"
      echo "  ✓ Listener borrado: $LISTENER_ARN"
    done
  else
    echo "  No se encontraron listeners para el ALB (continuando)"
  fi

  aws elbv2 delete-load-balancer \
    --load-balancer-arn "$ALB_ARN" \
    --region "$REGION"
  echo "  ALB '$ALB_NAME' eliminado, esperando..."
  aws elbv2 wait load-balancers-deleted \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION"
  echo "  ✓ ALB eliminado"
else
  echo "  ALB '$ALB_NAME' no encontrado (ya borrado o nunca creado)"
fi


# ---------------------------------------------
# 1. Vaciar bucket S3 antes de borrar el stack
# ---------------------------------------------
echo ""
echo ">>> Vaciando bucket S3 de reportes..."

S3_REPORTS_BUCKET=$(get_output "S3ReportsBucket")
S3_WEB_BUCKET=$(get_output "S3WebBucket")

if [ -n "$S3_REPORTS_BUCKET" ] && [ "$S3_REPORTS_BUCKET" != "None" ]; then
  echo "  Bucket: $S3_REPORTS_BUCKET"
  # Borrar objetos normales
  aws s3 rm "s3://${S3_REPORTS_BUCKET}" --recursive --region "$REGION" \
    && echo "  ✓ Objetos borrados" || echo "  (bucket ya vacío o sin objetos)"
  # Borrar versiones si el bucket tiene versionado
  aws s3api list-object-versions \
    --bucket "$S3_REPORTS_BUCKET" \
    --region "$REGION" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null | \
  python3 -c "
import sys, json, boto3
data = json.load(sys.stdin)
objs = data.get('Objects') or []
if objs:
    boto3.client('s3').delete_objects(
        Bucket='${S3_REPORTS_BUCKET}',
        Delete={'Objects': objs}
    )
    print('  ✓ Versiones borradas')
" 2>/dev/null || true
  echo "  ✓ Bucket vaciado"
else
  echo "  No se encontró el bucket en los outputs del stack (saltando)"
fi

# Vaciar bucket web (si existe y no es el mismo que el de reports)
if [ -n "$S3_WEB_BUCKET" ] && [ "$S3_WEB_BUCKET" != "None" ]; then
  if [ "$S3_WEB_BUCKET" = "$S3_REPORTS_BUCKET" ]; then
    echo "  Bucket web es el mismo que el de reportes (ya vaciado), saltando"
  else
    echo "  Bucket web: $S3_WEB_BUCKET"
    aws s3 rm "s3://${S3_WEB_BUCKET}" --recursive --region "$REGION" \
      && echo "  ✓ Objetos web borrados" || echo "  (bucket web ya vacío o sin objetos)"
    aws s3api list-object-versions \
      --bucket "$S3_WEB_BUCKET" \
      --region "$REGION" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null | \
    python3 -c "
import sys, json, boto3
data = json.load(sys.stdin)
objs = data.get('Objects') or []
if objs:
    boto3.client('s3').delete_objects(
        Bucket='${S3_WEB_BUCKET}',
        Delete={'Objects': objs}
    )
    print('  ✓ Versiones web borradas')
" 2>/dev/null || true
    echo "  ✓ Bucket web vaciado"
  fi
else
  echo "  No se encontró el bucket web en los outputs del stack (saltando)"
fi

# ---------------------------------------------
# 2. Borrar el stack y esperar
# ---------------------------------------------
echo ""
echo ">>> Eliminando stack CloudFormation '$STACK_NAME'..."

aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "  Esperando DELETE_COMPLETE (puede tardar 12-18 min)..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "  ✓ Stack eliminado"

# ---------------------------------------------
# 3. Borrar Target Groups huérfanos (Retain)
# ---------------------------------------------
echo ""
echo ">>> Eliminando Target Groups huérfanos..."

for TG_NAME in cafe-node-tg cafe-products-tg cafe-report-tg; do

  TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    aws elbv2 delete-target-group \
      --target-group-arn "$TG_ARN" \
      --region "$REGION"
    echo "  ✓ $TG_NAME borrado"
  else
    echo "  $TG_NAME no encontrado (ya borrado o nunca creado)"
  fi
done

echo ""
echo "============================================="
echo " Teardown completado"
echo " IMPORTANTE: Recuerde borrar esta instancia EC2 y por ultimo eliminar la VPC 10.0.0.0/16"
echo "============================================="