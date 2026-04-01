"""
Workforce Analytics — Org Chart Lambda
GET /org-chart → nested JSON tree for D3 rendering
"""
import boto3, json, os
from datetime import datetime
from collections import defaultdict

EMPLOYEES_TABLE = os.environ.get("EMPLOYEES_TABLE", "workforce_employees")
dynamodb        = boto3.resource("dynamodb")

CORS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Content-Type":                 "application/json",
}

def scan_all(table_name):
    table, items, last_key = dynamodb.Table(table_name), [], None
    while True:
        kw = {"ExclusiveStartKey": last_key} if last_key else {}
        r  = table.scan(**kw)
        items.extend(r.get("Items", []))
        last_key = r.get("LastEvaluatedKey")
        if not last_key: break
    return items

def build_tree(employees):
    emp_map      = {}
    children_map = defaultdict(list)
    roots        = []

    for e in employees:
        if e.get("status") != "active": continue
        eid = e["employee_id"]
        emp_map[eid] = {
            "id":            eid,
            "name":          e.get("name",""),
            "role":          e.get("role",""),
            "department":    e.get("department",""),
            "tenure_months": int(e.get("tenure_months", 0)),
            "location":      e.get("location",""),
            "_manager_id":   e.get("manager_id"),
        }

    all_ids = set(emp_map)
    for eid, emp in emp_map.items():
        mgr = emp.get("_manager_id")
        if mgr and mgr in all_ids: children_map[mgr].append(eid)
        else: roots.append(eid)

    visited = set()
    def build(eid, depth=0):
        if eid in visited or depth > 12:
            return emp_map[eid] | {"children": []}
        visited.add(eid)
        node = {k: v for k, v in emp_map[eid].items() if k != "_manager_id"}
        node["children"] = [build(c, depth+1) for c in sorted(children_map.get(eid, []))]
        return node

    if not roots: return None
    if len(roots) == 1: return build(roots[0])
    return {"id":"ROOT","name":"Organisation","role":"","department":"","children":[build(r) for r in sorted(roots)]}

def count_nodes(tree):
    if not tree: return 0
    return 1 + sum(count_nodes(c) for c in tree.get("children",[]))

def handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode":200, "headers":CORS, "body":""}
    try:
        employees  = scan_all(EMPLOYEES_TABLE)
        tree       = build_tree(employees)
        return {
            "statusCode": 200,
            "headers":    CORS,
            "body": json.dumps({
                "tree":       tree,
                "node_count": count_nodes(tree),
                "generated":  datetime.utcnow().isoformat(),
            }),
        }
    except Exception as e:
        print(f"ERROR: {e}")
        return {"statusCode":500,"headers":CORS,"body":json.dumps({"error":str(e)})}

if __name__ == "__main__":
    import argparse, pprint
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", default=None)
    a = p.parse_args()
    if a.endpoint:
        dynamodb = boto3.resource("dynamodb", endpoint_url=a.endpoint)
    r = handler({"httpMethod":"GET"}, None)
    t = json.loads(r["body"])
    print(f"Nodes: {t['node_count']}")
    pprint.pprint(t["tree"], depth=3)
