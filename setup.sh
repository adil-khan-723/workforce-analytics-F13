#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  OrgIQ Workforce Analytics — Full AWS Setup Script          ║
# ║  Run: chmod +x setup.sh && ./setup.sh                       ║
# ╚══════════════════════════════════════════════════════════════╝
set -euo pipefail

# ── COLOURS ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✓${RESET}  $*"; }
info() { echo -e "${CYAN}  →${RESET}  $*"; }
warn() { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
err()  { echo -e "${RED}  ✗${RESET}  $*"; exit 1; }
hdr()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── BANNER ────────────────────────────────────────────────────────
echo -e "${CYAN}"
cat << 'EOF'
   ___            ___ ___
  / _ \ _ _ __ _ |_ _/ _ \
 | (_) | '_/ _` | | | (_) |
  \___/|_| \__, ||___\__\_\
           |___/  Workforce Intelligence
EOF
echo -e "${RESET}"
echo -e "${BOLD}  Full AWS Deployment Setup${RESET}"
echo -e "  This script will deploy the complete OrgIQ stack to AWS.\n"

# ── CONFIG — edit these ────────────────────────────────────────────
STACK_NAME="workforce-analytics"
STAGE="prod"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ADMIN_EMAIL=""          # will prompt if empty
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── STEP 0: Prerequisites check ───────────────────────────────────
hdr "Step 0: Checking prerequisites"

check_cmd() {
  if command -v "$1" &>/dev/null; then
    ok "$1 found: $(command -v "$1")"
  else
    err "$1 not found. Install it first.\n     $2"
  fi
}

check_cmd python3  "brew install python / apt install python3"
check_cmd pip3     "comes with Python"
check_cmd aws      "https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
check_cmd sam      "brew install aws-sam-cli  OR  pip3 install aws-sam-cli"
check_cmd zip      "brew install zip / apt install zip"

# Check AWS credentials
info "Verifying AWS credentials…"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials not configured. Run: aws configure"
ok "AWS Account: ${ACCOUNT_ID} (region: ${REGION})"

# Python deps
info "Installing Python dependencies…"
pip3 install boto3 faker --quiet --break-system-packages 2>/dev/null \
  || pip3 install boto3 faker --quiet
ok "boto3 + faker installed"

# ── STEP 1: Get admin email ────────────────────────────────────────
hdr "Step 1: Configuration"

if [ -z "$ADMIN_EMAIL" ]; then
  read -rp "  Enter admin email for Cognito HR_Admin user: " ADMIN_EMAIL
fi
[ -z "$ADMIN_EMAIL" ] && err "Admin email is required."
ok "Admin email: ${ADMIN_EMAIL}"
ok "Stack name:  ${STACK_NAME}-${STAGE}"
ok "Region:      ${REGION}"

read -rp "  Press Enter to continue, or Ctrl+C to abort…"

# ── STEP 2: Deploy infrastructure (SAM) ───────────────────────────
hdr "Step 2: Deploying AWS Infrastructure"
info "Running sam build…"
cd "${PROJECT_DIR}/infrastructure"

# Create samconfig.toml for non-interactive deploy
cat > samconfig.toml << SAMEOF
version = 0.1
[default.deploy.parameters]
stack_name        = "${STACK_NAME}"
s3_prefix         = "${STACK_NAME}"
region            = "${REGION}"
confirm_changeset = false
capabilities      = "CAPABILITY_IAM CAPABILITY_NAMED_IAM"
parameter_overrides = "Stage=${STAGE} AdminEmail=${ADMIN_EMAIL}"
resolve_s3        = true
SAMEOF

sam build --quiet
ok "SAM build complete"

info "Deploying stack (this takes 3–5 minutes)…"
sam deploy --no-confirm-changeset 2>&1 | while IFS= read -r line; do
  case "$line" in
    *"CREATE_COMPLETE"*) ok "$line";;
    *"UPDATE_COMPLETE"*) ok "$line";;
    *"FAILED"*|*"ROLLBACK"*) warn "$line";;
    *) echo "       $line";;
  esac
done

ok "Stack deployed!"

# ── STEP 3: Get outputs ────────────────────────────────────────────
hdr "Step 3: Reading Stack Outputs"

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

API_ENDPOINT=$(get_output "ApiEndpoint")
DASHBOARD_URL=$(get_output "DashboardUrl")
USER_POOL_ID=$(get_output "UserPoolId")
CLIENT_ID=$(get_output "UserPoolClientId")
BUCKET_NAME=$(get_output "DashboardUrl" | sed 's|http://||;s|.s3-website.*||')

ok "API Endpoint:    ${API_ENDPOINT}"
ok "Dashboard URL:   ${DASHBOARD_URL}"
ok "User Pool ID:    ${USER_POOL_ID}"
ok "Client ID:       ${CLIENT_ID}"
ok "S3 Bucket:       ${BUCKET_NAME}"

# ── STEP 4: Seed DynamoDB ──────────────────────────────────────────
hdr "Step 4: Seeding DynamoDB with Dummy Data"
cd "${PROJECT_DIR}/scripts"

info "Running seed_data.py (75 employees, 5 tables)…"
python3 seed_data.py --region "${REGION}"
ok "DynamoDB seeded!"

# ── STEP 5: Run first aggregation ─────────────────────────────────
hdr "Step 5: Running Initial Metric Aggregation"
info "Invoking aggregation Lambda…"

LAMBDA_NAME="workforce-aggregation-${STAGE}"
aws lambda invoke \
  --function-name "${LAMBDA_NAME}" \
  --region "${REGION}" \
  --payload '{}' \
  /tmp/agg_response.json \
  --cli-binary-format raw-in-base64-out \
  --output text --query 'StatusCode' > /dev/null

STATUS=$(python3 -c "import json; d=json.load(open('/tmp/agg_response.json')); print(d.get('statusCode','?'))")
[ "$STATUS" = "200" ] && ok "Aggregation complete (status: ${STATUS})" \
  || warn "Aggregation returned status: ${STATUS} — check Lambda logs"

# ── STEP 6: Update frontend config ────────────────────────────────
hdr "Step 6: Patching Frontend Config"
FRONTEND="${PROJECT_DIR}/frontend/index.html"

# Replace the config block in the HTML
python3 - << PYEOF
import re

with open('${FRONTEND}', 'r') as f:
    html = f.read()

new_config = """const CONFIG = {
  API_BASE: '${API_ENDPOINT}',
  COGNITO: {
    userPoolId:       '${USER_POOL_ID}',
    userPoolClientId: '${CLIENT_ID}',
    region:           '${REGION}',
  },
  ALLOWED_GROUPS: ['HR_Admin', 'Leadership'],
  DEMO_MODE: false,
};"""

# Replace the CONFIG block
html = re.sub(
    r'const CONFIG = \{.*?DEMO_MODE:.*?\};',
    new_config,
    html,
    flags=re.DOTALL
)

with open('${FRONTEND}', 'w') as f:
    f.write(html)

print("  Frontend config updated.")
PYEOF
ok "Config patched with live API endpoint"

# ── STEP 7: Upload frontend to S3 ─────────────────────────────────
hdr "Step 7: Uploading Dashboard to S3"

# Auto-detect bucket name from stack
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardUrl'].OutputValue" \
  --output text | python3 -c "
import sys
url = sys.stdin.read().strip()
# http://bucket-name.s3-website-region.amazonaws.com
bucket = url.replace('http://','').split('.')[0]
print(bucket)
")

info "Uploading to s3://${BUCKET}…"
aws s3 sync "${PROJECT_DIR}/frontend/" "s3://${BUCKET}/" \
  --region "${REGION}" \
  --cache-control "max-age=3600" \
  --exclude "*.DS_Store" \
  --exclude ".git/*"
ok "Frontend uploaded!"

# ── STEP 8: Create Cognito admin user ─────────────────────────────
hdr "Step 8: Creating Cognito HR_Admin User"

TEMP_PASS="TempOrgIQ@$(date +%Y)!"

info "Creating user: ${ADMIN_EMAIL}…"
aws cognito-idp admin-create-user \
  --user-pool-id "${USER_POOL_ID}" \
  --username "${ADMIN_EMAIL}" \
  --temporary-password "${TEMP_PASS}" \
  --user-attributes Name=email,Value="${ADMIN_EMAIL}" Name=email_verified,Value=true \
  --region "${REGION}" \
  --output text > /dev/null 2>&1 \
  && ok "User created" \
  || warn "User may already exist — skipping"

info "Adding to HR_Admin group…"
aws cognito-idp admin-add-user-to-group \
  --user-pool-id "${USER_POOL_ID}" \
  --username "${ADMIN_EMAIL}" \
  --group-name "HR_Admin" \
  --region "${REGION}" \
  && ok "Added to HR_Admin group" \
  || warn "Could not add to group — may already be a member"

# ── DONE ──────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║           🎉  SETUP COMPLETE!                        ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}  Dashboard URL:${RESET}  ${CYAN}${DASHBOARD_URL}${RESET}"
echo -e "${BOLD}  API Endpoint:${RESET}   ${CYAN}${API_ENDPOINT}${RESET}"
echo ""
echo -e "${BOLD}  Login credentials:${RESET}"
echo -e "    Email:    ${ADMIN_EMAIL}"
echo -e "    Password: ${TEMP_PASS}  ${YELLOW}(temporary — Cognito will prompt you to change it)${RESET}"
echo ""
echo -e "${BOLD}  Aggregation schedule:${RESET}  Daily at 2:00 AM UTC (EventBridge)"
echo ""
echo -e "${YELLOW}  Tip: Bookmark the dashboard URL above and log in now.${RESET}"
echo ""

# Save summary to file
cat > "${PROJECT_DIR}/deployment_summary.txt" << SUMEOF
OrgIQ Workforce Analytics — Deployment Summary
Generated: $(date)

Dashboard URL:    ${DASHBOARD_URL}
API Endpoint:     ${API_ENDPOINT}
User Pool ID:     ${USER_POOL_ID}
Client ID:        ${CLIENT_ID}
S3 Bucket:        ${BUCKET}
Stack Name:       ${STACK_NAME}
Region:           ${REGION}
Admin Email:      ${ADMIN_EMAIL}
Temp Password:    ${TEMP_PASS}
SUMEOF

ok "Summary saved to deployment_summary.txt"
