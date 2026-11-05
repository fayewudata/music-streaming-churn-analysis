-- =====================================================================
-- 04_trial_conversion.sql
-- Do trials that start from the paywall convert to paid better than
-- trials that start from an email campaign?
--
-- Definitions
--   Trial:       a user's FIRST trial_started event (one trial per user)
--   Touchpoint:  the surface that trial_started event came from
--   Converted:   a paid_started event within 30 days after the trial start
--   Mature:      the trial started at least 30 days before the end of the
--                data, so its full 30-day window is observed. Immature
--                trials are excluded: they have not had time to convert,
--                and including them understates conversion.
-- =====================================================================

CREATE OR REPLACE TABLE trial_outcomes AS
WITH first_trial AS (
    SELECT user_id, event_ts AS trial_start_ts, touchpoint, trial_length_days
    FROM (
        SELECT
            user_id, event_ts, touchpoint, trial_length_days,
            ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_ts) AS trial_number
        FROM stg_subscription_events
        WHERE event_type = 'trial_started'
    ) t
    WHERE trial_number = 1
),
data_end AS (
    SELECT MAX(event_ts) AS max_ts FROM stg_subscription_events
)
SELECT
    t.user_id,
    t.touchpoint                                                            AS trial_touchpoint,
    t.trial_length_days,
    t.trial_start_ts,
    CASE WHEN t.trial_start_ts <= d.max_ts - INTERVAL 30 DAY THEN 1 ELSE 0 END AS is_mature,
    MAX(CASE WHEN p.event_ts >  t.trial_start_ts
              AND p.event_ts <= t.trial_start_ts + INTERVAL 30 DAY
             THEN 1 ELSE 0 END)                                             AS converted_30d
FROM first_trial t
CROSS JOIN data_end d
LEFT JOIN stg_subscription_events p
       ON p.user_id = t.user_id
      AND p.event_type = 'paid_started'
GROUP BY t.user_id, t.touchpoint, t.trial_length_days, t.trial_start_ts, d.max_ts;


-- 4.1 Conversion by trial touchpoint (mature trials only) -------------
CREATE OR REPLACE VIEW rpt_trial_conversion_by_touchpoint AS
SELECT
    trial_touchpoint,
    COUNT(*)                                                AS trials,
    SUM(converted_30d)                                      AS converted,
    ROUND(100.0 * AVG(converted_30d), 2)                    AS conversion_30d_pct,
    CAST(MIN(trial_start_ts) AS DATE)                       AS first_trial_date,
    CAST(MAX(trial_start_ts) AS DATE)                       AS last_trial_date,
    ROUND(COUNT(*) / GREATEST(DATE_DIFF('day', MIN(trial_start_ts), MAX(trial_start_ts)) / 7.0, 1), 1)
                                                            AS trials_per_week
FROM trial_outcomes
WHERE is_mature = 1
  AND trial_touchpoint IS NOT NULL
GROUP BY trial_touchpoint
ORDER BY conversion_30d_pct DESC;


-- 4.2 Headline gap: paywall-origin minus email-origin -----------------
CREATE OR REPLACE VIEW rpt_trial_conversion_gap AS
SELECT
    MAX(CASE WHEN trial_touchpoint = 'paywall' THEN conversion_30d_pct END) AS paywall_conversion_pct,
    MAX(CASE WHEN trial_touchpoint = 'email'   THEN conversion_30d_pct END) AS email_conversion_pct,
    ROUND(MAX(CASE WHEN trial_touchpoint = 'paywall' THEN conversion_30d_pct END)
        - MAX(CASE WHEN trial_touchpoint = 'email'   THEN conversion_30d_pct END), 2)
                                                                            AS gap_pct_points
FROM rpt_trial_conversion_by_touchpoint;


-- 4.3 Confounder check: is the gap just a different trial-length mix? --
--     30-day trials give users longer to decide. If paywall trials were
--     mostly 30-day trials, the gap could come from trial length rather
--     than the paywall itself.
CREATE OR REPLACE VIEW rpt_trial_mix_by_touchpoint AS
SELECT
    trial_touchpoint,
    COUNT(*)                                                               AS trials,
    ROUND(100.0 * AVG(CASE WHEN trial_length_days = 30 THEN 1 ELSE 0 END), 2) AS pct_30_day_trials,
    ROUND(100.0 * AVG(CASE WHEN trial_length_days = 7 THEN converted_30d END), 2)  AS conversion_7_day_trials_pct,
    ROUND(100.0 * AVG(CASE WHEN trial_length_days = 30 THEN converted_30d END), 2) AS conversion_30_day_trials_pct
FROM trial_outcomes
WHERE is_mature = 1
  AND trial_touchpoint IN ('paywall', 'email')
GROUP BY trial_touchpoint
ORDER BY trial_touchpoint DESC;
