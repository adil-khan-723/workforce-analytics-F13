"""
Workforce Analytics — DynamoDB Data Seeding Script
Populates 5 DynamoDB tables with realistic dummy data for 75 employees.

Usage:
    pip install boto3 faker
    python seed_data.py --region us-east-1
    python seed_data.py --endpoint http://localhost:8000   # local DynamoDB
"""

import boto3, os, random, json, argparse
from datetime import date, timedelta, datetime
from decimal import Decimal
from faker import Faker

fake = Faker('en_IN')
random.seed(42)

# ── TABLE NAMES ──────────────────────────────────────────────────────────────
# Stage suffix must match what SAM deployed (Stage=prod → table names end with _prod)
STAGE = os.environ.get("STAGE", "prod")
TABLES = {
    "employees":   f"workforce_employees_{STAGE}",
    "leave":       f"workforce_leave_records_{STAGE}",
    "performance": f"workforce_performance_{STAGE}",
    "recruitment": f"workforce_recruitment_{STAGE}",
    "analytics":   f"workforce_analytics_{STAGE}",
}

# ── DEPARTMENTS ──────────────────────────────────────────────────────────────
DEPARTMENTS = {
    "engineering": 22,
    "product":     10,
    "design":       8,
    "marketing":   12,
    "hr":           8,
    "finance":      8,
    "leadership":   7,
}

ROLES = {
    "engineering": ["Software Engineer","Senior Software Engineer","Staff Engineer",
                    "Engineering Manager","DevOps Engineer","QA Engineer","Data Engineer"],
    "product":     ["Product Manager","Senior Product Manager","Director of Product","Product Analyst"],
    "design":      ["UX Designer","Senior UX Designer","UI Designer","Design Lead","UX Researcher"],
    "marketing":   ["Marketing Manager","Content Strategist","Growth Analyst",
                    "Brand Designer","SEO Specialist","Marketing Director"],
    "hr":          ["HR Business Partner","Talent Acquisition Specialist","HR Manager",
                    "Compensation Analyst","L&D Manager"],
    "finance":     ["Financial Analyst","Senior Financial Analyst","Finance Manager",
                    "Controller","Accountant","FP&A Analyst"],
    "leadership":  ["CEO","CTO","CPO","CFO","CMO","VP Engineering","Chief of Staff"],
}

SALARY_BASE = {
    "engineering": 90000, "product": 95000, "design": 80000,
    "marketing": 75000, "hr": 70000, "finance": 85000, "leadership": 140000,
}

LOCATIONS = ["Bangalore","Mumbai","Delhi","Hyderabad","Pune","Chennai","Remote"]
ANNUAL_QUOTA = 21

# ── HELPERS ──────────────────────────────────────────────────────────────────
def rand_date(start: date, end: date) -> str:
    return (start + timedelta(days=random.randint(0, (end - start).days))).isoformat()

def dec(v): return Decimal(str(round(float(v), 4)))

def create_tables(dynamodb):
    existing = {t.name for t in dynamodb.tables.all()}
    defs = [
        {"TableName": TABLES["employees"],
         "KeySchema": [{"AttributeName":"employee_id","KeyType":"HASH"}],
         "AttributeDefinitions": [{"AttributeName":"employee_id","AttributeType":"S"}],
         "BillingMode": "PAY_PER_REQUEST"},
        {"TableName": TABLES["leave"],
         "KeySchema": [{"AttributeName":"record_id","KeyType":"HASH"},
                       {"AttributeName":"employee_id","KeyType":"RANGE"}],
         "AttributeDefinitions": [{"AttributeName":"record_id","AttributeType":"S"},
                                   {"AttributeName":"employee_id","AttributeType":"S"}],
         "BillingMode": "PAY_PER_REQUEST"},
        {"TableName": TABLES["performance"],
         "KeySchema": [{"AttributeName":"employee_id","KeyType":"HASH"},
                       {"AttributeName":"review_date","KeyType":"RANGE"}],
         "AttributeDefinitions": [{"AttributeName":"employee_id","AttributeType":"S"},
                                   {"AttributeName":"review_date","AttributeType":"S"}],
         "BillingMode": "PAY_PER_REQUEST"},
        {"TableName": TABLES["recruitment"],
         "KeySchema": [{"AttributeName":"applicant_id","KeyType":"HASH"},
                       {"AttributeName":"applied_date","KeyType":"RANGE"}],
         "AttributeDefinitions": [{"AttributeName":"applicant_id","AttributeType":"S"},
                                   {"AttributeName":"applied_date","AttributeType":"S"}],
         "BillingMode": "PAY_PER_REQUEST"},
        {"TableName": TABLES["analytics"],
         "KeySchema": [{"AttributeName":"metric_name","KeyType":"HASH"},
                       {"AttributeName":"date","KeyType":"RANGE"}],
         "AttributeDefinitions": [{"AttributeName":"metric_name","AttributeType":"S"},
                                   {"AttributeName":"date","AttributeType":"S"}],
         "BillingMode": "PAY_PER_REQUEST"},
    ]
    for d in defs:
        if d["TableName"] in existing:
            print(f"  ⚠  {d['TableName']} exists — skipping")
        else:
            t = dynamodb.create_table(**d)
            t.wait_until_exists()
            print(f"  ✓  {d['TableName']}")

# ── EMPLOYEE GENERATION ───────────────────────────────────────────────────────
def generate_employees():
    employees, eid, today = [], 1, date.today()
    start = today - timedelta(days=365 * 5)
    dept_managers = {}

    for dept, count in DEPARTMENTS.items():
        for i in range(count):
            emp_id = f"EMP{eid:04d}"
            hire   = date.fromisoformat(rand_date(start, today - timedelta(days=30)))
            tenure = (today.year - hire.year) * 12 + (today.month - hire.month)
            is_mgr = (i == 0)
            mgr_id = dept_managers.get(dept)
            if is_mgr:
                dept_managers[dept] = emp_id
            if dept == "leadership":
                mgr_id = None

            left   = random.random() < 0.10
            salary = random.randint(SALARY_BASE[dept], int(SALARY_BASE[dept] * 1.6))

            emp = {
                "employee_id":      emp_id,
                "name":             fake.name(),
                "email":            fake.company_email(),
                "department":       dept,
                "role":             random.choice(ROLES[dept]),
                "hire_date":        hire.isoformat(),
                "tenure_months":    tenure,
                "salary":           salary,
                "manager_id":       mgr_id,
                "status":           "inactive" if left else "active",
                "leave_date":       (hire + timedelta(days=random.randint(365, max(366, tenure*28)))).isoformat() if left else None,
                "leave_days_taken": random.randint(0, 25),
                "location":         random.choice(LOCATIONS),
                "gender":           random.choice(["M","F","Non-binary"]),
                "created_at":       datetime.utcnow().isoformat(),
            }
            employees.append(emp)
            eid += 1
    return employees

def seed_employees(table, employees):
    with table.batch_writer() as b:
        for e in employees:
            item = {k: dec(v) if isinstance(v, float) else v
                    for k, v in e.items() if v is not None}
            b.put_item(Item=item)
    print(f"  ✓  {len(employees)} employees")

def seed_leave(table, employees):
    today, jan1, rid = date.today(), date(date.today().year, 1, 1), 1
    recs = []
    for emp in employees:
        if emp["status"] == "inactive": continue
        for _ in range(random.randint(2, 6)):
            lt    = random.choice(["annual","sick","casual"])
            start = date.fromisoformat(rand_date(jan1, today - timedelta(days=5)))
            dur   = random.randint(1, 5)
            recs.append({
                "record_id":   f"LVR{rid:05d}",
                "employee_id": emp["employee_id"],
                "department":  emp["department"],
                "leave_type":  lt,
                "start_date":  start.isoformat(),
                "end_date":    (start + timedelta(days=dur-1)).isoformat(),
                "days":        dur,
                "status":      random.choice(["approved","approved","approved","pending"]),
                "year":        str(today.year),
            })
            rid += 1
    with table.batch_writer() as b:
        for r in recs: b.put_item(Item=r)
    print(f"  ✓  {len(recs)} leave records")

def seed_performance(table, employees):
    today, reviews = date.today(), []
    for emp in employees:
        nr = random.randint(1, min(4, max(1, emp["tenure_months"] // 3)))
        for q in range(nr):
            score = max(1.0, min(5.0, round(random.gauss(3.2, 0.8), 1)))
            reviews.append({
                "employee_id": emp["employee_id"],
                "review_date": (today - timedelta(days=90*q)).isoformat(),
                "department":  emp["department"],
                "score":       dec(score),
                "quarter":     f"Q{(today.month//3 - q) % 4 + 1}",
            })
    with table.batch_writer() as b:
        for r in reviews: b.put_item(Item=r)
    print(f"  ✓  {len(reviews)} performance reviews")

def seed_recruitment(table):
    today, start = date.today(), date.today() - timedelta(days=180)
    recs = []
    for i in range(120):
        applied = rand_date(start, today - timedelta(days=7))
        roll    = random.random()
        stage   = ("rejected" if roll<.25 else "shortlisted" if roll<.50 else
                   "interviewed" if roll<.70 else "offered" if roll<.82 else
                   "joined" if roll<.92 else "applied")
        dept    = random.choice(list(DEPARTMENTS.keys()))
        recs.append({
            "applicant_id":  f"APP{i+1:05d}",
            "applied_date":  applied,
            "name":          fake.name(),
            "email":         fake.email(),
            "department":    dept,
            "role":          random.choice(ROLES[dept]),
            "current_stage": stage,
            "source":        random.choice(["LinkedIn","Referral","JobPortal","Company Site","Agency"]),
        })
    with table.batch_writer() as b:
        for r in recs: b.put_item(Item=r)
    print(f"  ✓  {len(recs)} recruitment records")

# ── MAIN ─────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--region",   default="us-east-1")
    parser.add_argument("--endpoint", default=None)
    args = parser.parse_args()

    kw = {"region_name": args.region}
    if args.endpoint: kw["endpoint_url"] = args.endpoint
    db = boto3.resource("dynamodb", **kw)

    print("\n🌱  Workforce Analytics — Seeder")
    print("=" * 40)
    print("\n[1] Creating tables…")
    create_tables(db)
    print("\n[2] Generating & seeding employees…")
    employees = generate_employees()
    seed_employees(db.Table(TABLES["employees"]), employees)
    print("\n[3] Seeding leave records…")
    seed_leave(db.Table(TABLES["leave"]), employees)
    print("\n[4] Seeding performance…")
    seed_performance(db.Table(TABLES["performance"]), employees)
    print("\n[5] Seeding recruitment…")
    seed_recruitment(db.Table(TABLES["recruitment"]))
    print("\n✅  Done! Tables ready for aggregation Lambda.\n")

    with open("employees_seed.json","w") as f:
        json.dump(employees, f, indent=2, default=str)
    print("📄  employees_seed.json written.\n")

if __name__ == "__main__":
    main()
