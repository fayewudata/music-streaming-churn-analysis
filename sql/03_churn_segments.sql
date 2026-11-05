-- =====================================================================
-- 03_churn_segments.sql
-- Churn by acquisition channel, plan, and lifecycle stage.
--
-- Two different questions:
--   churn_rate_pct       -> how likely is a user in this segment to churn?
--   overrepresentation   -> share of churners / share of users.
--                           Above 1.0 means the segment makes up more of
--                           the churn problem than of the user base.
-- =====================================================================

CREATE OR REPLACE VIEW segment_churn AS
WITH long AS (
    SELECT 'acquisition_channel' AS dimension, acquisition_channel AS segment, churned_14d FROM stg_users
    UNION ALL
    SELECT 'plan',                             plan,                           churned_14d FROM stg_users
    UNION ALL
    SELECT 'lifecycle_stage',                  lifecycle_stage,                churned_14d FROM stg_users
),
agg AS (
    SELECT
        dimension,
        segment,
        COUNT(*)          AS users,
        SUM(churned_14d)  AS churners
    FROM long
    WHERE segment IS NOT NULL
    GROUP BY dimension, segment
)
SELECT
    dimension,
    segment,
    users,
    churners,
    ROUND(100.0 * churners / users, 2)                                            AS churn_rate_pct,
    ROUND(100.0 * users    / SUM(users)    OVER (PARTITION BY dimension), 2)      AS user_share_pct,
    ROUND(100.0 * churners / SUM(churners) OVER (PARTITION BY dimension), 2)      AS churner_share_pct,
    ROUND((1.0 * churners / SUM(churners) OVER (PARTITION BY dimension))
        / (1.0 * users    / SUM(users)    OVER (PARTITION BY dimension)), 2)      AS overrepresentation
FROM agg;


CREATE OR REPLACE VIEW rpt_churn_by_channel AS
SELECT segment AS acquisition_channel, users, churners, churn_rate_pct,
       user_share_pct, churner_share_pct, overrepresentation
FROM segment_churn
WHERE dimension = 'acquisition_channel'
ORDER BY churn_rate_pct DESC;


CREATE OR REPLACE VIEW rpt_churn_by_plan AS
SELECT segment AS plan, users, churners, churn_rate_pct,
       user_share_pct, churner_share_pct, overrepresentation
FROM segment_churn
WHERE dimension = 'plan'
ORDER BY churn_rate_pct DESC;


CREATE OR REPLACE VIEW rpt_churn_by_lifecycle AS
SELECT segment AS lifecycle_stage, users, churners, churn_rate_pct,
       user_share_pct, churner_share_pct, overrepresentation
FROM segment_churn
WHERE dimension = 'lifecycle_stage'
ORDER BY churner_share_pct DESC;
