-- =====================================================================
-- 01_user_metrics.sql
-- Roll raw listening, ad, and subscription events up to one row per user.
--
-- Leakage control: every metric uses only events strictly BEFORE the
-- snapshot. The churn label covers the 14 days AFTER it, so no feature
-- can see the outcome it is predicting.
--
-- Window definitions (matched to the provided feature table):
--   "7d"  = [snapshot - 7 days,  snapshot)
--   "30d" = [snapshot - 31 days, snapshot)  -> the full prior calendar
--           month for an April 1 snapshot (March has 31 days). Reconciling
--           against the feature table showed a strict 30-day window
--           matched only ~80% of users; the 31-day window matches 100%.
-- =====================================================================

CREATE OR REPLACE TABLE user_metrics AS
WITH snapshot AS (
    SELECT user_id, snapshot_ts FROM stg_users
),

listening AS (
    SELECT
        s.user_id,
        COUNT(DISTINCT CASE WHEN e.event_ts >= s.snapshot_ts - INTERVAL 7 DAY
                            THEN CAST(e.event_ts AS DATE) END)           AS active_days_7d,
        SUM(CASE WHEN e.event_ts >= s.snapshot_ts - INTERVAL 7 DAY
                 THEN e.play_duration_sec ELSE 0 END) / 60.0             AS listen_minutes_7d,
        COUNT(DISTINCT CAST(e.event_ts AS DATE))                         AS active_days_30d,
        COUNT(*)                                                         AS listen_events_30d,
        SUM(e.play_duration_sec) / 60.0                                  AS listen_minutes_30d,
        COUNT(DISTINCT e.session_id)                                     AS sessions_30d,
        AVG(e.play_duration_sec)                                         AS avg_play_duration_sec_30d,
        AVG(e.is_skipped)                                                AS skip_rate_30d,
        AVG(e.is_completed)                                              AS completion_rate_30d,
        SUM(e.is_liked)                                                  AS liked_songs_30d,
        SUM(e.is_playlist_add)                                           AS playlist_adds_30d,
        SUM(e.is_search)                                                 AS search_events_30d
    FROM snapshot s
    JOIN stg_listening_events e
      ON  e.user_id  = s.user_id
      AND e.event_ts >= s.snapshot_ts - INTERVAL 31 DAY
      AND e.event_ts <  s.snapshot_ts
    GROUP BY s.user_id
),

ads AS (
    SELECT
        s.user_id,
        COUNT(*)                AS ad_impressions_30d,
        SUM(e.is_click)         AS ad_clicks_30d,
        SUM(e.is_ad_complete)   AS ad_completions_30d,
        SUM(e.ad_revenue)       AS ad_revenue_30d
    FROM snapshot s
    JOIN stg_ad_events e
      ON  e.user_id  = s.user_id
      AND e.event_ts >= s.snapshot_ts - INTERVAL 31 DAY
      AND e.event_ts <  s.snapshot_ts
    GROUP BY s.user_id
),

subscriptions AS (
    SELECT
        s.user_id,
        MAX(CASE WHEN e.event_type = 'trial_started' THEN 1 ELSE 0 END)   AS trial_used_before_snapshot,
        MAX(CASE WHEN e.event_type = 'payment_failed'
                  AND e.event_ts >= s.snapshot_ts - INTERVAL 31 DAY
                 THEN 1 ELSE 0 END)                                      AS payment_failed_30d
    FROM snapshot s
    JOIN stg_subscription_events e
      ON  e.user_id  = s.user_id
      AND e.event_ts <  s.snapshot_ts
    GROUP BY s.user_id
)

-- LEFT JOINs keep users with no events: counts become 0; rates stay NULL
-- because a skip rate is undefined for a user with no plays.
SELECT
    s.user_id,
    s.snapshot_ts,
    COALESCE(l.active_days_7d, 0)                         AS active_days_7d,
    COALESCE(l.listen_minutes_7d, 0)                      AS listen_minutes_7d,
    COALESCE(l.active_days_30d, 0)                        AS active_days_30d,
    COALESCE(l.listen_events_30d, 0)                      AS listen_events_30d,
    COALESCE(l.listen_minutes_30d, 0)                     AS listen_minutes_30d,
    COALESCE(l.sessions_30d, 0)                           AS sessions_30d,
    l.avg_play_duration_sec_30d,
    l.skip_rate_30d,
    l.completion_rate_30d,
    COALESCE(l.liked_songs_30d, 0)                        AS liked_songs_30d,
    COALESCE(l.playlist_adds_30d, 0)                      AS playlist_adds_30d,
    COALESCE(l.search_events_30d, 0)                      AS search_events_30d,
    COALESCE(a.ad_impressions_30d, 0)                     AS ad_impressions_30d,
    COALESCE(a.ad_clicks_30d, 0)                          AS ad_clicks_30d,
    1.0 * a.ad_clicks_30d / NULLIF(a.ad_impressions_30d, 0)      AS ad_click_rate_30d,
    COALESCE(a.ad_completions_30d, 0)                     AS ad_completions_30d,
    1.0 * a.ad_completions_30d / NULLIF(a.ad_impressions_30d, 0) AS ad_completion_rate_30d,
    1.0 * a.ad_impressions_30d / NULLIF(l.active_days_30d, 0)    AS ad_impressions_per_active_day,
    COALESCE(a.ad_revenue_30d, 0)                         AS ad_revenue_30d,
    COALESCE(sub.trial_used_before_snapshot, 0)           AS trial_used_before_snapshot,
    COALESCE(sub.payment_failed_30d, 0)                   AS payment_failed_30d
FROM snapshot s
LEFT JOIN listening     l   ON l.user_id   = s.user_id
LEFT JOIN ads           a   ON a.user_id   = s.user_id
LEFT JOIN subscriptions sub ON sub.user_id = s.user_id;


-- ---------------------------------------------------------------------
-- Quality checks on the new table
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_user_metrics_qa AS
SELECT
    COUNT(*)                                                                AS users,
    COUNT(*) - COUNT(DISTINCT user_id)                                      AS duplicate_users,
    SUM(CASE WHEN active_days_30d < active_days_7d THEN 1 ELSE 0 END)       AS window_violations_days,
    SUM(CASE WHEN listen_minutes_30d < listen_minutes_7d THEN 1 ELSE 0 END) AS window_violations_minutes,
    SUM(CASE WHEN active_days_30d > 31 THEN 1 ELSE 0 END)                   AS impossible_active_days,
    ROUND(100.0 * AVG(CASE WHEN active_days_30d = 0 THEN 1 ELSE 0 END), 2)  AS pct_users_no_listening
FROM user_metrics;


-- ---------------------------------------------------------------------
-- Reconciliation: does each metric rebuilt from raw events match the
-- provided feature table? (Rates are compared with NULL treated as 0,
-- which is how the feature table stores users with no activity.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_metric_reconciliation AS
WITH pairs AS (
    SELECT 'active_days_7d' AS metric, m.active_days_7d AS rebuilt, f.active_days_7d AS provided FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'listen_minutes_7d', m.listen_minutes_7d, f.listen_minutes_7d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'active_days_30d', m.active_days_30d, f.active_days_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'listen_events_30d', m.listen_events_30d, f.listen_events_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'listen_minutes_30d', m.listen_minutes_30d, f.listen_minutes_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'sessions_30d', m.sessions_30d, f.sessions_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'avg_play_duration_sec_30d', m.avg_play_duration_sec_30d, f.avg_play_duration_sec_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'skip_rate_30d', m.skip_rate_30d, f.skip_rate_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'completion_rate_30d', m.completion_rate_30d, f.completion_rate_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'liked_songs_30d', m.liked_songs_30d, f.liked_songs_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'playlist_adds_30d', m.playlist_adds_30d, f.playlist_adds_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'search_events_30d', m.search_events_30d, f.search_events_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'ad_impressions_30d', m.ad_impressions_30d, f.ad_impressions_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'ad_clicks_30d', m.ad_clicks_30d, f.ad_clicks_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'ad_click_rate_30d', m.ad_click_rate_30d, f.ad_click_rate_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'ad_completions_30d', m.ad_completions_30d, f.ad_completions_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'ad_completion_rate_30d', m.ad_completion_rate_30d, f.ad_completion_rate_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'ad_impressions_per_active_day', m.ad_impressions_per_active_day, f.ad_impressions_per_active_day FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'ad_revenue_30d', m.ad_revenue_30d, f.ad_revenue_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'payment_failed_30d', m.payment_failed_30d, f.payment_failed_30d FROM user_metrics m JOIN raw_feature_table f USING (user_id)
    UNION ALL
    SELECT 'trial_used_before_snapshot', m.trial_used_before_snapshot, f.trial_used_before_snapshot FROM user_metrics m JOIN raw_feature_table f USING (user_id)
)
SELECT
    metric,
    COUNT(*)                                                                  AS users,
    SUM(CASE WHEN ABS(COALESCE(rebuilt, 0) - COALESCE(provided, 0)) >= 0.001
             THEN 1 ELSE 0 END)                                               AS mismatched_users,
    ROUND(100.0 * AVG(CASE WHEN ABS(COALESCE(rebuilt, 0) - COALESCE(provided, 0)) < 0.001
                           THEN 1 ELSE 0 END), 2)                             AS match_rate_pct
FROM pairs
GROUP BY metric
ORDER BY match_rate_pct, metric;


-- ---------------------------------------------------------------------
-- Leakage audit: the provided feature table flags a user as
-- "trial_used_before_snapshot" if they EVER started a trial, including
-- trials that began after the snapshot. Those later trials fall in the
-- prediction window, so the flag leaks future information. The rebuilt
-- column above uses only pre-snapshot trials and replaces it in the model.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_leakage_audit AS
WITH first_trial AS (
    SELECT user_id, MIN(event_ts) AS first_trial_ts
    FROM stg_subscription_events
    WHERE event_type = 'trial_started'
    GROUP BY user_id
)
SELECT
    CASE
        WHEN t.user_id IS NULL               THEN 'no trial'
        WHEN t.first_trial_ts < u.snapshot_ts THEN 'first trial before snapshot'
        ELSE                                      'first trial AFTER snapshot (leak)'
    END                                              AS trial_timing,
    COUNT(*)                                         AS users,
    SUM(f.trial_used_before_snapshot)                AS flagged_in_feature_table,
    SUM(m.trial_used_before_snapshot)                AS flagged_in_rebuild,
    ROUND(100.0 * AVG(u.churned_14d), 2)             AS churn_rate_pct
FROM stg_users u
JOIN raw_feature_table f ON f.user_id = u.user_id
JOIN user_metrics      m ON m.user_id = u.user_id
LEFT JOIN first_trial  t ON t.user_id = u.user_id
GROUP BY 1
ORDER BY users DESC;
