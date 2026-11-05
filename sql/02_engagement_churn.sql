-- =====================================================================
-- 02_engagement_churn.sql
-- How much does early engagement separate churners from retained users?
-- =====================================================================

-- 2.1 Churn by 30-day activity level ----------------------------------
CREATE OR REPLACE VIEW rpt_churn_by_activity AS
SELECT
    u.active_level_30d,
    COUNT(*)                                                    AS users,
    SUM(u.churned_14d)                                          AS churners,
    ROUND(100.0 * AVG(u.churned_14d), 2)                        AS churn_rate_pct,
    ROUND(AVG(m.active_days_30d), 2)                            AS avg_active_days_30d,
    ROUND(AVG(m.listen_minutes_30d), 1)                         AS avg_listen_minutes_30d,
    ROUND(AVG(m.playlist_adds_30d), 2)                          AS avg_playlist_adds_30d
FROM stg_users u
JOIN user_metrics m USING (user_id)
WHERE u.active_level_30d IS NOT NULL
GROUP BY u.active_level_30d
ORDER BY CASE u.active_level_30d
             WHEN 'inactive' THEN 1 WHEN 'low'  THEN 2
             WHEN 'medium'   THEN 3 WHEN 'high' THEN 4
             ELSE 5
         END;


-- 2.2 Headline ratio: inactive vs. highly active ----------------------
CREATE OR REPLACE VIEW rpt_activity_churn_ratio AS
SELECT
    MAX(CASE WHEN active_level_30d = 'inactive' THEN churn_rate_pct END) AS inactive_churn_pct,
    MAX(CASE WHEN active_level_30d = 'high'     THEN churn_rate_pct END) AS high_activity_churn_pct,
    ROUND(MAX(CASE WHEN active_level_30d = 'inactive' THEN churn_rate_pct END)
        / NULLIF(MAX(CASE WHEN active_level_30d = 'high' THEN churn_rate_pct END), 0), 1)
                                                                          AS inactive_to_high_ratio
FROM rpt_churn_by_activity;


-- 2.3 Content ownership: churn by number of playlist adds -------------
--     Supports the playlist-led onboarding recommendation: do users who
--     save music into playlists early stay longer?
CREATE OR REPLACE VIEW rpt_churn_by_playlist_adds AS
SELECT
    CASE
        WHEN m.playlist_adds_30d = 0 THEN '0'
        WHEN m.playlist_adds_30d <= 2 THEN '1-2'
        WHEN m.playlist_adds_30d <= 5 THEN '3-5'
        ELSE '6+'
    END                                                         AS playlist_adds_30d,
    COUNT(*)                                                    AS users,
    ROUND(100.0 * AVG(u.churned_14d), 2)                        AS churn_rate_pct
FROM stg_users u
JOIN user_metrics m USING (user_id)
GROUP BY 1
ORDER BY MIN(m.playlist_adds_30d);
