"""
Workforce Analytics — Health API Lambda
GET /health → real CloudWatch metrics for the last 24 hours

Returns:
  - API Gateway request count (last 24h)
  - Lambda invocation counts per function (last 24h)
  - Lambda error counts + error rate per function
  - Lambda duration P99 (last 24h)
  - DynamoDB consumed read/write capacity
  - Hourly timeseries for API requests and Lambda errors (for charts)
"""

import boto3
import json
import os
from datetime import datetime, timedelta, timezone

REGION     = os.environ.get("AWS_REGION", "us-east-1")
STAGE      = os.environ.get("STAGE", "prod")
API_NAME   = os.environ.get("API_NAME", f"workforce-api-{STAGE}")

LAMBDA_FNS = {
    "Aggregation": f"workforce-aggregation-{STAGE}",
    "Metrics API": f"workforce-metrics-api-{STAGE}",
    "Org Chart":   f"workforce-org-chart-{STAGE}",
}

TABLES = [
    f"workforce_employees_{STAGE}",
    f"workforce_analytics_{STAGE}",
]

cw = boto3.client("cloudwatch", region_name=REGION)

CORS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Content-Type":                 "application/json",
}


# ── CloudWatch query helpers ──────────────────────────────────────────────────

def get_metric_sum(namespace, metric_name, dimensions, hours=24):
    """Sum of a metric over the last N hours."""
    end   = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    try:
        r = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=start,
            EndTime=end,
            Period=hours * 3600,
            Statistics=["Sum"],
        )
        pts = r.get("Datapoints", [])
        return round(pts[0]["Sum"], 2) if pts else 0
    except Exception as e:
        print(f"get_metric_sum error {metric_name}: {e}")
        return 0


def get_metric_avg(namespace, metric_name, dimensions, hours=24):
    """Average of a metric over the last N hours."""
    end   = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    try:
        r = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=start,
            EndTime=end,
            Period=hours * 3600,
            Statistics=["Average"],
        )
        pts = r.get("Datapoints", [])
        return round(pts[0]["Average"], 2) if pts else 0
    except Exception as e:
        print(f"get_metric_avg error {metric_name}: {e}")
        return 0


def get_metric_p99(namespace, metric_name, dimensions, hours=24):
    """P99 of a metric over the last N hours."""
    end   = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    try:
        r = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=start,
            EndTime=end,
            Period=hours * 3600,
            ExtendedStatistics=["p99"],
        )
        pts = r.get("Datapoints", [])
        return round(pts[0]["ExtendedStatistics"]["p99"], 1) if pts else 0
    except Exception as e:
        print(f"get_metric_p99 error {metric_name}: {e}")
        return 0


def get_hourly_timeseries(namespace, metric_name, dimensions, hours=24, stat="Sum"):
    """
    Returns hourly data points for the last 24 hours as two lists:
    labels (HH:00) and values.
    Points are sorted oldest → newest.
    """
    end   = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    start = end - timedelta(hours=hours)
    try:
        r = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=start,
            EndTime=end,
            Period=3600,
            Statistics=[stat],
        )
        pts = sorted(r.get("Datapoints", []), key=lambda x: x["Timestamp"])

        # Build a full 24-slot array — fill gaps with 0
        result = {}
        for p in pts:
            hour_key = p["Timestamp"].strftime("%H:00")
            result[hour_key] = round(p[stat], 2)

        labels, values = [], []
        for h in range(hours):
            t   = start + timedelta(hours=h)
            lbl = t.strftime("%H:00")
            labels.append(lbl)
            values.append(result.get(lbl, 0))

        return labels, values
    except Exception as e:
        print(f"get_hourly_timeseries error {metric_name}: {e}")
        # Return 24 zeros so the frontend still renders cleanly
        labels = [(start + timedelta(hours=h)).strftime("%H:00") for h in range(hours)]
        return labels, [0] * hours


# ── Main data collection ──────────────────────────────────────────────────────

def collect_health():
    now = datetime.now(timezone.utc)

    # ── API Gateway ────────────────────────────────────────────────────────────
    api_dims = [{"Name": "ApiName", "Value": API_NAME}]

    api_requests_24h = get_metric_sum(
        "AWS/ApiGateway", "Count", api_dims
    )
    api_4xx_24h = get_metric_sum(
        "AWS/ApiGateway", "4XXError", api_dims
    )
    api_5xx_24h = get_metric_sum(
        "AWS/ApiGateway", "5XXError", api_dims
    )
    api_latency_p99 = get_metric_p99(
        "AWS/ApiGateway", "Latency", api_dims
    )

    # Hourly timeseries for charts
    hours_labels, api_req_series = get_hourly_timeseries(
        "AWS/ApiGateway", "Count", api_dims
    )
    _, api_err_series = get_hourly_timeseries(
        "AWS/ApiGateway", "5XXError", api_dims
    )

    # ── Lambda functions ───────────────────────────────────────────────────────
    lambda_summary = {}
    total_invocations = 0
    total_errors      = 0
    lambda_err_series_combined = [0] * 24

    for fn_label, fn_name in LAMBDA_FNS.items():
        dims = [{"Name": "FunctionName", "Value": fn_name}]

        invocations = get_metric_sum("AWS/Lambda", "Invocations", dims)
        errors      = get_metric_sum("AWS/Lambda", "Errors",      dims)
        duration_p99 = get_metric_p99("AWS/Lambda", "Duration",   dims)
        throttles   = get_metric_sum("AWS/Lambda", "Throttles",   dims)

        error_rate = round(errors / invocations * 100, 2) if invocations > 0 else 0.0

        lambda_summary[fn_label] = {
            "function_name": fn_name,
            "invocations":   invocations,
            "errors":        errors,
            "error_rate_pct": error_rate,
            "duration_p99_ms": duration_p99,
            "throttles":     throttles,
            "status":        "error" if error_rate > 5 else "warn" if error_rate > 0 else "ok",
        }
        total_invocations += invocations
        total_errors      += errors

        # Add this function's hourly error series to combined
        _, fn_err_series = get_hourly_timeseries("AWS/Lambda", "Errors", dims)
        for i, v in enumerate(fn_err_series):
            lambda_err_series_combined[i] += v

    overall_error_rate = round(total_errors / total_invocations * 100, 2) if total_invocations > 0 else 0.0

    # ── DynamoDB ──────────────────────────────────────────────────────────────
    ddb_reads  = 0
    ddb_writes = 0
    for table in TABLES:
        dims = [{"Name": "TableName", "Value": table}]
        ddb_reads  += get_metric_sum("AWS/DynamoDB", "ConsumedReadCapacityUnits",  dims)
        ddb_writes += get_metric_sum("AWS/DynamoDB", "ConsumedWriteCapacityUnits", dims)

    # ── Last aggregation run ──────────────────────────────────────────────────
    # Check when AggregationFn last had an invocation
    agg_dims = [{"Name": "FunctionName", "Value": LAMBDA_FNS["Aggregation"]}]
    _, agg_inv_series = get_hourly_timeseries("AWS/Lambda", "Invocations", agg_dims)
    last_agg_label = "Never (last 24h)"
    for i in range(len(agg_inv_series) - 1, -1, -1):
        if agg_inv_series[i] > 0:
            hours_ago = len(agg_inv_series) - 1 - i
            last_agg_label = f"{hours_ago}h ago" if hours_ago > 0 else "< 1h ago"
            break

    return {
        "generated_at":    now.isoformat(),
        "api_gateway": {
            "requests_24h":    api_requests_24h,
            "errors_4xx_24h":  api_4xx_24h,
            "errors_5xx_24h":  api_5xx_24h,
            "latency_p99_ms":  api_latency_p99,
            "status":          "error" if api_5xx_24h > 5 else "warn" if api_4xx_24h > 10 else "ok",
        },
        "lambda": {
            "total_invocations_24h": total_invocations,
            "total_errors_24h":      total_errors,
            "overall_error_rate_pct": overall_error_rate,
            "last_aggregation":      last_agg_label,
            "functions":             lambda_summary,
        },
        "dynamodb": {
            "read_units_24h":  ddb_reads,
            "write_units_24h": ddb_writes,
        },
        "timeseries": {
            "hours":            hours_labels,
            "api_requests":     api_req_series,
            "api_errors":       api_err_series,
            "lambda_errors":    lambda_err_series_combined,
        },
    }


# ── Handler ───────────────────────────────────────────────────────────────────

def handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return {"statusCode": 200, "headers": CORS, "body": ""}
    try:
        data = collect_health()
        return {
            "statusCode": 200,
            "headers":    CORS,
            "body":       json.dumps(data),
        }
    except Exception as e:
        import traceback; traceback.print_exc()
        return {
            "statusCode": 500,
            "headers":    CORS,
            "body":       json.dumps({"error": str(e)}),
        }


if __name__ == "__main__":
    result = handler({"httpMethod": "GET"}, None)
    print(json.dumps(json.loads(result["body"]), indent=2))
