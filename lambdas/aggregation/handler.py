"""
Workforce Analytics — Aggregation Lambda
Triggered daily by EventBridge. Reads source tables, computes metrics,
writes to workforce_analytics DynamoDB table.

Attrition Risk Formula:
  score = (0.35 * f_leave) + (0.35 * f_perf_inv) + (0.20 * f_tenure) + (0.10 * f_absent)
  × 100 → 0–100 score

  f_leave      = clamp(leave_days / 21 / 1.5)            # 0–1
  f_perf_inv   = clamp((5.0 - avg_score) / 4.0)          # 0–1, inverted
  f_tenure     = U-shaped: new/very long tenure = high risk
  f_absent     = clamp(leave_event_count / 10.0)          # 0–1

Thresholds: 0–30 LOW | 31–60 MEDIUM | 61–100 HIGH
"""

import boto3, json, os
from datetime import date, datetime
from decimal import Decimal
from collections import defaultdict

EMPLOYEES_TABLE   = os.environ.get("EMPLOYEES_TABLE",   "workforce_employees")
LEAVE_TABLE       = os.environ.get("LEAVE_TABLE",       "workforce_leave_records")
PERFORMANCE_TABLE = os.environ.get("PERFORMANCE_TABLE", "workforce_performance")
RECRUITMENT_TABLE = os.environ.get("RECRUITMENT_TABLE", "workforce_recruitment")
ANALYTICS_TABLE   = os.environ.get("ANALYTICS_TABLE",   "workforce_analytics")

WEIGHTS      = {"leave_ratio": 0.35, "perf_inverse": 0.35, "tenure_risk": 0.20, "absence_freq": 0.10}
ANNUAL_QUOTA = 21
DEPARTMENTS  = ["engineering","product","design","marketing","hr","finance","leadership"]

dynamodb = boto3.resource("dynamodb")

# ── HELPERS ──────────────────────────────────────────────────────────────────
def scan_all(table_name):
    table, items, last_key = dynamodb.Table(table_name), [], None
    while True:
        kw = {"ExclusiveStartKey": last_key} if last_key else {}
        r  = table.scan(**kw)
        items.extend(r.get("Items", []))
        last_key = r.get("LastEvaluatedKey")
        if not last_key: break
    return items

def clamp(v, lo=0.0, hi=1.0): return max(lo, min(hi, float(v)))
def dec(v): return Decimal(str(round(float(v), 4)))

def write_metric(table, name, date_str, value, extra=None):
    def cvt(v):
        if isinstance(v, float): return dec(v)
        if isinstance(v, dict):  return {k: cvt(vv) for k, vv in v.items()}
        if isinstance(v, list):  return [cvt(i) for i in v]
        return v
    item = {
        "metric_name": name,
        "date":        date_str,
        "value":       dec(value) if isinstance(value, (int, float)) else value,
        "computed_at": datetime.utcnow().isoformat(),
    }
    if extra:
        for k, v in extra.items():
            item[k] = cvt(v)
    table.put_item(Item=item)

# ── METRICS ──────────────────────────────────────────────────────────────────
def headcount_metrics(employees, today_str, tbl):
    counts = defaultdict(int)
    for e in employees:
        if e.get("status") == "active":
            counts[e["department"]] += 1
    for d, c in counts.items():
        write_metric(tbl, f"headcount_{d}", today_str, c)
    write_metric(tbl, "headcount_total", today_str, sum(counts.values()))
    return counts

def hires_departures(employees, tbl):
    today = date.today()
    months = []
    for i in range(12):
        y, m = today.year, today.month - i
        while m < 1: m += 12; y -= 1
        months.append(f"{y}-{m:02d}")

    hires = defaultdict(lambda: defaultdict(int))
    deps  = defaultdict(lambda: defaultdict(int))

    for e in employees:
        hm = e["hire_date"][:7]
        if hm in months: hires[hm][e["department"]] += 1
        if e.get("leave_date"):
            dm = e["leave_date"][:7]
            if dm in months: deps[dm][e["department"]] += 1

    for m in months:
        for d in DEPARTMENTS:
            write_metric(tbl, f"hires_{d}", m,      hires[m].get(d, 0))
            write_metric(tbl, f"departures_{d}", m, deps[m].get(d, 0))

def leave_utilisation(employees, leave_records, tbl):
    today  = date.today()
    cur_ym = today.strftime("%Y-%m")
    m3_set = set()
    for i in range(3):
        y, m = today.year, today.month - i
        while m < 1: m += 12; y -= 1
        m3_set.add(f"{y}-{m:02d}")

    dept_quota  = defaultdict(int)
    dept_active = defaultdict(int)
    for e in employees:
        if e.get("status") == "active":
            dept_active[e["department"]] += 1
            dept_quota[e["department"]] += ANNUAL_QUOTA

    cur_days = defaultdict(int)
    avg_days = defaultdict(int)
    for r in leave_records:
        mo   = r.get("start_date","")[:7]
        days = int(r.get("days", 0))
        dept = r.get("department","")
        if mo == cur_ym:  cur_days[dept] += days
        if mo in m3_set:  avg_days[dept] += days

    for d in dept_active:
        mq = dept_quota[d] / 12
        if mq == 0: continue
        write_metric(tbl, f"leave_util_current_{d}", cur_ym, round(clamp(cur_days[d]/mq*100, 0, 200), 1))
        write_metric(tbl, f"leave_util_3m_avg_{d}",  cur_ym, round(clamp((avg_days[d]/3)/mq*100, 0, 200), 1))

def recruitment_funnel(recruitment, tbl):
    """
    Each applicant sits at their CURRENT stage only.
    We store both raw stage counts AND cumulative counts so the
    frontend can render a proper funnel where every bar <= the one above.

    Cumulative logic:
      total_applied   = everyone who ever applied (all stages except rejected)
      cum_shortlisted = shortlisted + interviewed + offered + joined
      cum_interviewed = interviewed + offered + joined
      cum_offered     = offered + joined
      cum_joined      = joined

    Conversion rates:
      shortlist_rate = cum_shortlisted / total_applied
      interview_rate = cum_interviewed / cum_shortlisted
      offer_rate     = cum_offered     / cum_interviewed
      join_rate      = cum_joined      / cum_offered
    """
    today  = date.today()
    cur_ym = today.strftime("%Y-%m")
    stages = ["applied","shortlisted","interviewed","offered","joined","rejected"]
    counts = defaultdict(int)
    for a in recruitment:
        if a.get("applied_date","")[:7] <= cur_ym:
            counts[a.get("current_stage","applied")] += 1

    # Raw stage counts (how many are AT each stage right now)
    for s in stages:
        write_metric(tbl, f"recruitment_{s}", cur_ym, counts.get(s, 0))

    # Total who ever applied = everyone except rejected
    total_applied = sum(counts[s] for s in ["applied","shortlisted","interviewed","offered","joined"])
    write_metric(tbl, "recruitment_total_applied", cur_ym, total_applied)

    # Cumulative counts (how many reached AT LEAST each stage)
    cum_shortlisted = counts["shortlisted"] + counts["interviewed"] + counts["offered"] + counts["joined"]
    cum_interviewed = counts["interviewed"] + counts["offered"] + counts["joined"]
    cum_offered     = counts["offered"]     + counts["joined"]
    cum_joined      = counts["joined"]

    write_metric(tbl, "recruitment_cum_shortlisted", cur_ym, cum_shortlisted)
    write_metric(tbl, "recruitment_cum_interviewed", cur_ym, cum_interviewed)
    write_metric(tbl, "recruitment_cum_offered",     cur_ym, cum_offered)
    write_metric(tbl, "recruitment_cum_joined",      cur_ym, cum_joined)

    # Correct conversion rates
    if total_applied > 0:
        write_metric(tbl, "recruitment_shortlist_rate", cur_ym,
            round(cum_shortlisted / total_applied * 100, 1))
    if cum_shortlisted > 0:
        write_metric(tbl, "recruitment_interview_rate", cur_ym,
            round(cum_interviewed / cum_shortlisted * 100, 1))
    if cum_interviewed > 0:
        write_metric(tbl, "recruitment_offer_rate", cur_ym,
            round(cum_offered / cum_interviewed * 100, 1))
    if cum_offered > 0:
        write_metric(tbl, "recruitment_join_rate", cur_ym,
            round(cum_joined / cum_offered * 100, 1))

def attrition_risk(employees, leave_records, performance, tbl):
    today_str = date.today().strftime("%Y-%m")
    emp_leaves = defaultdict(list)
    for r in leave_records: emp_leaves[r["employee_id"]].append(r)

    emp_scores = defaultdict(list)
    for r in performance:
        try: emp_scores[r["employee_id"]].append(float(r["score"]))
        except: pass

    risks = []
    for e in employees:
        if e.get("status") != "active": continue
        eid    = e["employee_id"]
        tenure = int(e.get("tenure_months", 12))
        ld     = int(e.get("leave_days_taken", 0))

        f_leave  = clamp(ld / ANNUAL_QUOTA / 1.5)
        scores   = emp_scores.get(eid, [])
        avg_sc   = sum(scores)/len(scores) if scores else 3.0
        f_perf   = clamp((5.0 - avg_sc) / 4.0)
        f_tenure = (1.0 if tenure<3 else 0.75 if tenure<12 else
                    0.20 if tenure<36 else 0.35 if tenure<48 else 0.60)
        f_absent = clamp(len(emp_leaves.get(eid, [])) / 10.0)

        score_100 = round((WEIGHTS["leave_ratio"]*f_leave + WEIGHTS["perf_inverse"]*f_perf +
                           WEIGHTS["tenure_risk"]*f_tenure + WEIGHTS["absence_freq"]*f_absent) * 100, 1)
        level = "high" if score_100>=61 else "medium" if score_100>=31 else "low"

        risks.append({
            "employee_id": eid,
            "name":        e.get("name",""),
            "department":  e.get("department",""),
            "role":        e.get("role",""),
            "risk_score":  score_100,
            "risk_level":  level,
            "factors": {
                "leave_days":      ld,
                "avg_perf_score":  round(avg_sc, 2),
                "tenure_months":   tenure,
                "leave_events":    len(emp_leaves.get(eid, [])),
                "f_leave":         round(f_leave*100, 1),
                "f_perf":          round(f_perf*100, 1),
                "f_tenure":        round(f_tenure*100, 1),
                "f_absent":        round(f_absent*100, 1),
            },
        })

    risks.sort(key=lambda x: x["risk_score"], reverse=True)
    dist = defaultdict(int)
    for r in risks: dist[r["risk_level"]] += 1

    write_metric(tbl, "attrition_risk_top10",        today_str, len(risks[:10]),
                 {"employees": risks[:10]})
    write_metric(tbl, "attrition_risk_distribution", today_str, len(risks),
                 {"distribution": dict(dist)})
    print(f"  Attrition: high={dist['high']} medium={dist['medium']} low={dist['low']}")

# ── HANDLER ──────────────────────────────────────────────────────────────────
def handler(event, context):
    today_str = date.today().strftime("%Y-%m")
    print(f"🔄  Aggregation Lambda — {today_str}")
    tbl = dynamodb.Table(ANALYTICS_TABLE)

    print("[1] Loading employees…")
    employees   = scan_all(EMPLOYEES_TABLE)
    print(f"    {len(employees)} loaded")
    leave       = scan_all(LEAVE_TABLE)
    performance = scan_all(PERFORMANCE_TABLE)
    recruitment = scan_all(RECRUITMENT_TABLE)

    print("[2] Computing metrics…")
    headcount_metrics(employees, today_str, tbl)
    hires_departures(employees, tbl)
    leave_utilisation(employees, leave, tbl)
    recruitment_funnel(recruitment, tbl)
    attrition_risk(employees, leave, performance, tbl)

    print("✅  Aggregation complete")
    return {"statusCode": 200, "body": json.dumps({"status":"ok","date":today_str})}

if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", default=None)
    p.add_argument("--region",   default="us-east-1")
    a = p.parse_args()
    if a.endpoint:
        dynamodb = boto3.resource("dynamodb", region_name=a.region, endpoint_url=a.endpoint)
    handler({}, None)
