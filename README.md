# OrgIQ — Workforce Intelligence Dashboard.

**Real-time HR analytics platform:** headcount trends, attrition risk scoring, leave utilisation, recruitment funnel, live org chart — all in a single dark-mode dashboard.

---

## Quick Start (choose one)

### Option A — Local Demo (no AWS, 30 seconds)
```bash
python3 run_local.py
```
Opens the full dashboard in your browser instantly. Uses built-in mock data. No account needed.

---

### Option B — Full AWS Deployment (production)
```bash
chmod +x setup.sh
./setup.sh
```
Deploys the complete stack: DynamoDB, Lambda, API Gateway, Cognito, S3, EventBridge, CloudWatch.

---

## Prerequisites

### For Local Demo (Option A)
| Requirement | Check | Install |
|-------------|-------|---------|
| Python 3.10+ | `python3 --version` | [python.org](https://python.org) |

That's it. No other dependencies needed.

---

### For AWS Deployment (Option B)
| Tool | Check | Install |
|------|-------|---------|
| Python 3.10+ | `python3 --version` | [python.org](https://python.org) |
| AWS CLI v2 | `aws --version` | [AWS docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| AWS SAM CLI | `sam --version` | `brew install aws-sam-cli` |
| AWS credentials | `aws sts get-caller-identity` | `aws configure` |

Install all at once on macOS:
```bash
brew install awscli aws-sam-cli
pip3 install boto3 faker
aws configure   # enter your Access Key, Secret Key, region
```

Install all at once on Ubuntu/Debian:
```bash
sudo apt-get install -y python3-pip unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
pip3 install aws-sam-cli boto3 faker
aws configure
```

---

## Option A — Local Demo (detailed)

```bash
# 1. Unzip the project
unzip workforce-analytics.zip
cd workforce-analytics

# 2. Run the local server
python3 run_local.py

# Optional: use a different port
python3 run_local.py --port 8080

# Optional: don't auto-open browser
python3 run_local.py --no-browser
```

**Login:** any non-empty credentials (demo mode accepts anything).
- Email: `hr.admin@demo.com`
- Password: `Demo@1234`

The server runs at `http://localhost:5500`.

---

## Option B — Full AWS Deployment (detailed)

### Step 1 — Unzip and prepare
```bash
unzip workforce-analytics.zip
cd workforce-analytics
```

### Step 2 — Run setup script
```bash
chmod +x setup.sh
./setup.sh
```

The script will:
1. ✓ Check prerequisites (Python, AWS CLI, SAM CLI)
2. ✓ Ask for your admin email
3. ✓ Deploy all AWS infrastructure via SAM (~3-5 min)
4. ✓ Seed DynamoDB with 75 realistic dummy employees
5. ✓ Trigger the first metric aggregation Lambda
6. ✓ Patch the frontend with your live API URL + Cognito IDs
7. ✓ Upload the dashboard to S3
8. ✓ Create your Cognito HR_Admin user

At the end, you'll see:
```
  Dashboard URL:  http://workforce-dashboard-XXXX.s3-website-us-east-1.amazonaws.com
  Login:          hr@yourcompany.com / TempOrgIQ@2025!  (change on first login)
```

### Step 3 — Log in
Visit the dashboard URL, sign in. Cognito will ask you to set a permanent password on first login.

---

## Manual Steps (if you prefer not to use setup.sh)

```bash
# 1. Install Python deps
pip3 install boto3 faker

# 2. Deploy infrastructure
cd infrastructure
sam build
sam deploy --guided   # follow the prompts

# 3. Seed DynamoDB
cd ../scripts
python3 seed_data.py --region us-east-1

# 4. Run first aggregation
aws lambda invoke \
  --function-name workforce-aggregation-prod \
  --payload '{}' /tmp/out.json
cat /tmp/out.json

# 5. Get outputs
aws cloudformation describe-stacks \
  --stack-name workforce-analytics \
  --query "Stacks[0].Outputs" \
  --output table

# 6. Update frontend/index.html CONFIG block with your values:
#    API_BASE, userPoolId, userPoolClientId → set DEMO_MODE: false

# 7. Upload frontend
aws s3 sync frontend/ s3://YOUR-BUCKET-NAME/

# 8. Create Cognito user
aws cognito-idp admin-create-user \
  --user-pool-id YOUR_POOL_ID \
  --username hr@yourcompany.com \
  --temporary-password Temp@1234 \
  --user-attributes Name=email,Value=hr@yourcompany.com Name=email_verified,Value=true

aws cognito-idp admin-add-user-to-group \
  --user-pool-id YOUR_POOL_ID \
  --username hr@yourcompany.com \
  --group-name HR_Admin
```

---

## Project Structure

```
workforce-analytics/
├── setup.sh                    ← Full AWS deployment (one command)
├── teardown.sh                 ← Remove all AWS resources
├── run_local.py                ← Local demo (no AWS)
├── README.md                   ← This file
│
├── frontend/
│   └── index.html              ← Single-page dashboard (S3-hostable)
│
├── lambdas/
│   ├── aggregation/handler.py  ← Daily metrics aggregation (EventBridge)
│   ├── org-chart/handler.py    ← Recursive org tree API
│   └── metrics-api/handler.py  ← All metrics endpoint (?type=all|headcount|…)
│
├── scripts/
│   └── seed_data.py            ← DynamoDB seeder (75 employees)
│
├── infrastructure/
│   └── template.yaml           ← SAM/CloudFormation (5 tables, 3 Lambdas, Cognito, S3)
│
└── docs/
    ├── attrition_formula.md    ← Risk score formula, weights, thresholds
    └── deployment_guide.md     ← Detailed deployment reference
```

---

## Architecture

```
EventBridge (daily 2 AM UTC)
       │
       ▼
Aggregation Lambda
  reads  → Employees, Leave, Performance, Recruitment (DynamoDB)
  writes → Analytics DynamoDB (metric_name PK + date SK)
       │
       ├── Metrics API Lambda  ──┐
       └── Org Chart Lambda   ──┤── API Gateway (Cognito auth)
                                 │
                         S3 Dashboard (index.html)
                         Chart.js × 10 charts + D3 Org Chart
```

---

## Dashboard Tabs

| Tab | Charts / Features |
|-----|-------------------|
| Overview | 5 KPI cards, dept headcount bar, risk doughnut, leave grouped bar, funnel |
| Headcount | Hires vs departures line, stacked dept bar, current split donut |
| Leave | Grouped bar (current vs 3m avg), per-dept utilisation cards |
| Recruitment | Funnel bars, conversion rate cards, drop-off bar chart |
| Attrition Risk | Sortable top-10 risk table with score bars + contributing factors |
| Org Chart | Interactive D3 tree — pan, zoom, hover tooltips |
| System Health | CloudWatch metrics panel, API request volume, Lambda error rate |

---

## Attrition Risk Formula

```
score = (0.35 × f_leave) + (0.35 × f_perf_inv) + (0.20 × f_tenure) + (0.10 × f_absent)
score × 100 → 0–100

Thresholds:   0–30 = LOW  |  31–60 = MEDIUM  |  61–100 = HIGH
```

See `docs/attrition_formula.md` for full factor definitions and examples.

---

## Cost Estimate (~75 employees)

All services stay within AWS Free Tier at this scale. Approximate monthly cost:

| Service | Est. Cost |
|---------|-----------|
| DynamoDB (PAY_PER_REQUEST) | ~$1.50 |
| Lambda (3 fns × ~1K invocations) | Free tier |
| API Gateway (~5K requests) | ~$0.02 |
| S3 (static hosting, ~70KB) | Free tier |
| Cognito (<50 MAU) | Free tier |
| CloudWatch (2 alarms) | ~$0.20 |
| **Total** | **~$2/month** |

---

## Teardown

To remove all AWS resources:
```bash
chmod +x teardown.sh
./teardown.sh
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Dashboard shows blank charts | Run aggregation Lambda manually (Step 4) |
| CORS errors in browser console | Verify `CorsOrigin` in SAM deploy matches your domain |
| Cognito login fails in production | Check `userPoolId` + `userPoolClientId` in `frontend/index.html` CONFIG |
| `sam deploy` fails | Run `aws sts get-caller-identity` — confirm credentials work |
| Aggregation Lambda timeout | Increase `Timeout: 300` → `600` in `infrastructure/template.yaml` |
| Tables already exist error | Re-run seed with `--endpoint` or delete tables first |
| S3 bucket already exists | Change `ACCOUNT_ID` suffix or use a custom bucket name |
