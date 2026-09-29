#!/usr/bin/env bash
# Rebuild the CrisisMonitor images and redeploy them.
#
#   deploy/deploy.sh aws     # model + backend + frontend + MongoDB on the EC2 host
#   deploy/deploy.sh azure   # backend + frontend on Azure App Service (uses AWS model + MongoDB)
#   deploy/deploy.sh all     # both, AWS first
#
# Needs: docker (buildx), aws CLI logged in; for azure also az CLI + docker hub login.
# Secrets are read from SSM Parameter Store (/crisismonitor/*), never from this repo.
# One-time setup: deploy/setup-once.sh
set -euo pipefail

# ---- config (override via env) ----
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-303936065814}"
EC2_INSTANCE_ID="${EC2_INSTANCE_ID:-i-04900afc624c386ab}"
EC2_PUBLIC_IP="${EC2_PUBLIC_IP:-32.199.57.44}"          # Elastic IP
EC2_SECURITY_GROUP="${EC2_SECURITY_GROUP:-sg-0099f760cbf7a837a}"
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-crisismonitor_group}"
AZ_BACKEND_APP="${AZ_BACKEND_APP:-crisismonitor-backend-alice}"
AZ_FRONTEND_APP="${AZ_FRONTEND_APP:-crisismonitor-frontend-alice}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-excila}"

ECR="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${TAG:-}" ]; then
  TAG="$(git -C "$ROOT" rev-parse --short HEAD)"
  [ -n "$(git -C "$ROOT" status --porcelain -- backend frontend model deploy)" ] && TAG="$TAG-dev$(date +%s)"
fi

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Read a SecureString from Parameter Store and mask it in GitHub Actions logs.
param() {
  local v
  v="$(aws ssm get-parameter --region "$AWS_REGION" --name "/crisismonitor/$1" --with-decryption \
        --query Parameter.Value --output text 2>/dev/null)" \
    || die "SSM parameter /crisismonitor/$1 missing - run deploy/setup-once.sh"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$v" >&2
  printf '%s' "$v"
}

# build <context-dir> <image:tag> [extra buildx args...]  (always linux/amd64, pushes)
build() {
  local ctx="$1" image="$2"; shift 2
  local cache=()
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    local scope="$ctx-${image%%/*}"   # e.g. frontend-docker.io (frontend build args differ per cloud)
    cache=(--cache-from "type=gha,scope=$scope" --cache-to "type=gha,mode=max,scope=$scope")
  fi
  log "Building $image"
  docker buildx build --platform linux/amd64 --push ${cache[@]+"${cache[@]}"} "$@" -t "$image" "$ROOT/$ctx"
}

# wait_http <url> <timeout-seconds> [expected-body-substring]
wait_http() {
  local url="$1" timeout="$2" want="${3:-}" start=$SECONDS body
  while (( SECONDS - start < timeout )); do
    if body="$(curl -fsS -m 10 "$url" 2>/dev/null)" && [[ -z "$want" || "$body" == *"$want"* ]]; then
      echo "  ok  $url"; return 0
    fi
    sleep 10
  done
  echo "  FAIL $url (last body: ${body:-none})"; return 1
}

deploy_aws() {
  log "AWS: tag $TAG -> $ECR"
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR" >/dev/null
  for repo in crisismonitor-model crisismonitor-backend crisismonitor-frontend; do
    aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo" >/dev/null 2>&1 \
      || aws ecr create-repository --region "$AWS_REGION" --repository-name "$repo" >/dev/null
  done

  build model   "$ECR/crisismonitor-model:$TAG"
  build backend "$ECR/crisismonitor-backend:$TAG"
  build frontend "$ECR/crisismonitor-frontend:$TAG" --build-arg "NEXT_PUBLIC_API_URL=http://$EC2_PUBLIC_IP:8000"

  log "AWS: rolling out on $EC2_INSTANCE_ID via SSM"
  local compose_b64 remote cmd_id status
  compose_b64="$(base64 < "$ROOT/deploy/docker-compose.yml" | tr -d '\n')"
  remote=$(cat <<EOF
set -euo pipefail
export AWS_DEFAULT_REGION=$AWS_REGION
mkdir -p /opt/crisismonitor && cd /opt/crisismonitor

# 2 GB swap so the model fits alongside everything else on a t3.small
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

command -v docker >/dev/null || dnf install -y docker
systemctl enable --now docker
if ! docker compose version >/dev/null 2>&1; then
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

echo "$compose_b64" | base64 -d > docker-compose.yml
get() { aws ssm get-parameter --name "/crisismonitor/\$1" --with-decryption --query Parameter.Value --output text; }
umask 077
cat > .env <<ENV
REGISTRY=$ECR
TAG=$TAG
MONGO_ROOT_PASSWORD=\$(get MONGO_ROOT_PASSWORD)
WANDB_API_KEY=\$(get WANDB_API_KEY)
ENV

aws ecr get-login-password | docker login --username AWS --password-stdin $ECR
docker rm -f backend frontend >/dev/null 2>&1 || true   # containers from the original user-data launch
docker compose pull -q
docker compose up -d --remove-orphans
docker image prune -af >/dev/null
docker compose ps

# The model downloads its weights from W&B on startup; wait until it can serve.
for i in \$(seq 1 60); do
  curl -fsS -m 5 localhost:8001/ready 2>/dev/null | grep -q true && { echo "model ready"; exit 0; }
  sleep 10
done
echo "model not ready after 10 min"; docker compose logs --tail 60 model; exit 1
EOF
)
  cmd_id="$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$EC2_INSTANCE_ID" \
      --document-name AWS-RunShellScript --comment "crisismonitor deploy $TAG" --timeout-seconds 600 \
      --parameters "$(jq -n --arg c "$remote" '{commands: [$c], executionTimeout: ["1800"]}')" \
      --query Command.CommandId --output text)"
  echo "  SSM command $cmd_id"
  while :; do
    sleep 10
    status="$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" \
        --instance-id "$EC2_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in Pending|InProgress|Delayed) continue ;; esac
    break
  done
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$EC2_INSTANCE_ID" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -40
  [ "$status" = Success ] || die "remote deploy $status"

  log "AWS: health checks"
  wait_http "http://$EC2_PUBLIC_IP:8000/health" 180 ok
  wait_http "http://$EC2_PUBLIC_IP/" 120
  echo "AWS frontend: http://$EC2_PUBLIC_IP"
}

deploy_azure() {
  local backend_url="https://$AZ_BACKEND_APP.azurewebsites.net"
  log "Azure: tag $TAG -> docker.io/$DOCKERHUB_NAMESPACE"
  build backend  "docker.io/$DOCKERHUB_NAMESPACE/crisismonitor-backend:$TAG"
  build frontend "docker.io/$DOCKERHUB_NAMESPACE/crisismonitor-frontend:$TAG" --build-arg "NEXT_PUBLIC_API_URL=$backend_url"

  log "Azure: allow backend outbound IPs to reach model (8001) + MongoDB (27017) on EC2"
  local ips ip port
  ips="$(az webapp show -g "$AZ_RESOURCE_GROUP" -n "$AZ_BACKEND_APP" --query outboundIpAddresses -o tsv | tr ',' ' ')"
  for ip in $ips; do
    for port in 8001 27017; do
      aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$EC2_SECURITY_GROUP" \
        --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=$ip/32,Description=azure-backend}]" \
        >/dev/null 2>&1 || true   # already present
    done
  done

  log "Azure: configure + roll out web apps"
  local mongo_pw; mongo_pw="$(param MONGO_ROOT_PASSWORD)"
  az webapp config appsettings set -g "$AZ_RESOURCE_GROUP" -n "$AZ_BACKEND_APP" --output none --settings \
    MODEL_SERVICE_HOST="$EC2_PUBLIC_IP" MODEL_SERVICE_PORT=8001 MONGO_DB=mlapp WEBSITES_PORT=80 PORT=80 \
    MONGO_URI="mongodb://root:$mongo_pw@$EC2_PUBLIC_IP:27017/?authSource=admin"
  az webapp config appsettings set -g "$AZ_RESOURCE_GROUP" -n "$AZ_FRONTEND_APP" --output none --settings \
    WEBSITES_PORT=80 PORT=80
  az webapp config container set -g "$AZ_RESOURCE_GROUP" -n "$AZ_BACKEND_APP" --output none \
    --container-image-name "$DOCKERHUB_NAMESPACE/crisismonitor-backend:$TAG"
  az webapp config container set -g "$AZ_RESOURCE_GROUP" -n "$AZ_FRONTEND_APP" --output none \
    --container-image-name "$DOCKERHUB_NAMESPACE/crisismonitor-frontend:$TAG"

  log "Azure: health checks (F1 cold starts are slow)"
  wait_http "$backend_url/health" 600 ok
  wait_http "https://$AZ_FRONTEND_APP.azurewebsites.net/" 600
  echo "Azure frontend: https://$AZ_FRONTEND_APP.azurewebsites.net"
}

case "${1:-}" in
  aws)   deploy_aws ;;
  azure) deploy_azure ;;
  all)   deploy_aws; deploy_azure ;;
  *)     echo "usage: $0 aws|azure|all" >&2; exit 2 ;;
esac
