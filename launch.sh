#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════╗
# ║         OrgIQ Workforce Analytics — Master Launch Script             ║
# ║                                                                       ║
# ║  • No prompts — runs fully automated                                 ║
# ║  • Idempotent — re-run anytime, skips already-done steps             ║
# ║  • Auto-detects AWS vs local demo mode                               ║
# ║  • Deploys infra, seeds data, aggregates metrics, opens dashboard    ║
# ║                                                                       ║
# ║  Usage:  chmod +x launch.sh && ./launch.sh                           ║
# ║  Flags:  --local        force local demo (no AWS)                    ║
# ║          --aws          force AWS mode (fail if creds missing)       ║
# ║          --region XX    override AWS region (default: us-east-1)     ║
# ║          --no-browser   skip opening browser at end                  ║
# ╚═══════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ─── HARDCODED CONFIG (edit if needed) ────────────────────────────────────
ADMIN_EMAIL="adilk3682@gmail.com"
STACK_NAME="workforce-analytics"
STAGE="prod"
REGION="us-east-1"

# ─── PARSE FLAGS ──────────────────────────────────────────────────────────
MODE="auto"
OPEN_BROWSER=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)       MODE="local"        ;;
    --aws)         MODE="aws"          ;;
    --region)      REGION="$2"; shift  ;;
    --no-browser)  OPEN_BROWSER=false  ;;
    --help|-h)
      echo "Usage: ./launch.sh [--local|--aws] [--region REGION] [--no-browser]"
      exit 0 ;;
    *) ;;
  esac
  shift
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$PROJECT_DIR/orgiq_launch.log"
cd "$PROJECT_DIR"

# Tee everything to log
exec > >(tee -a "$LOGFILE") 2>&1

# ─── COLOURS ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  R='\033[0m' B='\033[1m' D='\033[2m'
  CY='\033[0;36m' GR='\033[0;32m' YL='\033[1;33m' RD='\033[0;31m' BL='\033[0;34m'
else
  R='' B='' D='' CY='' GR='' YL='' RD='' BL=''
fi

step() { echo -e "\n${B}${CY}▶  $*${R}"; }
ok()   { echo -e "   ${GR}✔${R}  $*"; }
info() { echo -e "   ${BL}ℹ${R}  $*"; }
warn() { echo -e "   ${YL}⚠${R}  $*"; }
skip() { echo -e "   ${D}↷  already done — $*${R}"; }
die()  { echo -e "\n${RD}${B}FATAL: $*${R}\n"; exit 1; }

open_browser() {
  local url="$1"
  ( sleep 1.5
    command -v xdg-open &>/dev/null && { xdg-open "$url"; exit; }
    command -v open     &>/dev/null && { open "$url";     exit; }
    command -v start    &>/dev/null && { start "$url";    exit; }
  ) &
}

# ─── BANNER ───────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo -e "${CY}${B}"
cat << 'BANNER'
  ╔═══════════════════════════════════════════════════╗
  ║   ██████╗ ██████╗  ██████╗ ██╗ ██████╗           ║
  ║  ██╔═══██╗██╔══██╗██╔════╝ ██║██╔═══██╗          ║
  ║  ██║   ██║██████╔╝██║  ███╗██║██║   ██║          ║
  ║  ╚██████╔╝██╔══██╗╚██████╔╝██║╚██████╔╝          ║
  ║   ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝ ╚══▀▀═╝           ║
  ║      Workforce Intelligence Dashboard             ║
  ╚═══════════════════════════════════════════════════╝
BANNER
echo -e "${R}"
echo -e "   ${D}Log  → $LOGFILE${R}"
echo -e "   ${D}Mode → auto-detect  |  Region → $REGION  |  Admin → $ADMIN_EMAIL${R}"

# ══════════════════════════════════════════════════════════════════════════
#  STEP 1 — PREREQUISITES
# ══════════════════════════════════════════════════════════════════════════
step "Step 1/8 — System Prerequisites"

info "OS: $(uname -s) $(uname -m)"

# Python
PYTHON=""
for cmd in python3 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python; do
  if command -v "$cmd" &>/dev/null; then
    VER=$($cmd --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    MAJ=$(echo "$VER" | cut -d. -f1)
    MIN=$(echo "$VER" | cut -d. -f2)
    if [ "${MAJ:-0}" -ge 3 ] && [ "${MIN:-0}" -ge 9 ]; then
      PYTHON="$cmd"
      ok "Python $VER ($(command -v $cmd))"
      break
    fi
  fi
done
[ -z "$PYTHON" ] && die "Python 3.9+ required. Install: https://python.org"

# pip
PIP=""
for cmd in pip3 pip; do
  if command -v "$cmd" &>/dev/null; then
    PIP="$cmd"; ok "pip ($(command -v $cmd))"; break
  fi
done
if [ -z "$PIP" ]; then
  $PYTHON -m pip --version &>/dev/null && PIP="$PYTHON -m pip" && ok "pip via python -m pip"
fi
[ -z "$PIP" ] && die "pip not found. Install: curl https://bootstrap.pypa.io/get-pip.py | python3"

for t in curl unzip; do
  command -v "$t" &>/dev/null && ok "$t" || warn "$t not found (some steps may be affected)"
done

# ══════════════════════════════════════════════════════════════════════════
#  STEP 2 — PYTHON PACKAGES
# ══════════════════════════════════════════════════════════════════════════
step "Step 2/8 — Python Packages"

pip_install() {
  local pkg="$1" mod="${2:-$1}"
  if $PYTHON -c "import $mod" 2>/dev/null; then
    skip "$pkg already installed"
  else
    echo -ne "   Installing $pkg…"
    $PIP install "$pkg" --quiet --break-system-packages 2>/dev/null \
      || $PIP install "$pkg" --quiet \
      || die "Failed to install $pkg"
    echo -e " ${GR}done${R}"
    ok "$pkg installed"
  fi
}

pip_install "boto3"
pip_install "faker"

# ══════════════════════════════════════════════════════════════════════════
#  STEP 3 — DETECT AWS vs LOCAL
# ══════════════════════════════════════════════════════════════════════════
step "Step 3/8 — Environment Detection"

AWS_OK=false
SAM_OK=false
ACCOUNT_ID=""

if command -v aws &>/dev/null; then
  ok "AWS CLI: $(aws --version 2>&1 | head -1)"
  if IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null); then
    ACCOUNT_ID=$(echo "$IDENTITY" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['Account'])")
    AWS_USER=$(echo "$IDENTITY"   | $PYTHON -c "import sys,json; print(json.load(sys.stdin).get('Arn','unknown').split('/')[-1])")
    ok "AWS Account: $ACCOUNT_ID  User: $AWS_USER"
    AWS_OK=true
  else
    warn "AWS credentials not configured or expired — falling back to local mode"
  fi
else
  warn "AWS CLI not found — falling back to local mode"
fi

if command -v sam &>/dev/null; then
  ok "SAM CLI: $(sam --version 2>&1 | head -1)"
  SAM_OK=true
else
  warn "SAM CLI not found — falling back to local mode"
fi

# Auto-decide
if [ "$MODE" = "auto" ]; then
  if $AWS_OK && $SAM_OK; then
    MODE="aws"
    info "Auto-selected: FULL AWS DEPLOYMENT"
  else
    MODE="local"
    info "Auto-selected: LOCAL DEMO (no AWS)"
    $AWS_OK || info "  Reason: valid AWS credentials not found"
    $SAM_OK || info "  Reason: SAM CLI not found"
  fi
fi

# Enforce mode requirements
if [ "$MODE" = "aws" ]; then
  $AWS_OK || die "AWS mode requires credentials.\n   Run: aws configure\n   Then re-run: ./launch.sh"
  $SAM_OK || die "AWS mode requires SAM CLI.\n   macOS: brew install aws-sam-cli\n   pip:   pip3 install aws-sam-cli\n   Then re-run: ./launch.sh"
fi

# ══════════════════════════════════════════════════════════════════════════
#  LOCAL DEMO BRANCH
# ══════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "local" ]; then

  step "Step 4/8 — Local Dashboard Setup"

  FRONTEND="$PROJECT_DIR/frontend/index.html"
  [ -f "$FRONTEND" ] || die "frontend/index.html not found at: $FRONTEND"
  ok "Dashboard file found"

  if grep -q "DEMO_MODE: false" "$FRONTEND" 2>/dev/null; then
    sed -i.bak 's/DEMO_MODE: false/DEMO_MODE: true/' "$FRONTEND"
    rm -f "$FRONTEND.bak"
    ok "DEMO_MODE → true"
  else
    skip "DEMO_MODE already true"
  fi

  step "Steps 5–8/8 — Skipped (using built-in mock data)"

  # Find a free port
  PORT=5500
  for p in 5500 5501 5502 8080 8081 8082 3000 3001; do
    if ! $PYTHON -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',$p)); s.close()" 2>/dev/null; then
      continue
    fi
    PORT=$p; break
  done
  URL="http://localhost:$PORT"

  $OPEN_BROWSER && open_browser "$URL"

  echo ""
  echo -e "${GR}${B}"
  echo "  ╔═══════════════════════════════════════════════════╗"
  echo "  ║       ✅  OrgIQ Local Demo is Running!            ║"
  echo "  ╚═══════════════════════════════════════════════════╝"
  echo -e "${R}"
  echo -e "   ${B}Dashboard:${R} ${CY}$URL${R}"
  echo -e "   ${B}Email:${R}     hr.admin@demo.com"
  echo -e "   ${B}Password:${R}  Demo@1234  ${D}(any non-empty creds work in demo mode)${R}"
  echo ""
  echo -e "   ${D}All 7 tabs, 10 charts, D3 org chart — all live with mock data.${R}"
  echo -e "   ${YL}Press Ctrl+C to stop.${R}\n"

  cd "$PROJECT_DIR/frontend"
  exec $PYTHON -c "
import http.server, pathlib

PORT = $PORT
DIR  = pathlib.Path('.')

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(DIR), **kw)
    def log_message(self, fmt, *args):
        code = str(args[1]) if len(args) > 1 else '000'
        if code not in ('200', '304', '206'):
            print(f'   [{code}] {self.path}')
    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()
    def do_GET(self):
        p = pathlib.Path(self.path.lstrip('/'))
        if self.path == '/' or not (DIR / p).exists():
            self.path = '/index.html'
        super().do_GET()

server = http.server.HTTPServer(('', PORT), H)
print(f'   Serving on port {PORT}')
server.serve_forever()
"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
#  AWS BRANCH
# ══════════════════════════════════════════════════════════════════════════

step "Step 4/8 — AWS Configuration"
ok "Admin email: $ADMIN_EMAIL"
ok "Stack:  $STACK_NAME  |  Stage: $STAGE  |  Region: $REGION  |  Account: $ACCOUNT_ID"

# ──────────────────────────────────────────────────────────────
#  STEP 5 — INFRA (idempotent)
# ──────────────────────────────────────────────────────────────
step "Step 5/8 — AWS Infrastructure"

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STACK_STATUS" == *"COMPLETE"* ]]; then
  skip "CloudFormation stack already deployed ($STACK_STATUS)"
else
  info "Stack status: ${STACK_STATUS} — deploying now…"
  cd "$PROJECT_DIR/infrastructure"

  # Write samconfig (non-interactive deploy)
  cat > samconfig.toml << SAMEOF
version = 0.1
[default.deploy.parameters]
stack_name        = "${STACK_NAME}"
region            = "${REGION}"
confirm_changeset = false
capabilities      = "CAPABILITY_IAM CAPABILITY_NAMED_IAM"
parameter_overrides = "Stage=${STAGE} AdminEmail=${ADMIN_EMAIL}"
resolve_s3        = true
s3_prefix         = "${STACK_NAME}"
SAMEOF

  # SAM does not support --python-interpreter; instead we prepend the directory
  # containing the right Python to PATH so SAM picks it up automatically.
  # We look for python3.11 first (matches the Lambda runtime in template.yaml),
  # then fall back to any python3.9+ that is available.
  SAM_PYTHON=""
  for cmd in python3.11 python3.12 python3.10 python3.9 python3 python; do
    if command -v "$cmd" &>/dev/null; then
      VER=$($cmd --version 2>&1 | grep -oE '[0-9]+[.][0-9]+' | head -1)
      MAJ=$(echo "$VER" | cut -d. -f1)
      MIN=$(echo "$VER" | cut -d. -f2)
      if [ "${MAJ:-0}" -ge 3 ] && [ "${MIN:-0}" -ge 9 ]; then
        SAM_PYTHON="$(command -v $cmd)"
        ok "Python for SAM: $VER at $SAM_PYTHON"
        break
      fi
    fi
  done
  [ -z "$SAM_PYTHON" ] && die "No suitable Python 3.9+ found for SAM build"

  # Prepend the found Python's directory to PATH so SAM resolves it first,
  # and create a 'python3.11' symlink in a temp dir if needed
  SAM_PYTHON_DIR="$(dirname "$SAM_PYTHON")"
  TMPBIN="$(mktemp -d)"
  ln -sf "$SAM_PYTHON" "$TMPBIN/python3.11"
  ln -sf "$SAM_PYTHON" "$TMPBIN/python3"
  ln -sf "$SAM_PYTHON" "$TMPBIN/python"
  export PATH="$TMPBIN:$SAM_PYTHON_DIR:$PATH"

  info "Running sam build..."
  set +e
  sam build 2>&1
  BUILD_EXIT=$?
  set -e
  rm -rf "$TMPBIN"
  if [ "$BUILD_EXIT" -ne 0 ]; then
    die "SAM build failed (exit $BUILD_EXIT). See output above."
  fi
  ok "SAM build succeeded"
  info "SAM deploy (takes 3–5 minutes)…"
  sam deploy --no-confirm-changeset 2>&1 | \
    grep --line-buffered -E "COMPLETE|IN_PROGRESS|FAILED|error|Deploying" | \
    while IFS= read -r line; do
      case "$line" in
        *"COMPLETE"*)    ok   "  $line" ;;
        *"IN_PROGRESS"*) info "  $line" ;;
        *"FAILED"*|*"error"*) warn "  $line" ;;
        *)               info "  $line" ;;
      esac
    done

  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "UNKNOWN")

  if [[ "$STACK_STATUS" == *"COMPLETE"* ]]; then
    ok "Stack deployed successfully: $STACK_STATUS"
  else
    die "Stack deployment failed: $STACK_STATUS\nView events: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION"
  fi

  cd "$PROJECT_DIR"
fi

# Read stack outputs
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null || echo ""
}

API_ENDPOINT=$(get_output "ApiEndpoint")
DASHBOARD_URL=$(get_output "DashboardUrl")
USER_POOL_ID=$(get_output "UserPoolId")
CLIENT_ID=$(get_output "UserPoolClientId")
BUCKET=$($PYTHON -c "
url = '$DASHBOARD_URL'
bucket = url.replace('http://','').split('.')[0]
print(bucket)
")

[ -z "$API_ENDPOINT" ] && die "Could not read ApiEndpoint from stack outputs"

ok "API Endpoint:  $API_ENDPOINT"
ok "Dashboard URL: $DASHBOARD_URL"
ok "User Pool ID:  $USER_POOL_ID"
ok "S3 Bucket:     $BUCKET"

# ──────────────────────────────────────────────────────────────
#  STEP 6 — SEED DYNAMODB (idempotent)
# ──────────────────────────────────────────────────────────────
step "Step 6/8 — Seed DynamoDB"

EMP_COUNT=$(aws dynamodb scan \
  --table-name "workforce_employees_${STAGE}" \
  --region "$REGION" \
  --select COUNT \
  --query "Count" \
  --output text 2>/dev/null || echo "0")

if [ "${EMP_COUNT:-0}" -gt 10 ] 2>/dev/null; then
  skip "DynamoDB already seeded (${EMP_COUNT} employees found)"
else
  info "Seeding 75 dummy employees across 7 departments…"
  cd "$PROJECT_DIR/scripts"
  $PYTHON seed_data.py --region "$REGION" 2>&1 | \
    while IFS= read -r line; do
      case "$line" in
        *"✓"*|*"Done"*|*"Seeding"*) ok   "  $line" ;;
        *"["*)                        info "  $line" ;;
        *"ERROR"*|*"Error"*)          warn "  $line" ;;
      esac
    done
  cd "$PROJECT_DIR"
  ok "DynamoDB seeded"
fi

# ──────────────────────────────────────────────────────────────
#  STEP 7 — AGGREGATION (idempotent)
# ──────────────────────────────────────────────────────────────
step "Step 7/8 — Metric Aggregation"

ANALYTICS_COUNT=$(aws dynamodb scan \
  --table-name "workforce_analytics_${STAGE}" \
  --region "$REGION" \
  --select COUNT \
  --query "Count" \
  --output text 2>/dev/null || echo "0")

if [ "${ANALYTICS_COUNT:-0}" -gt 5 ] 2>/dev/null; then
  skip "Analytics already has data (${ANALYTICS_COUNT} metrics computed)"
else
  info "Invoking aggregation Lambda…"
  aws lambda invoke \
    --function-name "workforce-aggregation-${STAGE}" \
    --region "$REGION" \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/orgiq_agg_response.json \
    --output text > /dev/null 2>&1

  HTTP_CODE=$($PYTHON -c "
import json
try:
    d = json.load(open('/tmp/orgiq_agg_response.json'))
    print(d.get('statusCode', '?'))
except Exception as e:
    print('error: ' + str(e))
")

  if [ "$HTTP_CODE" = "200" ]; then
    ok "Aggregation complete (HTTP 200)"
  else
    warn "Aggregation returned: $HTTP_CODE — check Lambda logs if charts appear empty"
    info "Manual retry: aws lambda invoke --function-name workforce-aggregation-${STAGE} --payload '{}' /tmp/out.json"
  fi
fi

# ──────────────────────────────────────────────────────────────
#  STEP 8 — FRONTEND + COGNITO (idempotent)
# ──────────────────────────────────────────────────────────────
step "Step 8/8 — Frontend & Cognito"

# Patch frontend config with live values
info "Patching frontend/index.html with live API config…"
# Write the patch script to a temp file so bash doesn't interpolate Python code
  PATCH_SCRIPT="/tmp/orgiq_patch_$$.py"
  cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
import re, pathlib, sys, os

html_path = pathlib.Path(os.environ['ORGIQ_HTML'])
api       = os.environ['ORGIQ_API']
pool_id   = os.environ['ORGIQ_POOL_ID']
client_id = os.environ['ORGIQ_CLIENT_ID']
region    = os.environ['ORGIQ_REGION']

html = html_path.read_text()

new_config = (
    "const CONFIG = {\n"
    "  API_BASE: '" + api + "',\n"
    "  COGNITO: {\n"
    "    userPoolId:       '" + pool_id + "',\n"
    "    userPoolClientId: '" + client_id + "',\n"
    "    region:           '" + region + "',\n"
    "  },\n"
    "  ALLOWED_GROUPS: ['HR_Admin', 'Leadership'],\n"
    "  DEMO_MODE: false,\n"
    "};"
)

patched = re.sub(r'const CONFIG = \{.*?\};', new_config, html, flags=re.DOTALL)

if patched == html:
    print("   WARNING: CONFIG block not found or already patched")
    sys.exit(0)

html_path.write_text(patched)
print("   OK: Frontend config patched with live endpoints")
PATCH_EOF

  ORGIQ_HTML="$PROJECT_DIR/frontend/index.html" \
  ORGIQ_API="$API_ENDPOINT" \
  ORGIQ_POOL_ID="$USER_POOL_ID" \
  ORGIQ_CLIENT_ID="$CLIENT_ID" \
  ORGIQ_REGION="$REGION" \
  $PYTHON "$PATCH_SCRIPT"
  rm -f "$PATCH_SCRIPT"

# Upload to S3
info "Uploading dashboard to s3://$BUCKET/..."
set +e
aws s3 sync "$PROJECT_DIR/frontend/" "s3://$BUCKET/" \
  --region "$REGION" \
  --cache-control "max-age=3600" \
  --delete \
  --exclude "*.DS_Store" \
  --exclude ".git/*" 2>&1
S3_EXIT=$?
set -e
if [ "$S3_EXIT" -ne 0 ]; then
  warn "S3 upload exited with code $S3_EXIT — check output above"
else
  ok "Frontend uploaded to s3://$BUCKET/"
fi

# Cognito user (idempotent)
USER_STATUS=$(aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$ADMIN_EMAIL" \
  --region "$REGION" \
  --query "UserStatus" \
  --output text 2>/dev/null || echo "NOT_FOUND")

TEMP_PASS=""
if [ "$USER_STATUS" != "NOT_FOUND" ]; then
  skip "Cognito user already exists ($ADMIN_EMAIL — status: $USER_STATUS)"
else
  TEMP_PASS="OrgIQ@$(date +%Y%m%d)!"
  aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$ADMIN_EMAIL" \
    --temporary-password "$TEMP_PASS" \
    --user-attributes \
      Name=email,Value="$ADMIN_EMAIL" \
      Name=email_verified,Value=true \
    --message-action SUPPRESS \
    --region "$REGION" \
    --output text > /dev/null
  ok "Cognito user created: $ADMIN_EMAIL"

  aws cognito-idp admin-add-user-to-group \
    --user-pool-id "$USER_POOL_ID" \
    --username "$ADMIN_EMAIL" \
    --group-name "HR_Admin" \
    --region "$REGION" 2>/dev/null \
    && ok "Added to HR_Admin group" \
    || warn "Could not add to HR_Admin group — do it manually in Cognito console"
fi

# Save summary file
cat > "$PROJECT_DIR/deployment_summary.txt" << SUMEOF
OrgIQ — Deployment Summary
Generated: $(date)

Dashboard:     $DASHBOARD_URL
API Endpoint:  $API_ENDPOINT
User Pool ID:  $USER_POOL_ID
Client ID:     $CLIENT_ID
S3 Bucket:     $BUCKET
Stack:         $STACK_NAME ($STAGE)
Region:        $REGION
Admin Email:   $ADMIN_EMAIL
Temp Password: ${TEMP_PASS:-see Cognito console}

Re-run:        ./launch.sh        (safe to run again anytime)
Tear down:     ./teardown.sh
Log:           $LOGFILE
SUMEOF

ok "Deployment summary → $PROJECT_DIR/deployment_summary.txt"

# Open browser
$OPEN_BROWSER && open_browser "$DASHBOARD_URL"

# ══════════════════════════════════════════════════════════════════════════
#  FINAL SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GR}${B}"
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║            ✅  DEPLOYMENT COMPLETE!                        ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo -e "${R}"
echo -e "   ${B}Dashboard:${R}  ${CY}$DASHBOARD_URL${R}"
echo -e "   ${B}API:${R}        ${D}$API_ENDPOINT${R}"
echo ""
echo -e "   ${B}Login credentials:${R}"
echo -e "     Email:    $ADMIN_EMAIL"
if [ -n "$TEMP_PASS" ]; then
  echo -e "     Password: $TEMP_PASS  ${YL}← change this on first login${R}"
else
  echo -e "     Password: use your existing Cognito password"
fi
echo ""
echo -e "   ${B}What's deployed:${R}"
echo -e "   ${D}  ✔ 5 DynamoDB tables  ✔ 3 Lambda functions  ✔ API Gateway + Cognito auth"
echo -e "     ✔ S3 static dashboard  ✔ EventBridge (daily 2AM)  ✔ CloudWatch alarms"
echo -e "     ✔ 75 employees seeded  ✔ All metrics pre-computed${R}"
echo ""
echo -e "   ${D}Re-run anytime (idempotent):  ./launch.sh"
echo -e "   Tear down all AWS resources:  ./teardown.sh${R}"
echo ""
