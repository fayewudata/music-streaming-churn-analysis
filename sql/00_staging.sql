-- =====================================================================
-- 00_staging.sql
-- Load the raw CSVs and expose them through staging views with standard
-- column names and types. Every later query reads the stg_* views, so if
-- a source column is renamed, this is the only file to edit.
-- =====================================================================

CREATE OR REPLACE TABLE raw_users               AS SELECT * FROM read_csv_auto('data/users.csv');
CREATE OR REPLACE TABLE raw_listening_events    AS SELECT * FROM read_csv_auto('data/listening_events.csv');
CREATE OR REPLACE TABLE raw_ad_events           AS SELECT * FROM read_csv_auto('data/ad_events.csv');
CREATE OR REPLACE TABLE raw_subscription_events AS SELECT * FROM read_csv_auto('data/subscription_events.csv');
CREATE OR REPLACE TABLE raw_feature_table       AS SELECT * FROM read_csv_auto('data/feature_table.csv');


-- One row per play
CREATE OR REPLACE VIEW stg_listening_events AS
SELECT
    user_id,
    session_id,
    CAST(event_timestamp AS TIMESTAMP)    AS event_ts,
    recommendation_source,
    CAST(play_duration_sec  AS DOUBLE)    AS play_duration_sec,
    CAST(track_duration_sec AS DOUBLE)    AS track_duration_sec,
    CAST(completed_flag     AS INTEGER)   AS is_completed,
    CAST(skipped_flag       AS INTEGER)   AS is_skipped,
    CAST(liked_flag         AS INTEGER)   AS is_liked,
    CAST(playlist_add_flag  AS INTEGER)   AS is_playlist_add,
    CAST(search_used_flag   AS INTEGER)   AS is_search
FROM raw_listening_events;


-- One row per ad impression
CREATE OR REPLACE VIEW stg_ad_events AS
SELECT
    user_id,
    CAST(event_timestamp AS TIMESTAMP)    AS event_ts,
    ad_type,
    placement,
    CAST(clicked_flag   AS INTEGER)       AS is_click,
    CAST(completed_flag AS INTEGER)       AS is_ad_complete,
    CAST(revenue_usd    AS DOUBLE)        AS ad_revenue
FROM raw_ad_events;


-- One row per subscription event.
-- event_type: trial_exposed, trial_started, trial_expired, paid_started,
--             renewal_success, payment_failed, cancel
-- touchpoint: the surface the event came from (paywall, email,
--             home_banner, push_notification, ...)
CREATE OR REPLACE VIEW stg_subscription_events AS
SELECT
    user_id,
    CAST(event_timestamp AS TIMESTAMP)    AS event_ts,
    LOWER(event_type)                     AS event_type,
    LOWER(source_touchpoint)              AS touchpoint,
    plan_type,
    CAST(price_usd AS DOUBLE)             AS price_usd,
    trial_length_days
FROM raw_subscription_events;


-- One row per user at the snapshot date, with the 14-day-forward churn label
CREATE OR REPLACE VIEW stg_users AS
SELECT
    user_id,
    CAST(snapshot_date AS TIMESTAMP)      AS snapshot_ts,
    CAST(churn_label_14d AS INTEGER)      AS churned_14d,
    acquisition_channel,
    subscription_type                     AS plan,
    lifecycle_stage,
    active_level_30d
FROM raw_feature_table;


-- ---------------------------------------------------------------------
-- Event volume behind the user-level metrics
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_event_volume AS
WITH counts AS (
    SELECT 'listening_events'    AS source_table, COUNT(*) AS n_events FROM stg_listening_events
    UNION ALL
    SELECT 'ad_events',           COUNT(*) FROM stg_ad_events
    UNION ALL
    SELECT 'subscription_events', COUNT(*) FROM stg_subscription_events
)
SELECT source_table, n_events FROM counts
UNION ALL
SELECT 'TOTAL', SUM(n_events) FROM counts
UNION ALL
SELECT 'users', COUNT(DISTINCT user_id) FROM stg_users;
