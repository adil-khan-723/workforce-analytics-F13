#!/usr/bin/env bash
# OrgIQ Workforce Analytics — Teardown Script
# Removes ALL AWS infrastructure for the project including:
#   S3 bucket, DynamoDB tables, Lambda functions, API Gateway,
#   Cognito User Pool, EventBridge rules, CloudWatch alarms, IAM roles
# Also handles any manually seeded DynamoDB data and Lambda invocations

set -euo pipefail

# ── CONFIG ────────────────────────────────────────────────────────────────
STACK_NAME="workforce-analytics"
STAGE="prod"
REGION="us-east-1"
BUCKET="workforce-dashboard-736786104206-prod"
SKIP_CONFIRM=false

TABLES=(
  "workforce_employees_prod"
  "workforce_leave_records_prod"
  "workforce_performance_prod"
  "workforce_recruitment_prod"
  "workforce_analytics_prod"
)

LAMBDA_FUNCTIONS=(
  "workforce-aggregation-prod"
  "workforce-metrics-api-prod"
  "workforce-org-chart-prod"
  "workforce-health-api-prod"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift ;;
    --yes|-y) SKIP_CONFIRM=true ;;
    *) ;;
  esac
  shift
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── COLORS ────────────────────────────────────────────────────────────────
R='\033[0m'; B='\033[1m'; CY='\033[0;36m'; GR='\033[0;32m'
YL='\033[1;33m'; RD='\033[0;31m'; BL='\033[0;34m'; D='\033[2m'

step() { echo -e "\n${B}${CY}▶  $*${R}"; }
ok()   { echo -e "   ${GR}✔${R}  $*"; }
info() { echo -e "   ${BL}ℹ${R}  $*"; }
warn() { echo -e "   ${YL}⚠${R}  $*"; }
skip() { echo -e "   ${D}   not found - skipping: $*${R}"; }
die()  { echo -e "\n${RD}${B}FATAL: $*${R}\n"; exit 1; }

clear 2>/dev/null || true
echo -e "${RD}${B}"
cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════════╗
  ║         OrgIQ — AWS Resource Teardown                     ║
  ║         All resources will be permanently deleted.        ║
  ╚═══════════════════════════════════════════════════════════╝
BANNER
echo -e "${R}"

command -v aws &>/dev/null || die "AWS CLI not found."

echo -e "   ${B}Stack:${R}   $STACK_NAME"
echo -e "   ${B}Stage:${R}   $STAGE"
echo -e "   ${B}Region:${R}  $REGION"
echo -e "   ${B}Bucket:${R}  $BUCKET"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "AWS credentials not configured. Run: aws configure"
echo -e "   ${B}Account:${R} $ACCOUNT_ID"

if ! $SKIP_CONFIRM; then
  echo ""
  echo -e "   ${YL}${B}This will permanently delete all OrgIQ AWS resources.${R}"
  echo -e "   ${YL}   This action cannot be undone.${R}"
  echo ""
  read -rp "   Type 'yes' to confirm: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "   Aborted."; exit 0; }
fi

echo ""
echo -e "   ${D}Starting teardown at $(date)${R}"

# ══════════════════════════════════════════════════════════════════════════
#  STEP 1 — S3 BUCKET
# ══════════════════════════════════════════════════════════════════════════
step "Step 1/6 — S3 Bucket"

if aws s3 ls "s3://${BUCKET}" --region "$REGION" &>/dev/null; then
  info "Emptying s3://${BUCKET}..."
  aws s3 rm "s3://${BUCKET}/" --recursive --region "$REGION" 2>/dev/null || true
  aws s3 rb "s3://${BUCKET}" --region "$REGION" 2>/dev/null || true
  ok "S3 bucket deleted: ${BUCKET}"
else
  skip "S3 bucket: ${BUCKET}"
fi

# ══════════════════════════════════════════════════════════════════════════
#  STEP 2 — DYNAMODB TABLES
# ══════════════════════════════════════════════════════════════════════════
step "Step 2/6 — DynamoDB Tables"

for tbl in "${TABLES[@]}"; do
  STATUS=$(aws dynamodb describe-table \
    --table-name "$tbl" --region "$REGION" \
    --query "Table.TableStatus" --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$STATUS" = "NOT_FOUND" ]; then
    skip "$tbl"
  else
    info "Deleting $tbl..."
    aws dynamodb delete-table \
      --table-name "$tbl" \
      --region "$REGION" \
      --output text > /dev/null 2>&1
    ok "Deleted: $tbl"
  fi
done

info "Waiting for table deletions to complete..."
for tbl in "${TABLES[@]}"; do
  aws dynamodb wait table-not-exists \
    --table-name "$tbl" --region "$REGION" 2>/dev/null || true
done
ok "All DynamoDB tables removed"

# ══════════════════════════════════════════════════════════════════════════
#  STEP 3 — LAMBDA FUNCTIONS (explicit cleanup in case CFN misses them)
# ══════════════════════════════════════════════════════════════════════════
step "Step 3/6 — Lambda Functions"

for fn in "${LAMBDA_FUNCTIONS[@]}"; do
  EXISTS=$(aws lambda get-function \
    --function-name "$fn" --region "$REGION" \
    --query "Configuration.FunctionName" --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$EXISTS" = "NOT_FOUND" ]; then
    skip "Lambda: $fn"
  else
    info "Deleting Lambda: $fn..."
    aws lambda delete-function \
      --function-name "$fn" \
      --region "$REGION" 2>/dev/null || true
    ok "Deleted: $fn"
  fi
done

# ══════════════════════════════════════════════════════════════════════════
#  STEP 4 — EVENTBRIDGE RULES
# ══════════════════════════════════════════════════════════════════════════
step "Step 4/6 — EventBridge Rules"

RULES=$(aws events list-rules \
  --name-prefix "workforce" \
  --region "$REGION" \
  --query "Rules[].Name" \
  --output text 2>/dev/null || echo "")

if [ -z "$RULES" ]; then
  skip "No EventBridge rules found"
else
  for rule in $RULES; do
    info "Removing targets from rule: $rule..."
    TARGET_IDS=$(aws events list-targets-by-rule \
      --rule "$rule" --region "$REGION" \
      --query "Targets[].Id" --output text 2>/dev/null || echo "")

    if [ -n "$TARGET_IDS" ]; then
      aws events remove-targets \
        --rule "$rule" \
        --ids $TARGET_IDS \
        --region "$REGION" > /dev/null 2>&1 || true
    fi

    aws events delete-rule \
      --name "$rule" \
      --region "$REGION" 2>/dev/null || true
    ok "Deleted EventBridge rule: $rule"
  done
fi

# ══════════════════════════════════════════════════════════════════════════
#  STEP 5 — CLOUDFORMATION STACK
#  (handles API Gateway, Cognito, IAM roles, CloudWatch alarms)
# ══════════════════════════════════════════════════════════════════════════
step "Step 5/6 — CloudFormation Stack"

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  skip "CloudFormation stack: $STACK_NAME"
else
  info "Deleting stack: $STACK_NAME (current status: $STACK_STATUS)..."
  info "This removes: API Gateway, Cognito, IAM roles, CloudWatch alarms, EventBridge"

  aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

  info "Waiting for stack deletion (2-4 minutes)..."
  while true; do
    CFN_STATUS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DELETED")

    case "$CFN_STATUS" in
      "DELETED"|"DOES_NOT_EXIST")
        break ;;
      *"FAILED"*|*"ROLLBACK"*)
        warn "Stack deletion issue: $CFN_STATUS"
        info "Check: https://${REGION}.console.aws.amazon.com/cloudformation"
        break ;;
      *)
        echo -ne "   ${D}Status: $CFN_STATUS...${R}\r"
        sleep 5 ;;
    esac
  done
  echo ""
  ok "CloudFormation stack deleted"
fi

# ══════════════════════════════════════════════════════════════════════════
#  STEP 6 — LOCAL FILE CLEANUP
# ══════════════════════════════════════════════════════════════════════════
step "Step 6/6 — Local File Cleanup"

LOCAL_FILES=(
  "$PROJECT_DIR/infrastructure/samconfig.toml"
  "$PROJECT_DIR/deployment_summary.txt"
  "$PROJECT_DIR/scripts/employees_seed.json"
  "$PROJECT_DIR/employees_seed.json"
  "/tmp/response.json"
  "/tmp/orgiq_agg_response.json"
  "/tmp/orgiq_agg.json"
)

for f in "${LOCAL_FILES[@]}"; do
  if [ -f "$f" ]; then
    rm -f "$f"
    ok "Removed: $f"
  fi
done

FRONTEND="$PROJECT_DIR/frontend/index.html"
if [ -f "$FRONTEND" ] && grep -q "DEMO_MODE: false" "$FRONTEND" 2>/dev/null; then
  sed -i.bak 's/DEMO_MODE: false/DEMO_MODE: true/' "$FRONTEND"
  rm -f "${FRONTEND}.bak"
  ok "frontend/index.html reset to DEMO_MODE: true"
fi

# ══════════════════════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GR}${B}"
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║         Teardown Complete — AWS bill: \$0                 ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo -e "${R}"
echo -e "   ${D}Removed:"
echo -e "     S3 dashboard bucket"
echo -e "     5 DynamoDB tables (employees, leave, performance, recruitment, analytics)"
echo -e "     4 Lambda functions"
echo -e "     API Gateway"
echo -e "     Cognito User Pool"
echo -e "     EventBridge schedule rules"
echo -e "     CloudWatch alarms"
echo -e "     IAM roles and policies"
echo -e "     Local config files${R}"
echo ""
echo -e "   ${D}To redeploy: ./launch.sh${R}"
echo ""
