"""
Workforce Analytics — Metrics API Lambda
GET /metrics?type=headcount|leave|recruitment|attrition|all
"""
import boto3, json, os
from datetime import date, datetime
from decimal import Decimal
from collections import defaultdict

ANALYTICS_TABLE = os.environ.get("ANALYTICS_TABLE", "workforce_analytics")
dynamodb        = boto3.resource("dynamodb")
DEPARTMENTS     = ["engineering","product","design","marketing","hr","finance","leadership"]

CORS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Content-Type":                 "application/json",
}

class DecEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Decimal): return float(o)
        return super().default(o)

def get_metric(name, date_str=None):
    table = dynamodb.Table(ANALYTICS_TABLE)
    if date_str:
        r = table.get_item(Key={"metric_name":name,"date":date_str})
        return r.get("Item")
    from boto3.dynamodb.conditions import Key
    r = table.query(KeyConditionExpression=Key("metric_name").eq(name),
                    ScanIndexForward=False, Limit=1)
    items = r.get("Items",[])
    return items[0] if items else None

def fv(item): return float(item["value"]) if item else 0

def headcount():
    today  = date.today()
    months = []
    for i in range(6):
        y, m = today.year, today.month - i
        while m < 1: m += 12; y -= 1
        months.append(f"{y}-{m:02d}")
    months.reverse()

    cur = {d: fv(get_metric(f"headcount_{d}", today.strftime("%Y-%m"))) for d in DEPARTMENTS}
    trend = {}
    for d in DEPARTMENTS:
        trend[d] = {
            "hires":      [fv(get_metric(f"hires_{d}", m))      for m in months],
            "departures": [fv(get_metric(f"departures_{d}", m)) for m in months],
        }
    total = get_metric("headcount_total", today.strftime("%Y-%m"))
    return {"current":cur, "total":fv(total) or sum(cur.values()), "trend":trend, "months":months}

def leave():
    cur_ym = date.today().strftime("%Y-%m")
    depts  = {}
    for d in DEPARTMENTS:
        depts[d] = {
            "current_month_pct": fv(get_metric(f"leave_util_current_{d}", cur_ym)),
            "three_month_avg":   fv(get_metric(f"leave_util_3m_avg_{d}",  cur_ym)),
        }
    return {"departments":depts, "month":cur_ym}

def recruitment():
    cur_ym = date.today().strftime("%Y-%m")
    stages = ["applied","shortlisted","interviewed","offered","joined","rejected"]
    # Raw counts (how many are AT each stage)
    raw = {s: fv(get_metric(f"recruitment_{s}", cur_ym)) for s in stages}
    # Total who ever applied
    total = fv(get_metric("recruitment_total_applied", cur_ym)) or sum(raw[s] for s in stages if s != "rejected")
    # Cumulative counts (how many reached AT LEAST each stage) — used for funnel bars
    cumulative = {
        "applied":     total,
        "shortlisted": fv(get_metric("recruitment_cum_shortlisted", cur_ym)),
        "interviewed": fv(get_metric("recruitment_cum_interviewed", cur_ym)),
        "offered":     fv(get_metric("recruitment_cum_offered",     cur_ym)),
        "joined":      fv(get_metric("recruitment_cum_joined",      cur_ym)),
    }
    rates = {k: fv(get_metric(f"recruitment_{k}", cur_ym))
             for k in ["shortlist_rate","interview_rate","offer_rate","join_rate"]}
    return {"funnel": cumulative, "raw": raw, "conversion_rates": rates, "month": cur_ym}

def attrition():
    cur_ym   = date.today().strftime("%Y-%m")
    top10i   = get_metric("attrition_risk_top10", cur_ym)
    disti    = get_metric("attrition_risk_distribution", cur_ym)
    top10    = json.loads(json.dumps(top10i.get("employees",[]) if top10i else [], cls=DecEncoder))
    dist     = json.loads(json.dumps(disti.get("distribution",{}) if disti else {}, cls=DecEncoder))
    return {"top10":top10, "distribution":dist, "month":cur_ym}

def handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode":200,"headers":CORS,"body":""}
    t = (event.get("queryStringParameters") or {}).get("type","all").lower()
    try:
        payload = ({"headcount":headcount()} if t=="headcount" else
                   {"leave":leave()}          if t=="leave"     else
                   {"recruitment":recruitment()} if t=="recruitment" else
                   {"attrition":attrition()}  if t=="attrition" else
                   {"headcount":headcount(),"leave":leave(),"recruitment":recruitment(),
                    "attrition":attrition(),"generated_at":datetime.utcnow().isoformat()})
        return {"statusCode":200,"headers":CORS,"body":json.dumps(payload, cls=DecEncoder)}
    except Exception as e:
        import traceback; traceback.print_exc()
        return {"statusCode":500,"headers":CORS,"body":json.dumps({"error":str(e)})}

if __name__ == "__main__":
    r = handler({"httpMethod":"GET","queryStringParameters":{"type":"all"}}, None)
    print(json.dumps(json.loads(r["body"]), indent=2)[:2000])
