-- Fitness App DB - Additive schema extensions for additional features
-- Keep this migration additive and safe to apply after 001_init.sql.
-- Focus: photo metadata fields, analytics time-series index support, notification delivery history enhancements.

BEGIN;

-- =========================
-- Progress photos: add minimal metadata to support richer UI and querying
-- =========================
ALTER TABLE progress_photo
  ADD COLUMN IF NOT EXISTS meta JSONB NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE progress_photo
  ADD COLUMN IF NOT EXISTS mime_type TEXT;

ALTER TABLE progress_photo
  ADD COLUMN IF NOT EXISTS file_size_bytes BIGINT CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0);

ALTER TABLE progress_photo
  ADD COLUMN IF NOT EXISTS width_px INT CHECK (width_px IS NULL OR width_px > 0);

ALTER TABLE progress_photo
  ADD COLUMN IF NOT EXISTS height_px INT CHECK (height_px IS NULL OR height_px > 0);

-- Useful for filtering/searching on provider/key and ensuring uniqueness per provider.
CREATE UNIQUE INDEX IF NOT EXISTS uq_progress_photo_provider_object_key
  ON progress_photo(storage_provider, object_key)
  WHERE deleted_at IS NULL;

-- =========================
-- Notification delivery: enhance history + query performance
-- =========================
ALTER TABLE notification_delivery
  ADD COLUMN IF NOT EXISTS provider_message_id TEXT;

ALTER TABLE notification_delivery
  ADD COLUMN IF NOT EXISTS attempt INT NOT NULL DEFAULT 1 CHECK (attempt >= 1);

ALTER TABLE notification_delivery
  ADD COLUMN IF NOT EXISTS delivered_to TEXT; -- e.g. email address or push token (if applicable)

-- Common query patterns: list deliveries for a schedule, recent failures, etc.
CREATE INDEX IF NOT EXISTS idx_notification_delivery_schedule_time
  ON notification_delivery(schedule_id, delivered_at DESC)
  WHERE schedule_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notification_delivery_status_time
  ON notification_delivery(status, delivered_at DESC);

-- =========================
-- Analytics: add time-series friendly indexes for dashboard charts
-- =========================

-- Activity logs: charts by day; already has (user_id, occurred_on desc) but add BRIN on date for large tables.
CREATE INDEX IF NOT EXISTS brin_activity_log_occurred_on
  ON activity_log USING BRIN (occurred_on)
  WHERE deleted_at IS NULL;

-- Body metrics: chart by measured_at; already has btree user_id/measured_at, add BRIN to speed range scans.
CREATE INDEX IF NOT EXISTS brin_body_metric_measured_at
  ON body_metric USING BRIN (measured_at)
  WHERE deleted_at IS NULL;

-- Workout logs: chart over time; already has btree user_id/started_at desc, add BRIN for range scans.
CREATE INDEX IF NOT EXISTS brin_workout_log_started_at
  ON workout_log USING BRIN (started_at)
  WHERE deleted_at IS NULL;

-- App events: already has (event_name, occurred_at desc) and (user_id, occurred_at desc).
-- Add BRIN on occurred_at for large append-only event tables.
CREATE INDEX IF NOT EXISTS brin_app_event_occurred_at
  ON app_event USING BRIN (occurred_at);

COMMIT;
