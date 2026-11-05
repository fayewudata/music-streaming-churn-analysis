# Data

Place the five source CSVs here before running the pipeline:

| File | Rows | Grain |
|---|---|---|
| `users.csv` | 50,000 | One row per user |
| `listening_events.csv` | 1,072,063 | One row per play |
| `ad_events.csv` | 310,438 | One row per ad impression |
| `subscription_events.csv` | 104,498 | One row per subscription event (trial exposed/started/expired, paid started, renewal, payment failed, cancel) |
| `feature_table.csv` | 50,000 | One row per user at the April 1, 2026 snapshot, with the 14-day churn label |

The CSVs are not committed: `listening_events.csv` is 123 MB, above GitHub's 100 MB file limit, and the dataset is simulated.

If a source column is renamed, update the matching view in `sql/00_staging.sql`; all other queries read from those views.
