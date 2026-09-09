# US bank holidays — for the D-000 trend/anomaly check

The anomaly check (Step 3.5) uses this list for two things:

1. **Suppress** — if the target day (`EXPECTED_MAX`) is a US bank holiday or a
   weekend, marketing activity is expected to be low (PPL revenue is ~0 and PPL
   cost tiny; several channels — e.g. Partners, Paid Social — drop to near-zero).
   A low day here is normal, so anomaly flags are suppressed, not raised.
2. **Clean the baseline** — holidays are excluded from the trailing same-weekday
   baseline so a holiday that lands on the compared weekday (e.g. Labor Day on a
   Monday) doesn't drag the "normal" band down and mask a real problem on later
   same-weekday runs.

**Why US holidays specifically:** the GDM channel data follows the US marketing
calendar (verified in `GARTNER_GDM` — e.g. Labor Day 2026-09-07 shows Partners
revenue = $0 and Organic Search −60% vs. surrounding Mondays). IST/other holidays
do **not** show this effect and are intentionally not listed.

Weekends are handled in SQL directly (`DAYOFWEEK NOT IN (0,6)`), so only the
holiday **dates** live here. Keep this list current — add the next year before
January, and include the **observed** date when a holiday falls on a weekend
(e.g. Jul 4 2026 is a Saturday → observed Fri Jul 3).

## Holiday dates (federal, observed)

| Date         | Holiday                     |
|--------------|-----------------------------|
| 2025-01-01   | New Year's Day              |
| 2025-01-20   | MLK Jr. Day                 |
| 2025-02-17   | Presidents' Day             |
| 2025-05-26   | Memorial Day                |
| 2025-06-19   | Juneteenth                  |
| 2025-07-04   | Independence Day            |
| 2025-09-01   | Labor Day                   |
| 2025-11-11   | Veterans Day                |
| 2025-11-27   | Thanksgiving                |
| 2025-12-25   | Christmas Day               |
| 2026-01-01   | New Year's Day              |
| 2026-01-19   | MLK Jr. Day                 |
| 2026-02-16   | Presidents' Day             |
| 2026-05-25   | Memorial Day                |
| 2026-06-19   | Juneteenth                  |
| 2026-07-03   | Independence Day (observed) |
| 2026-09-07   | Labor Day                   |
| 2026-11-11   | Veterans Day                |
| 2026-11-26   | Thanksgiving                |
| 2026-12-25   | Christmas Day               |

The `holidays` CTE at the top of `anomaly.sql` must match this table. When you add
a year here, add the same dates to that CTE (they are independent — no automatic
sharing).
