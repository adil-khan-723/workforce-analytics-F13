# Deployment Guide

## Prerequisites
- Python 3.12+, AWS CLI v2, AWS SAM CLI, boto3, faker

## Step 1 — Deploy Infrastructure
```bash
cd infrastructure/
sam build
sam deploy --guided --stack-name workforce-analytics \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides Stage=prod AdminEmail=hr@company.com
```
Save outputs: ApiEndpoint, UserPoolId, UserPoolClientId, DashboardUrl

## Step 2 — Seed Data
```bash
pip install boto3 faker
cd scripts/
python seed_data.py --region us-east-1
```

## Step 3 — First Aggregation
```bash
aws lambda invoke --function-name workforce-aggregation-prod \
  --payload '{}' /tmp/out.json && cat /tmp/out.json
```

## Step 4 — Deploy Frontend
Update CONFIG in frontend/index.html:
```javascript
const CONFIG = {
  API_BASE: 'https://YOUR_API_ID.execute-api.us-east-1.amazonaws.com/prod',
  COGNITO: { userPoolId: 'us-east-1_XXX', userPoolClientId: 'XXX', region: 'us-east-1' },
  DEMO_MODE: false,
};
```
Upload:
```bash
aws s3 sync frontend/ s3://workforce-dashboard-ACCOUNTID-prod/
```

## Step 5 — Create Cognito User
```bash
POOL=$(aws cloudformation describe-stacks --stack-name workforce-analytics \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)

aws cognito-idp admin-create-user --user-pool-id $POOL \
  --username hr@company.com --temporary-password Temp@1234 \
  --user-attributes Name=email,Value=hr@company.com

aws cognito-idp admin-add-user-to-group --user-pool-id $POOL \
  --username hr@company.com --group-name HR_Admin
```

## Architecture
```
EventBridge (daily 2AM UTC)
  └─► AggregationLambda
        ├─ reads: Employees, Leave, Performance, Recruitment (DynamoDB)
        └─ writes: Analytics (DynamoDB)
              ├─► MetricsAPI Lambda ─► API Gateway ─► Dashboard (S3)
              └─► OrgChart Lambda  ─►     │              ▲
                                    Cognito Auth ────────┘
```

## Cost (~$2/month for 75 employees)
DynamoDB + Lambda + API Gateway + S3 + Cognito all within free tier limits.
