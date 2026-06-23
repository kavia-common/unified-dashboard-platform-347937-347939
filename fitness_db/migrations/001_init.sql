-- Fitness App DB - Initial schema
-- This migration is designed to be idempotent-ish for local/dev by using IF NOT EXISTS where safe.
-- In production, prefer running once on a clean DB using a migration runner.

BEGIN;

-- Extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;

-- =========================
-- Core: users + profiles
-- =========================
CREATE TABLE IF NOT EXISTS app_user (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid TEXT NOT NULL UNIQUE,
    email CITEXT,
    display_name TEXT,
    photo_url TEXT,

    is_admin BOOLEAN NOT NULL DEFAULT FALSE,
    is_disabled BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_app_user_firebase_uid ON app_user(firebase_uid);
CREATE INDEX IF NOT EXISTS idx_app_user_email ON app_user(email) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_app_user_not_deleted ON app_user(id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS user_profile (
    user_id UUID PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,

    -- onboarding/profile fields
    birthdate DATE,
    sex TEXT CHECK (sex IN ('male', 'female', 'other', 'prefer_not_say')),
    height_cm NUMERIC(6,2) CHECK (height_cm IS NULL OR height_cm > 0),
    timezone TEXT,
    locale TEXT,

    fitness_level TEXT CHECK (fitness_level IN ('beginner', 'intermediate', 'advanced')),
    injuries TEXT, -- freeform notes
    equipment JSONB NOT NULL DEFAULT '[]'::jsonb, -- list of equipment strings

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================
-- Goals
-- =========================
CREATE TABLE IF NOT EXISTS user_goal (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    goal_type TEXT NOT NULL CHECK (goal_type IN ('weight_loss', 'muscle_gain', 'endurance', 'flexibility', 'general_fitness')),
    -- target fields are flexible, keep structured payload for different goal types
    target JSONB NOT NULL DEFAULT '{}'::jsonb,

    start_date DATE NOT NULL DEFAULT CURRENT_DATE,
    end_date DATE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_user_goal_user_active ON user_goal(user_id, is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_user_goal_user_dates ON user_goal(user_id, start_date, end_date) WHERE deleted_at IS NULL;

-- =========================
-- Exercise library (admin-managed + user custom)
-- =========================
CREATE TABLE IF NOT EXISTS exercise (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- If created_by is NULL => global/admin seeded exercise; else user-created
    created_by UUID REFERENCES app_user(id) ON DELETE SET NULL,

    name TEXT NOT NULL,
    description TEXT,
    primary_muscle_group TEXT,
    secondary_muscle_groups TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    equipment TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    movement_pattern TEXT,
    difficulty TEXT CHECK (difficulty IS NULL OR difficulty IN ('beginner', 'intermediate', 'advanced')),

    instructions JSONB NOT NULL DEFAULT '[]'::jsonb, -- steps
    media JSONB NOT NULL DEFAULT '{}'::jsonb, -- urls, thumbnails, etc.

    is_public BOOLEAN NOT NULL DEFAULT TRUE,
    is_archived BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    CONSTRAINT exercise_name_nonempty CHECK (length(trim(name)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_exercise_public_not_archived ON exercise(is_public, is_archived) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_exercise_created_by ON exercise(created_by) WHERE created_by IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_exercise_name_trgm_like ON exercise USING GIN (name gin_trgm_ops);

-- Enable trigram index support (requires extension)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Templates for reusable workouts (admin and/or user)
CREATE TABLE IF NOT EXISTS workout_template (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_user_id UUID REFERENCES app_user(id) ON DELETE CASCADE, -- NULL means admin/global template
    title TEXT NOT NULL,
    description TEXT,

    tags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    is_public BOOLEAN NOT NULL DEFAULT FALSE,
    is_archived BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    CONSTRAINT workout_template_title_nonempty CHECK (length(trim(title)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_workout_template_owner ON workout_template(owner_user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workout_template_public ON workout_template(is_public) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS workout_template_exercise (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workout_template_id UUID NOT NULL REFERENCES workout_template(id) ON DELETE CASCADE,
    exercise_id UUID NOT NULL REFERENCES exercise(id) ON DELETE RESTRICT,

    position INT NOT NULL,
    sets INT CHECK (sets IS NULL OR sets >= 0),
    reps INT CHECK (reps IS NULL OR reps >= 0),
    rep_range JSONB NOT NULL DEFAULT '{}'::jsonb, -- e.g., {"min":8,"max":12}
    weight_kg NUMERIC(10,2) CHECK (weight_kg IS NULL OR weight_kg >= 0),
    duration_seconds INT CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    distance_meters NUMERIC(12,2) CHECK (distance_meters IS NULL OR distance_meters >= 0),
    rest_seconds INT CHECK (rest_seconds IS NULL OR rest_seconds >= 0),
    notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_template_exercise_position UNIQUE (workout_template_id, position),
    CONSTRAINT chk_position_nonneg CHECK (position >= 0)
);

CREATE INDEX IF NOT EXISTS idx_wte_template ON workout_template_exercise(workout_template_id, position);

-- =========================
-- Plans / schedules
-- =========================
CREATE TABLE IF NOT EXISTS workout_plan (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    title TEXT NOT NULL,
    description TEXT,
    start_date DATE NOT NULL DEFAULT CURRENT_DATE,
    end_date DATE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    -- generator metadata (if any)
    source TEXT CHECK (source IS NULL OR source IN ('manual', 'generated')),
    source_meta JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    CONSTRAINT workout_plan_title_nonempty CHECK (length(trim(title)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_workout_plan_user_active ON workout_plan(user_id, is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workout_plan_user_dates ON workout_plan(user_id, start_date, end_date) WHERE deleted_at IS NULL;

-- A plan has scheduled sessions (usually weekly schedule)
CREATE TABLE IF NOT EXISTS planned_workout_session (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workout_plan_id UUID NOT NULL REFERENCES workout_plan(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    scheduled_date DATE NOT NULL,
    title TEXT,
    notes TEXT,

    -- optionally derive content from template
    workout_template_id UUID REFERENCES workout_template(id) ON DELETE SET NULL,

    status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'completed', 'skipped', 'cancelled')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    CONSTRAINT uq_user_scheduled_date_plan UNIQUE (user_id, scheduled_date, workout_plan_id)
);

CREATE INDEX IF NOT EXISTS idx_planned_session_user_date ON planned_workout_session(user_id, scheduled_date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_planned_session_plan_date ON planned_workout_session(workout_plan_id, scheduled_date) WHERE deleted_at IS NULL;

-- Planned session exercises (copied from template or manually authored)
CREATE TABLE IF NOT EXISTS planned_session_exercise (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    planned_session_id UUID NOT NULL REFERENCES planned_workout_session(id) ON DELETE CASCADE,
    exercise_id UUID NOT NULL REFERENCES exercise(id) ON DELETE RESTRICT,

    position INT NOT NULL,
    target JSONB NOT NULL DEFAULT '{}'::jsonb, -- {sets,reps,weight,etc} flexible

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_planned_session_exercise_position UNIQUE (planned_session_id, position),
    CONSTRAINT chk_planned_position_nonneg CHECK (position >= 0)
);

CREATE INDEX IF NOT EXISTS idx_planned_session_exercise_session ON planned_session_exercise(planned_session_id, position);

-- =========================
-- Workout logging (actual performed)
-- =========================
CREATE TABLE IF NOT EXISTS workout_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    planned_session_id UUID REFERENCES planned_workout_session(id) ON DELETE SET NULL,

    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    title TEXT,
    notes TEXT,

    rpe INT CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10)),
    calories_burned NUMERIC(10,2) CHECK (calories_burned IS NULL OR calories_burned >= 0),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_workout_log_user_started_at ON workout_log(user_id, started_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_workout_log_planned_session ON workout_log(planned_session_id) WHERE planned_session_id IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS workout_log_exercise (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workout_log_id UUID NOT NULL REFERENCES workout_log(id) ON DELETE CASCADE,
    exercise_id UUID NOT NULL REFERENCES exercise(id) ON DELETE RESTRICT,

    position INT NOT NULL,
    notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_wle_position UNIQUE (workout_log_id, position),
    CONSTRAINT chk_wle_position_nonneg CHECK (position >= 0)
);

CREATE INDEX IF NOT EXISTS idx_wle_workout ON workout_log_exercise(workout_log_id, position);

CREATE TABLE IF NOT EXISTS workout_log_set (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workout_log_exercise_id UUID NOT NULL REFERENCES workout_log_exercise(id) ON DELETE CASCADE,

    set_number INT NOT NULL,
    reps INT CHECK (reps IS NULL OR reps >= 0),
    weight_kg NUMERIC(10,2) CHECK (weight_kg IS NULL OR weight_kg >= 0),
    duration_seconds INT CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    distance_meters NUMERIC(12,2) CHECK (distance_meters IS NULL OR distance_meters >= 0),
    is_warmup BOOLEAN NOT NULL DEFAULT FALSE,

    rpe INT CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10)),
    notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_set_number UNIQUE (workout_log_exercise_id, set_number),
    CONSTRAINT chk_set_number_positive CHECK (set_number >= 1)
);

CREATE INDEX IF NOT EXISTS idx_wls_exercise ON workout_log_set(workout_log_exercise_id, set_number);

-- =========================
-- Activity logs (steps / cardio / misc)
-- =========================
CREATE TABLE IF NOT EXISTS activity_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    activity_type TEXT NOT NULL CHECK (activity_type IN ('steps', 'cardio', 'sport', 'mobility', 'other')),
    occurred_on DATE NOT NULL,

    steps INT CHECK (steps IS NULL OR steps >= 0),
    duration_minutes INT CHECK (duration_minutes IS NULL OR duration_minutes >= 0),
    distance_meters NUMERIC(12,2) CHECK (distance_meters IS NULL OR distance_meters >= 0),
    calories_burned NUMERIC(10,2) CHECK (calories_burned IS NULL OR calories_burned >= 0),

    source TEXT, -- manual/imported/device/etc
    meta JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    CONSTRAINT uq_activity_user_type_day UNIQUE (user_id, activity_type, occurred_on)
);

CREATE INDEX IF NOT EXISTS idx_activity_log_user_day ON activity_log(user_id, occurred_on DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_activity_log_user_type_day ON activity_log(user_id, activity_type, occurred_on DESC) WHERE deleted_at IS NULL;

-- =========================
-- Progress tracking: metrics, photos, PRs
-- =========================
CREATE TABLE IF NOT EXISTS body_metric (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    measured_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    weight_kg NUMERIC(10,2) CHECK (weight_kg IS NULL OR weight_kg > 0),
    body_fat_pct NUMERIC(5,2) CHECK (body_fat_pct IS NULL OR (body_fat_pct >= 0 AND body_fat_pct <= 100)),

    -- circumference etc
    measurements JSONB NOT NULL DEFAULT '{}'::jsonb,

    notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_body_metric_user_measured_at ON body_metric(user_id, measured_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS progress_photo (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    taken_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    storage_provider TEXT NOT NULL DEFAULT 'local',
    object_key TEXT NOT NULL, -- path/key in storage
    url TEXT, -- optional public url
    caption TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_progress_photo_user_taken_at ON progress_photo(user_id, taken_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS personal_record (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    exercise_id UUID REFERENCES exercise(id) ON DELETE SET NULL,

    pr_type TEXT NOT NULL CHECK (pr_type IN ('1rm', 'max_reps', 'max_volume', 'best_time', 'best_distance', 'other')),
    value JSONB NOT NULL DEFAULT '{}'::jsonb, -- e.g. {"weight_kg":100} or {"reps":20,"weight_kg":60}
    achieved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_pr_user_achieved ON personal_record(user_id, achieved_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_pr_user_exercise ON personal_record(user_id, exercise_id) WHERE deleted_at IS NULL;

-- =========================
-- Reminders / notifications
-- =========================
CREATE TABLE IF NOT EXISTS notification_schedule (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    notification_type TEXT NOT NULL CHECK (notification_type IN ('workout_reminder', 'goal_checkin', 'streak_nudge', 'custom')),
    channel TEXT NOT NULL DEFAULT 'in_app' CHECK (channel IN ('in_app', 'push', 'email')),

    title TEXT,
    body TEXT,

    cron TEXT, -- optional
    scheduled_at TIMESTAMPTZ, -- one-off
    timezone TEXT,

    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,

    last_run_at TIMESTAMPTZ,
    next_run_at TIMESTAMPTZ,

    meta JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    CONSTRAINT chk_notification_schedule_timing CHECK (
        (cron IS NOT NULL AND scheduled_at IS NULL)
        OR (cron IS NULL AND scheduled_at IS NOT NULL)
        OR (cron IS NULL AND scheduled_at IS NULL) -- allow placeholder drafts
    )
);

CREATE INDEX IF NOT EXISTS idx_notification_user_enabled_next ON notification_schedule(user_id, is_enabled, next_run_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notification_next_run ON notification_schedule(next_run_at) WHERE is_enabled = TRUE AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS notification_delivery (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_id UUID REFERENCES notification_schedule(id) ON DELETE SET NULL,
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    delivered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    channel TEXT NOT NULL CHECK (channel IN ('in_app', 'push', 'email')),
    status TEXT NOT NULL DEFAULT 'delivered' CHECK (status IN ('queued', 'delivered', 'failed')),
    error TEXT,

    payload JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_notification_delivery_user_time ON notification_delivery(user_id, delivered_at DESC);

-- =========================
-- Social sharing artifacts
-- =========================
CREATE TABLE IF NOT EXISTS share_artifact (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,

    artifact_type TEXT NOT NULL CHECK (artifact_type IN ('progress_photo', 'workout_summary', 'metric_snapshot', 'pr', 'other')),
    -- polymorphic reference
    ref_table TEXT,
    ref_id UUID,

    title TEXT,
    description TEXT,

    share_token TEXT NOT NULL UNIQUE, -- random token for share URLs
    is_public BOOLEAN NOT NULL DEFAULT TRUE,
    expires_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_share_artifact_token ON share_artifact(share_token);
CREATE INDEX IF NOT EXISTS idx_share_artifact_user_created ON share_artifact(user_id, created_at DESC) WHERE deleted_at IS NULL;

-- =========================
-- Admin content (articles/tips)
-- =========================
CREATE TABLE IF NOT EXISTS admin_content (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_by UUID REFERENCES app_user(id) ON DELETE SET NULL,

    content_type TEXT NOT NULL CHECK (content_type IN ('article', 'tip', 'program', 'announcement')),
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    summary TEXT,
    body_markdown TEXT NOT NULL,
    tags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],

    is_published BOOLEAN NOT NULL DEFAULT FALSE,
    published_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    CONSTRAINT admin_content_title_nonempty CHECK (length(trim(title)) > 0),
    CONSTRAINT admin_content_slug_nonempty CHECK (length(trim(slug)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_admin_content_published ON admin_content(is_published, published_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_admin_content_tags ON admin_content USING GIN (tags);

-- =========================
-- Analytics-friendly events
-- =========================
CREATE TABLE IF NOT EXISTS app_event (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES app_user(id) ON DELETE SET NULL,

    event_name TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source TEXT, -- frontend/backend/etc
    properties JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_app_event_name_time ON app_event(event_name, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_app_event_user_time ON app_event(user_id, occurred_at DESC) WHERE user_id IS NOT NULL;

-- =========================
-- Updated-at trigger helper
-- =========================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach updated_at triggers (only for tables that have updated_at)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_app_user_updated_at') THEN
    CREATE TRIGGER trg_app_user_updated_at BEFORE UPDATE ON app_user
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_user_profile_updated_at') THEN
    CREATE TRIGGER trg_user_profile_updated_at BEFORE UPDATE ON user_profile
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_user_goal_updated_at') THEN
    CREATE TRIGGER trg_user_goal_updated_at BEFORE UPDATE ON user_goal
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_exercise_updated_at') THEN
    CREATE TRIGGER trg_exercise_updated_at BEFORE UPDATE ON exercise
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_workout_template_updated_at') THEN
    CREATE TRIGGER trg_workout_template_updated_at BEFORE UPDATE ON workout_template
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_workout_plan_updated_at') THEN
    CREATE TRIGGER trg_workout_plan_updated_at BEFORE UPDATE ON workout_plan
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_planned_workout_session_updated_at') THEN
    CREATE TRIGGER trg_planned_workout_session_updated_at BEFORE UPDATE ON planned_workout_session
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_workout_log_updated_at') THEN
    CREATE TRIGGER trg_workout_log_updated_at BEFORE UPDATE ON workout_log
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_activity_log_updated_at') THEN
    CREATE TRIGGER trg_activity_log_updated_at BEFORE UPDATE ON activity_log
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notification_schedule_updated_at') THEN
    CREATE TRIGGER trg_notification_schedule_updated_at BEFORE UPDATE ON notification_schedule
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_admin_content_updated_at') THEN
    CREATE TRIGGER trg_admin_content_updated_at BEFORE UPDATE ON admin_content
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

COMMIT;
