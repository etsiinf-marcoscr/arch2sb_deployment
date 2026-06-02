#!/bin/bash
# =============================================================
# arch2sb.sh - Sandbox EC2 + Docker + CF
# =============================================================
#   /products*       -> EC2 products-api  :5000  (prio 10)
#   /create_report*  -> EC2 report-service:5001  (prio 20)
#   /bean_products*  -> EC2 report-service:5001  (prio 30)
#   /*               -> EC2 node-web-app  :3000  (default)
#
# CloudFront apunta al ALB en vez de a las EC2 directamente,
# exactamente igual que lo hace la versión ECS.
#
# Configuración previa:
#   1. Tener /resources y arch2.pem en el mismo nivel que este script
#   En caso de tener la clave de acceso a las EC2 otro nombre,
#   exportar la variable EC2_KEY_PAIR con el nombre del Key Pair (sin .pem)
#   2. export EMAIL="tu@email.com"
#   3. chmod +x arch2sb.sh && ./arch2sb.sh
# =============================================================
set -e

echo "============================================="
echo " Cafe EC2 + Docker + CF"
echo "============================================="

STACK_NAME="arch2sb"
REGION="us-east-1"
MYPASS="coffee_beans_for_all"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/resources"
KEY_PATH="$SCRIPT_DIR/arch2.pem"
TEMPLATE_FILE="$SCRIPT_DIR/arch2sb-deployment.yaml"
KEY_PAIR_NAME="${EC2_KEY_PAIR:-$(basename "$KEY_PATH" .pem)}"

if [ ! -d "$RESOURCES_DIR" ]; then
  echo "ERROR: no existe directorio de recursos en $RESOURCES_DIR"
  exit 1
fi

if [ ! -f "$KEY_PATH" ]; then
  echo "ERROR: no existe la llave PEM en $KEY_PATH"
  exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "ERROR: no existe el template CloudFormation en $TEMPLATE_FILE"
  exit 1
fi

chmod 400 "$KEY_PATH"

# ---------------------------------------------
# 0. Desplegar stack CloudFormation (si no existe)
# ---------------------------------------------
echo ""
echo ">>> Comprobando stack CloudFormation..."

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].StackStatus" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  echo "  Stack no existe, desplegando..."

  if [ -z "$EMAIL" ]; then
    echo 'ERROR: variable EMAIL no definida. Ejecuta: export EMAIL="tu@email.com"'
    exit 1
  fi

  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

  MAC=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/network/interfaces/macs/)

  VPC_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/vpc-id")

  SUBNET_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/subnet-id")

  echo "  VPC detectada:    $VPC_ID"
  echo "  Subnet detectada: $SUBNET_ID"
  echo "  KeyPair usada:    $KEY_PAIR_NAME"

  LAB_ROLE_ARN=$(aws iam get-role \
    --role-name "LabRole" \
    --query "Role.Arn" --output text)

  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE_FILE" \
    --parameters \
      ParameterKey=VpcId,ParameterValue="$VPC_ID" \
      ParameterKey=PublicSubnetOne,ParameterValue="$SUBNET_ID" \
      ParameterKey=StudentEmail,ParameterValue="$EMAIL" \
      ParameterKey=EC2KeyPair,ParameterValue="$KEY_PAIR_NAME" \
    --role-arn "$LAB_ROLE_ARN" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION"

  echo "  Stack lanzado, esperando CREATE_COMPLETE (puede tardar 8-15 min)..."
  aws cloudformation wait stack-create-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION"
  echo "  ✓ Stack desplegado"

elif [ "$STACK_STATUS" = "CREATE_COMPLETE" ] || \
     [ "$STACK_STATUS" = "UPDATE_COMPLETE" ]; then
  echo "  Stack ya existe y esta en estado $STACK_STATUS, continuando..."

else
  echo "ERROR: el stack existe pero esta en estado inesperado: $STACK_STATUS"
  echo "  Revisa la consola de CloudFormation antes de continuar."
  exit 1
fi

# ---------------------------------------------
# 1. Leer outputs del stack CloudFormation
# ---------------------------------------------
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text \
    --region "$REGION"
}

echo ">>> Leyendo outputs del stack..."
PRODUCTS_IP=$(get_output "EC2ProductsApiIP")
PRODUCTS_DNS=$(get_output "EC2ProductsApiDNS")
REPORT_IP=$(get_output "EC2ReportServiceIP")
REPORT_DNS=$(get_output "EC2ReportServiceDNS")
NODE_IP=$(get_output "EC2NodeWebAppIP")
CLOUDFRONT_URL=$(get_output "CloudFrontURL")
AURORA_ENDPOINT=$(get_output "AuroraEndpoint")
S3_WEB_BUCKET=$(get_output "S3WebBucket")
S3_REPORTS_BUCKET=$(get_output "S3ReportsBucket")
SNS_TOPIC_ARN=$(get_output "SNSEmailTopicArn")
SQS_QUEUE_URL=$(get_output "SQSInventoryQueueUrl")
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

DISTRO_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?Id=='S3-cafeOrigin']].Id" \
  --output text)
DISTRO_DOMAIN=$(echo "$CLOUDFRONT_URL" | sed 's|https://||')

echo "products-api:   http://$PRODUCTS_IP:5000"
echo "report-service: http://$REPORT_IP:5001"
echo "node-web-app:   http://$NODE_IP:3000"
echo "CloudFront:     $CLOUDFRONT_URL"
echo "CloudFront ID:  $DISTRO_ID"
echo "Aurora:         $AURORA_ENDPOINT"
echo "S3 web:         $S3_WEB_BUCKET"
echo "S3 reports:     $S3_REPORTS_BUCKET"
echo "SQS queue:      $SQS_QUEUE_URL"
echo "Cuenta:         $ACCOUNT_ID"

if [ -z "$PRODUCTS_IP" ] || [ -z "$REPORT_IP" ] || [ -z "$NODE_IP" ] || \
   [ -z "$DISTRO_ID" ] || [ -z "$AURORA_ENDPOINT" ]; then
  echo ""
  echo "ERROR: faltan variables críticas. Comprueba los outputs del stack."
  exit 1
fi

# ---------------------------------------------
# 2. Instalar dependencias en el bastión
# ---------------------------------------------
echo ""
echo ">>> Instalando dependencias en el bastión..."
sudo dnf install -y docker mariadb105 git python3-pip
pip3 install boto3
sudo systemctl start docker
sudo systemctl enable docker
sudo chmod 666 /var/run/docker.sock

# ---------------------------------------------
# 3. Asignar LabInstanceProfile a las EC2
# ---------------------------------------------
echo ""
echo ">>> Asignando LabInstanceProfile a las EC2..."

get_instance_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text \
    --region "$REGION"
}

PRODUCTS_INSTANCE=$(get_instance_id "cafe-products-api")
REPORT_INSTANCE=$(get_instance_id "cafe-report-service")
NODE_INSTANCE=$(get_instance_id "cafe-node-web-app")

echo "  products-api:   $PRODUCTS_INSTANCE"
echo "  report-service: $REPORT_INSTANCE"
echo "  node-web-app:   $NODE_INSTANCE"

for INSTANCE_ID in "$PRODUCTS_INSTANCE" "$REPORT_INSTANCE" "$NODE_INSTANCE"; do
  CURRENT=$(aws ec2 describe-iam-instance-profile-associations \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query "IamInstanceProfileAssociations[0].AssociationId" \
    --output text 2>/dev/null || echo "None")

  if [ "$CURRENT" = "None" ] || [ -z "$CURRENT" ]; then
    aws ec2 associate-iam-instance-profile \
      --instance-id "$INSTANCE_ID" \
      --iam-instance-profile Name=LabInstanceProfile
    echo "  $INSTANCE_ID -> LabInstanceProfile asignado"
  else
    echo "  $INSTANCE_ID -> ya tiene Instance Profile, saltando"
  fi
done

# ---------------------------------------------
# run_remote - ejecuta comandos por SSH
# ---------------------------------------------
run_remote() {
  local IP="$1"
  local CMD="$2"
  local LABEL="${3:-comando}"
  echo "  -> SSH a $IP: $LABEL"
  ssh -i "$KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o ServerAliveInterval=10 \
      ec2-user@"$IP" \
      "$CMD"
  local EXIT=$?
  if [ $EXIT -eq 0 ]; then
    echo "  ✓ $LABEL completado"
  else
    echo "  ✗ $LABEL falló (exit $EXIT)"
    return 1
  fi
}

# ---------------------------------------------
# 4. Login ECR
# ---------------------------------------------
echo ""
echo ">>> Login en ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_BASE"

# ---------------------------------------------
# 5. Build y push - node-web-app
# ---------------------------------------------
echo ""
echo ">>> Build node-web-app..."
cd "$RESOURCES_DIR/codebase_partner"

cat > Dockerfile <<'DOCKERFILE'
FROM node:11-alpine
RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app
COPY . .
RUN npm install
EXPOSE 3000
CMD ["npm", "run", "start"]
DOCKERFILE

docker build --tag cafe/node-web-app .
docker tag cafe/node-web-app:latest "${ECR_BASE}/cafe/node-web-app:latest"
docker push "${ECR_BASE}/cafe/node-web-app"

# ---------------------------------------------
# 6. Build y push - products-api (Flask)
# ---------------------------------------------
echo ""
echo ">>> Build products-api..."
cd "$RESOURCES_DIR/products_api"
docker build --tag cafe/products-api .
docker tag cafe/products-api:latest "${ECR_BASE}/cafe/products-api:latest"
docker push "${ECR_BASE}/cafe/products-api"

# ---------------------------------------------
# 7. Build y push - report-service (Flask)
# ---------------------------------------------
echo ""
echo ">>> Build report-service..."
cd "$RESOURCES_DIR/report_service"
docker build --tag cafe/report-service .
docker tag cafe/report-service:latest "${ECR_BASE}/cafe/report-service:latest"
docker push "${ECR_BASE}/cafe/report-service"

# ---------------------------------------------
# 8. Poblar Aurora
# ---------------------------------------------
echo ""
echo ">>> Poblando Aurora RDS..."

mysql -h "$AURORA_ENDPOINT" -P 3306 -u admin -p"$MYPASS" <<EOF
CREATE USER IF NOT EXISTS 'nodeapp' IDENTIFIED WITH mysql_native_password BY 'coffee';
CREATE DATABASE IF NOT EXISTS COFFEE;
GRANT ALL PRIVILEGES ON COFFEE.* TO 'nodeapp'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES,
  INDEX, ALTER, SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE,
  REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW,
  CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER
  ON *.* TO 'nodeapp'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

mysql -h "$AURORA_ENDPOINT" -P 3306 -u admin -p"$MYPASS" COFFEE \
  < "$RESOURCES_DIR/coffee_db_dump.sql"
echo "Aurora poblada."

# ---------------------------------------------
# 9. Poblar DynamoDB
# ---------------------------------------------
echo ""
echo ">>> Poblando DynamoDB con productos..."
python3 "$RESOURCES_DIR/seed.py"
echo "DynamoDB poblado."

# ---------------------------------------------
# 10. Obtener endpoint Memcached
# ---------------------------------------------
MEMC_HOST=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "Memcached" \
  --show-cache-node-info \
  --query "CacheClusters[0].CacheNodes[0].Endpoint.Address" \
  --output text \
  --region "$REGION")
echo "Memcached: $MEMC_HOST"

# ---------------------------------------------
# 11. Arrancar contenedores en las EC2 via SSH
# ---------------------------------------------
echo ""
echo ">>> Arrancando contenedores en las EC2..."

run_remote "$PRODUCTS_IP" \
  "sudo chmod 666 /var/run/docker.sock; \
   aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR_BASE} && \
   docker pull ${ECR_BASE}/cafe/products-api:latest && \
   docker stop products-api 2>/dev/null || true && \
   docker rm   products-api 2>/dev/null || true && \
   docker run -d --name products-api --restart always \
     -p 5000:5000 \
     -e AWS_DEFAULT_REGION=${REGION} \
     -e DYNAMODB_TABLE=FoodProducts \
     -e DYNAMODB_INDEX=special_GSI \
     ${ECR_BASE}/cafe/products-api:latest" \
  "products-api docker run"

run_remote "$REPORT_IP" \
  "sudo chmod 666 /var/run/docker.sock; \
   aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR_BASE} && \
   docker pull ${ECR_BASE}/cafe/report-service:latest && \
   docker stop report-service 2>/dev/null || true && \
   docker rm   report-service 2>/dev/null || true && \
   docker run -d --name report-service --restart always \
     -p 5001:5000 \
     -e AWS_DEFAULT_REGION=${REGION} \
     -e REPORT_BUCKET_NAME=${S3_REPORTS_BUCKET} \
     -e SNS_TOPIC_ARN=${SNS_TOPIC_ARN} \
     -e REPORT_KEY=report.html \
     -e PRESIGNED_EXPIRY_SECONDS=3600 \
     -e DB_HOST=${AURORA_ENDPOINT} \
     -e DB_USER=admin \
     -e DB_PASSWORD=${MYPASS} \
     -e DB_NAME=COFFEE \
     ${ECR_BASE}/cafe/report-service:latest" \
  "report-service docker run"

run_remote "$NODE_IP" \
  "sudo chmod 666 /var/run/docker.sock; \
   aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR_BASE} && \
   docker pull ${ECR_BASE}/cafe/node-web-app:latest && \
   docker stop node-web-app 2>/dev/null || true && \
   docker rm   node-web-app 2>/dev/null || true && \
   docker run -d --name node-web-app --restart always \
     -p 3000:3000 \
     -e APP_DB_HOST=${AURORA_ENDPOINT} \
     -e MEMC_HOST=${MEMC_HOST}:11211 \
     ${ECR_BASE}/cafe/node-web-app:latest" \
  "node-web-app docker run"

# ---------------------------------------------
# SQS worker (en background sobre la EC2 de report)
# ---------------------------------------------
echo ""
echo ">>> Desplegando sqs_worker..."

scp -i "$KEY_PATH" \
  "$RESOURCES_DIR/report_service/sqs_worker.py" \
    ec2-user@${REPORT_IP}:/home/ec2-user/sqs_worker.py

run_remote "$REPORT_IP" "pip3 install boto3 pymysql pymemcache" "pip3 install worker deps"

run_remote "$REPORT_IP" \
  "SQS_QUEUE_URL=${SQS_QUEUE_URL} \
   DB_HOST=${AURORA_ENDPOINT} \
   DB_USER=admin \
   DB_PASSWORD=${MYPASS} \
   DB_NAME=COFFEE \
   AWS_DEFAULT_REGION=${REGION} \
   MEMC_HOST=${MEMC_HOST}:11211 \
   nohup python3 /home/ec2-user/sqs_worker.py > /home/ec2-user/worker.log 2>&1 &
   echo Worker PID: \$!" \
  "sqs_worker start"

# ---------------------------------------------
# 12. Obtener VPC y SGs del stack para el ALB
# ---------------------------------------------
echo ""
echo ">>> Obteniendo VPC y SGs del stack..."

VPC_ID=$(aws ec2 describe-instances \
  --instance-ids "$PRODUCTS_INSTANCE" \
  --query "Reservations[0].Instances[0].VpcId" \
  --output text)

# Reutilizamos el SG que ya abre los puertos de las EC2 (EC2SecurityGroup)
EC2_SG=$(aws ec2 describe-instances \
  --instance-ids "$PRODUCTS_INSTANCE" \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
  --output text)

# Subnets públicas donde viven las EC2 (necesitamos al menos 2 AZs para el ALB)
SUBNET_1=$(aws ec2 describe-instances \
  --instance-ids "$PRODUCTS_INSTANCE" \
  --query "Reservations[0].Instances[0].SubnetId" \
  --output text)

# La segunda subnet la saca del stack (ExtraSubnet está en AZ2)
SUBNET_2=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" \
  --query "StackResources[?LogicalResourceId=='ExtraSubnet'].PhysicalResourceId" \
  --output text)

echo "  VPC:      $VPC_ID"
echo "  SG EC2:   $EC2_SG"
echo "  Subnet1:  $SUBNET_1"
echo "  Subnet2:  $SUBNET_2"

# ---------------------------------------------
# 12b. Asociar la route table pública a ExtraSubnet
#
# ExtraSubnet tiene MapPublicIpOnLaunch=true pero
# CloudFormation no le asigna automáticamente la
# route table pública (la que tiene la ruta al IGW).
# Sin esto el ALB en AZ2 no tiene salida a internet
# y CloudFront recibe 504 en ~50% de las peticiones.
# ---------------------------------------------
echo ""
echo ">>> Asociando route table pública a ExtraSubnet (AZ2)..."

RT_PUBLIC=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=route.destination-cidr-block,Values=0.0.0.0/0" \
  --query "RouteTables[0].RouteTableId" \
  --output text)

echo "  Route table pública: $RT_PUBLIC"

# Comprobar si ya está asociada para no duplicar
RT_ASSOC=$(aws ec2 describe-route-tables \
  --route-table-ids "$RT_PUBLIC" \
  --query "RouteTables[0].Associations[?SubnetId=='${SUBNET_2}'].RouteTableAssociationId" \
  --output text 2>/dev/null)

if [ -z "$RT_ASSOC" ] || [ "$RT_ASSOC" = "None" ]; then
  aws ec2 associate-route-table \
    --subnet-id "$SUBNET_2" \
    --route-table-id "$RT_PUBLIC"
  echo "  ✓ ExtraSubnet asociada a la route table pública"
else
  echo "  ExtraSubnet ya tiene la asociación correcta (saltando)"
fi
# ---------------------------------------------
echo ""
echo ">>> Creando SG del ALB..."

ALB_SG=$(aws ec2 create-security-group \
  --group-name "cafe-alb-sg" \
  --description "ALB compartido cafe sandbox" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

echo "  ALB SG: $ALB_SG"

# ---------------------------------------------
# 14. ALB
# ---------------------------------------------
echo ""
echo ">>> Creando ALB compartido..."

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "cafe-shared-alb" \
  --subnets "$SUBNET_1" "$SUBNET_2" \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" \
  --output text)

echo "  ALB ARN: $ALB_ARN"
echo "  ALB DNS: $ALB_DNS"

# ---------------------------------------------
# 15. Target Groups
# ---------------------------------------------
echo ""
echo ">>> Creando Target Groups..."

TG_PRODUCTS=$(aws elbv2 create-target-group \
  --name "cafe-products-tg" \
  --protocol HTTP --port 5000 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path "/products" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

TG_REPORT=$(aws elbv2 create-target-group \
  --name "cafe-report-tg" \
  --protocol HTTP --port 5001 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --matcher HttpCode="200-499" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

TG_NODE=$(aws elbv2 create-target-group \
  --name "cafe-node-tg" \
  --protocol HTTP --port 3000 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

echo "  TG products: $TG_PRODUCTS"
echo "  TG report:   $TG_REPORT"
echo "  TG node:     $TG_NODE"

# ---------------------------------------------
# 16. Registrar IPs privadas en los TGs
# ---------------------------------------------
echo ""
echo ">>> Registrando IPs privadas de las EC2..."

PRODUCTS_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids "$PRODUCTS_INSTANCE" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

REPORT_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids "$REPORT_INSTANCE" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

NODE_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids "$NODE_INSTANCE" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

echo "  products-api   $PRODUCTS_PRIVATE_IP"
echo "  report-service $REPORT_PRIVATE_IP"
echo "  node-web-app   $NODE_PRIVATE_IP"

aws elbv2 register-targets \
  --target-group-arn "$TG_PRODUCTS" \
  --targets "Id=${PRODUCTS_PRIVATE_IP},Port=5000"

aws elbv2 register-targets \
  --target-group-arn "$TG_REPORT" \
  --targets "Id=${REPORT_PRIVATE_IP},Port=5001"

aws elbv2 register-targets \
  --target-group-arn "$TG_NODE" \
  --targets "Id=${NODE_PRIVATE_IP},Port=3000"

echo "  ✓ Targets registrados"

# ---------------------------------------------
# 17. Listener HTTP:80 y rules por ruta
# ---------------------------------------------
echo ""
echo ">>> Creando Listener y reglas..."

LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_NODE}" \
  --query "Listeners[0].ListenerArn" \
  --output text)

echo "  Listener: $LISTENER_ARN"

aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions "Field=path-pattern,Values='/products*'" \
  --actions "Type=forward,TargetGroupArn=${TG_PRODUCTS}" \
  --query "Rules[0].RuleArn" --output text

aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 20 \
  --conditions "Field=path-pattern,Values='/create_report*'" \
  --actions "Type=forward,TargetGroupArn=${TG_REPORT}" \
  --query "Rules[0].RuleArn" --output text

aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 30 \
  --conditions "Field=path-pattern,Values='/bean_products*'" \
  --actions "Type=forward,TargetGroupArn=${TG_REPORT}" \
  --query "Rules[0].RuleArn" --output text

echo "  ✓ Reglas creadas"

# ---------------------------------------------
# 18. Actualizar CloudFront para apuntar al ALB
#     en vez de a las EC2 directamente
# ---------------------------------------------
echo ""
echo ">>> Actualizando distribución CloudFront para usar el ALB..."

# Actualizar CloudFront via Python: sustituir los dos origins de EC2
# por un único "alb-origin" y redirigir los CacheBehaviors.
# La API update_distribution exige campos que get_distribution_config
# puede devolver vacíos o ausentes (OriginPath, CustomHeaders, OriginShield…).
# normalize_origin() los rellena con sus valores por defecto para evitar
# errores.
python3 - "$ALB_DNS" "$DISTRO_ID" <<'PYEOF'
import sys, boto3

alb_dns   = sys.argv[1]
distro_id = sys.argv[2]
cf = boto3.client("cloudfront")

resp   = cf.get_distribution_config(Id=distro_id)
etag   = resp["ETag"]
config = resp["DistributionConfig"]

def normalize_origin(o):
    """Rellena los campos que la API exige aunque estén vacíos."""
    o.setdefault("OriginPath", "")
    o.setdefault("ConnectionAttempts", 3)
    o.setdefault("ConnectionTimeout", 10)
    o.setdefault("OriginShield", {"Enabled": False})
    o.setdefault("CustomHeaders", {"Quantity": 0, "Items": []})
    if "CustomOriginConfig" in o:
        coc = o["CustomOriginConfig"]
        coc.setdefault("OriginReadTimeout", 30)
        coc.setdefault("OriginKeepaliveTimeout", 5)
        ssl = coc.setdefault("OriginSslProtocols", {"Items": ["TLSv1.2"]})
        ssl["Quantity"] = len(ssl["Items"])
    return o

# Localizar y normalizar el origen S3
s3_origin = next(o for o in config["Origins"]["Items"] if o["Id"] == "S3-cafeOrigin")
normalize_origin(s3_origin)

# Construir el nuevo origen ALB completamente especificado
alb_origin = normalize_origin({
    "Id": "alb-origin",
    "DomainName": alb_dns,
    "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only",
        "OriginSslProtocols": {"Items": ["TLSv1.2"]},
    },
})

config["Origins"]["Items"]    = [s3_origin, alb_origin]
config["Origins"]["Quantity"] = 2

# Redirigir los CacheBehaviors de EC2 al nuevo ALB origin
EC2_ORIGINS = {"products-api-origin", "report-service-origin"}
for cb in config.get("CacheBehaviors", {}).get("Items", []):
    if cb["TargetOriginId"] in EC2_ORIGINS:
        cb["TargetOriginId"] = "alb-origin"

cf.update_distribution(
    DistributionConfig=config,
    Id=distro_id,
    IfMatch=etag,
)
print("CloudFront actualizado correctamente.")
PYEOF

# ---------------------------------------------
# 19. Configurar config.js
# ---------------------------------------------
echo ""
echo ">>> Configurando config.js..."

USER_POOL_ID=$(aws cognito-idp list-user-pools \
  --max-results 1 --query "UserPools[0].Id" --output text)
COGNITO_CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
  --user-pool-id "$USER_POOL_ID" --max-results 1 \
  --query "UserPoolClients[0].ClientId" --output text)
COGNITO_DOMAIN=$(aws cognito-idp describe-user-pool \
  --user-pool-id "$USER_POOL_ID" \
  --query "UserPool.Domain" --output text)

COGNITO_LOGIN_URL="https://${COGNITO_DOMAIN}.auth.${REGION}.amazoncognito.com/login?client_id=${COGNITO_CLIENT_ID}&response_type=token&scope=email+openid&redirect_uri=https://${DISTRO_DOMAIN}/callback.html"

cat > "$RESOURCES_DIR/website/config.js" << EOF
window.COFFEE_CONFIG = {
        API_GW_BASE_URL_STR: "https://${DISTRO_DOMAIN}",
        API_GW_REPORT_URL_STR: "https://${DISTRO_DOMAIN}",
        COGNITO_LOGIN_BASE_URL_STR: "${COGNITO_LOGIN_URL}"
}
EOF

echo "config.js actualizado:"
cat "$RESOURCES_DIR/website/config.js"

# ---------------------------------------------
# 20. Crear usuario Cognito "frank"
# ---------------------------------------------
echo ""
echo ">>> Creando usuario Cognito 'frank'..."

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "frank" \
  --message-action SUPPRESS \
  --temporary-password '!CoffeeIsGreat34' \
  --user-attributes \
      Name=email,Value="$EMAIL" \
      Name=email_verified,Value=true \
  2>/dev/null && echo "  Usuario frank creado" || echo "  frank ya existe, continuando"

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "frank" \
  --password '!CoffeeIsGreat35' \
  --permanent
echo "  Contraseña permanente establecida"

# ---------------------------------------------
# 21. Política S3 para CloudFront OAI
# ---------------------------------------------
echo ""
echo ">>> Aplicando política S3 para CloudFront OAI..."

OAI_ID=$(aws cloudfront list-cloud-front-origin-access-identities \
  --query "CloudFrontOriginAccessIdentityList.Items[?Comment=='access-identity-cafe-website'].Id" \
  --output text)

aws s3api put-bucket-policy \
  --bucket "$S3_WEB_BUCKET" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"AllowCloudFrontOAI\",
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"AWS\": \"arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${OAI_ID}\"
      },
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::${S3_WEB_BUCKET}/*\"
    }]
  }"
echo "  Política S3 aplicada."

# ---------------------------------------------
# 22. Subir web a S3
# ---------------------------------------------
echo ""
echo ">>> Subiendo web estática a S3..."
aws s3 cp "$RESOURCES_DIR/website" "s3://$S3_WEB_BUCKET/" \
  --recursive \
  --cache-control "max-age=0" \
  --region "$REGION"
echo "Web subida."

# ---------------------------------------------
# 23. Invalidar caché CloudFront
# ---------------------------------------------
echo ""
echo ">>> Invalidando caché CloudFront..."
aws cloudfront create-invalidation \
  --distribution-id "$DISTRO_ID" \
  --paths "/*" \
  --query "Invalidation.Id" \
  --output text
echo "  Caché invalidado (puede tardar 1-2 min en propagarse)."

echo ""
echo "============================================="
echo " Despliegue completado"
echo "============================================="
echo ""
echo " Web (CloudFront): $CLOUDFRONT_URL"
echo "   -> puede tardar 3-5 min en propagar los cambios de CF"
echo ""
echo " Rutas via CloudFront -> ALB -> EC2:"
echo "   productos:   https://$DISTRO_DOMAIN/products"
echo "   oferta:      https://$DISTRO_DOMAIN/products/on_offer"
echo "   reporte:     https://$DISTRO_DOMAIN/create_report"
echo "   web:         https://$DISTRO_DOMAIN/"
echo ""
echo " Debug directo contra el ALB (sin CloudFront):"
echo "   productos:   http://$ALB_DNS/products"
echo "   reporte:     http://$ALB_DNS/create_report"
echo "   node:        http://$ALB_DNS/"
echo ""
echo " Debug directo contra las EC2 (sin ALB):"
echo "   products-api:   http://$PRODUCTS_IP:5000/products"
echo "   report-service: http://$REPORT_IP:5001/create_report"
echo "   node-web-app:   http://$NODE_IP:3000"
echo ""
echo " Cognito usuario: frank / !CoffeeIsGreat35"
echo " Confirma el email de SNS en tu bandeja."
echo "============================================="