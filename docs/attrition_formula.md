# Attrition Risk Scoring Formula

## Score Range: 0–100

```
score = (0.35 × f_leave) + (0.35 × f_perf_inv) + (0.20 × f_tenure) + (0.10 × f_absent)
score = score × 100
```

## Factor Definitions

| Factor | Weight | Formula | Rationale |
|--------|--------|---------|-----------|
| `f_leave`    | 35% | `clamp(leave_days / 21 / 1.5)` | High leave usage signals burnout/disengagement |
| `f_perf_inv` | 35% | `clamp((5.0 - avg_score) / 4.0)` | Low performance predicts voluntary/involuntary exits |
| `f_tenure`   | 20% | U-shaped (see table below) | New joiners + long-tenured both at higher risk |
| `f_absent`   | 10% | `clamp(leave_events / 10.0)` | Many small absences = fragmented attendance |

## Tenure Risk Bands (f_tenure)

| Tenure | Score | Reason |
|--------|-------|--------|
| < 3 months  | 1.00 | Onboarding failure risk |
| 3–11 months | 0.75 | Still settling, moderate risk |
| 12–35 months| 0.20 | Stable zone |
| 36–47 months| 0.35 | Mid-career drift |
| ≥ 48 months | 0.60 | Ceiling risk / market pull |

## Thresholds

| Score | Level  | Action |
|-------|--------|--------|
| 0–30  | 🟢 Low    | Standard quarterly check-in |
| 31–60 | 🟡 Medium | 1:1 within 2 weeks |
| 61–100| 🔴 High   | Immediate HR intervention (72h) |

## Example

Employee: tenure=4m, leave=19d, perf=2.1, events=7

```
f_leave  = min(19/21/1.5, 1) = 0.603
f_perf   = (5-2.1)/4         = 0.725
f_tenure = 0.75               (3–11m band)
f_absent = 7/10               = 0.700

score = (0.35×0.603)+(0.35×0.725)+(0.20×0.75)+(0.10×0.700)
      = 0.211 + 0.254 + 0.150 + 0.070 = 0.685 × 100 = 68.5 → HIGH 🔴
```
