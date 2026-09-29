#!/usr/bin/env bash
# One-time setup for deploy/deploy.sh and the "Deploy (AWS + Azure)" GitHub workflow.
# Safe to re-run. Run it yourself with admin-level AWS + Azure logins:
#
#   deploy/setup-once.sh
#
# It creates:
#   AWS   - SSM access for the EC2 instance role, a "crisismonitor-deploy" policy,
#           a "crisismonitor-ci" IAM user (+ access key for GitHub), and the
#           /crisismonitor/MONGO_ROOT_PASSWORD + /crisismonitor/WANDB_API_KEY parameters
#   Azure - an app registration that GitHub Actions logs in as via OIDC (no secret),
#           with Contributor on the crisismonitor resource group only
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
EC2_ROLE="crisismonitor-ec2-role"
EC2_SECURITY_GROUP="${EC2_SECURITY_GROUP:-sg-0099f760cbf7a837a}"
LOCAL_DEPLOY_USER="${LOCAL_DEPLOY_USER:-crisismonitor-deployer}"
CI_USER="crisismonitor-ci"
GITHUB_REPO="${GITHUB_REPO:-Granine/CrisisMonitor}"
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-crisismonitor_group}"
AZ_APP_NAME="crisismonitor-github-deploy"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- AWS
log "EC2 instance role: SSM agent + read /crisismonitor/* parameters"
aws iam attach-role-policy --role-name "$EC2_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
cat > "$TMP/ec2.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["ssm:GetParameter","ssm:GetParameters"],
 "Resource":"arn:aws:ssm:$AWS_REGION:$AWS_ACCOUNT_ID:parameter/crisismonitor/*"}]}
EOF
aws iam put-role-policy --role-name "$EC2_ROLE" --policy-name crisismonitor-read-params \
  --policy-document "file://$TMP/ec2.json"

log "Deploy policy (ECR push, SSM run-command, parameters, security group)"
cat > "$TMP/deploy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer",
   "ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage",
   "ecr:DescribeRepositories","ecr:CreateRepository"],
  "Resource":"arn:aws:ecr:$AWS_REGION:$AWS_ACCOUNT_ID:repository/crisismonitor-*"},
 {"Effect":"Allow","Action":"ssm:SendCommand","Resource":[
   "arn:aws:ec2:$AWS_REGION:$AWS_ACCOUNT_ID:instance/*",
   "arn:aws:ssm:$AWS_REGION::document/AWS-RunShellScript"]},
 {"Effect":"Allow","Action":["ssm:GetCommandInvocation","ssm:ListCommandInvocations"],"Resource":"*"},
 {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],
  "Resource":"arn:aws:ssm:$AWS_REGION:$AWS_ACCOUNT_ID:parameter/crisismonitor/*"},
 {"Effect":"Allow","Action":["ec2:AuthorizeSecurityGroupIngress"],
  "Resource":"arn:aws:ec2:$AWS_REGION:$AWS_ACCOUNT_ID:security-group/$EC2_SECURITY_GROUP"}
]}
EOF
POLICY_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:policy/crisismonitor-deploy"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # keep at most 5 versions: drop the oldest non-default one before adding
  OLD="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
          --query 'Versions[?!IsDefaultVersion]|sort_by(@,&CreateDate)[0].VersionId' --output text)"
  [ "$OLD" != "None" ] && aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLD"
  aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "file://$TMP/deploy.json" \
    --set-as-default >/dev/null
else
  aws iam create-policy --policy-name crisismonitor-deploy --policy-document "file://$TMP/deploy.json" >/dev/null
fi
aws iam attach-user-policy --user-name "$LOCAL_DEPLOY_USER" --policy-arn "$POLICY_ARN"

log "CI user $CI_USER"
aws iam get-user --user-name "$CI_USER" >/dev/null 2>&1 || aws iam create-user --user-name "$CI_USER" >/dev/null
aws iam attach-user-policy --user-name "$CI_USER" --policy-arn "$POLICY_ARN"
if [ "$(aws iam list-access-keys --user-name "$CI_USER" --query 'length(AccessKeyMetadata)')" = 0 ]; then
  read -r CI_KEY_ID CI_KEY_SECRET < <(aws iam create-access-key --user-name "$CI_USER" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
else
  echo "  $CI_USER already has an access key; not creating another (delete it in IAM to rotate)."
fi

log "SSM parameters"
if ! aws ssm get-parameter --region "$AWS_REGION" --name /crisismonitor/MONGO_ROOT_PASSWORD >/dev/null 2>&1; then
  # hex only, so it never needs URL-encoding inside MONGO_URI
  aws ssm put-parameter --region "$AWS_REGION" --name /crisismonitor/MONGO_ROOT_PASSWORD \
    --type SecureString --value "$(openssl rand -hex 24)" >/dev/null
  echo "  generated /crisismonitor/MONGO_ROOT_PASSWORD"
else
  echo "  /crisismonitor/MONGO_ROOT_PASSWORD exists (kept)"
fi
if ! aws ssm get-parameter --region "$AWS_REGION" --name /crisismonitor/WANDB_API_KEY >/dev/null 2>&1 \
   || [ "${RESET_WANDB:-}" = 1 ]; then
  read -r -s -p "  W&B API key (https://wandb.ai/authorize, input hidden): " WANDB_KEY; echo
  aws ssm put-parameter --region "$AWS_REGION" --name /crisismonitor/WANDB_API_KEY \
    --type SecureString --overwrite --value "$WANDB_KEY" >/dev/null
  echo "  stored /crisismonitor/WANDB_API_KEY"
else
  echo "  /crisismonitor/WANDB_API_KEY exists (kept; RESET_WANDB=1 to replace)"
fi

# ---------------------------------------------------------------- Azure
log "Azure app registration for GitHub OIDC"
SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
APP_ID="$(az ad app list --display-name "$AZ_APP_NAME" --query '[0].appId' -o tsv)"
[ -z "$APP_ID" ] && APP_ID="$(az ad app create --display-name "$AZ_APP_NAME" --query appId -o tsv)"
az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null
az role assignment create --assignee "$APP_ID" --role Contributor --output none \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$AZ_RESOURCE_GROUP" 2>/dev/null || true
for fc in "gh-pull-request:repo:$GITHUB_REPO:pull_request" "gh-main:repo:$GITHUB_REPO:ref:refs/heads/main"; do
  name="${fc%%:*}"; subject="${fc#*:}"
  az ad app federated-credential show --id "$APP_ID" --federated-credential-id "$name" >/dev/null 2>&1 && continue
  az ad app federated-credential create --id "$APP_ID" --output none --parameters \
    "{\"name\":\"$name\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$subject\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
done

# ---------------------------------------------------------------- summary
log "Add these GitHub repository secrets (Settings -> Secrets and variables -> Actions):"
cat <<EOF
  CRISISMONITOR_AWS_ACCESS_KEY_ID      ${CI_KEY_ID:-<existing key - see IAM user $CI_USER>}
  CRISISMONITOR_AWS_SECRET_ACCESS_KEY  ${CI_KEY_SECRET:-<only shown when first created>}
  AZURE_CLIENT_ID                      $APP_ID
  AZURE_TENANT_ID                      $TENANT_ID
  AZURE_SUBSCRIPTION_ID                $SUB_ID
  DOCKERHUB_USERNAME                   <your Docker Hub user, e.g. excila>
  DOCKERHUB_TOKEN                      <Docker Hub access token with Read & Write>
EOF
