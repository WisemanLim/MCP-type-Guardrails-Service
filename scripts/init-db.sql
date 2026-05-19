-- Initial schema for Guardrails Service.
-- Loaded by Postgres entrypoint on first boot.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS tenants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS domains (
  domain_key       TEXT PRIMARY KEY,
  parent_key       TEXT REFERENCES domains(domain_key),
  display_name     JSONB NOT NULL DEFAULT '{}'::jsonb,
  description      TEXT,
  default_locales  TEXT[] NOT NULL DEFAULT ARRAY['ko-KR','en']::TEXT[],
  regulation_tags  TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  status           TEXT NOT NULL CHECK (status IN ('active','beta','deprecated')) DEFAULT 'active',
  inherits_from    TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  version          TEXT NOT NULL DEFAULT '0.0.1',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rules (
  rule_id           TEXT PRIMARY KEY,
  domain            TEXT NOT NULL REFERENCES domains(domain_key),
  locale            TEXT NOT NULL,
  io_type           TEXT NOT NULL CHECK (io_type IN ('input','output','both')),
  category          TEXT NOT NULL,
  sub_category      TEXT,
  severity          TEXT NOT NULL CHECK (severity IN ('low','medium','high','critical')),
  priority          INT  NOT NULL DEFAULT 100,
  action            TEXT NOT NULL,
  pattern_bundle    JSONB NOT NULL DEFAULT '{}'::jsonb,
  message_template  JSONB NOT NULL DEFAULT '{}'::jsonb,
  regulation_tags   TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  examples_positive TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  examples_negative TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  enabled           BOOLEAN NOT NULL DEFAULT TRUE,
  version           TEXT NOT NULL DEFAULT '1.0.0',
  source            TEXT NOT NULL DEFAULT 'admin'
                     CHECK (source IN ('file','admin','csv')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rules_domain_locale_io ON rules(domain, locale, io_type) WHERE enabled;
-- Add source column on existing deployments missing it.
ALTER TABLE rules ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'admin';

CREATE TABLE IF NOT EXISTS policy_versions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  domain      TEXT NOT NULL,
  version     TEXT NOT NULL,
  bundle      JSONB NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('draft','staged','active','archived')) DEFAULT 'active',
  created_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (domain, version)
);

CREATE TABLE IF NOT EXISTS whitelists (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  domain            TEXT NOT NULL,
  locale            TEXT NOT NULL,
  category          TEXT NOT NULL,
  patterns          TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  description       TEXT,
  score_adjustment  NUMERIC NOT NULL DEFAULT -0.1
);

CREATE TABLE IF NOT EXISTS decision_events (
  decision_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID,
  session_id      TEXT,
  domain          TEXT NOT NULL,
  locale          TEXT NOT NULL,
  io_type         TEXT NOT NULL,
  text_hash       TEXT NOT NULL,
  text_encrypted  BYTEA,
  decision        TEXT NOT NULL,
  risk_score      NUMERIC NOT NULL DEFAULT 0,
  matched_rules   TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  categories      TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  policy_version  TEXT,
  latency_ms      INT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_tenant_time ON decision_events(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_domain_time ON decision_events(domain, created_at DESC);

CREATE TABLE IF NOT EXISTS api_keys (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID REFERENCES tenants(id),
  key_hash        TEXT NOT NULL UNIQUE,
  scopes          TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  allowed_domains TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS test_cases (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  domain            TEXT NOT NULL,
  locale            TEXT NOT NULL,
  io_type           TEXT NOT NULL,
  input_text        TEXT NOT NULL,
  expected_decision TEXT NOT NULL,
  expected_rule_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  tags              TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- Admin Service tables (opt-in deployment via docker-compose.admin.yml).
-- =====================================================================

CREATE TABLE IF NOT EXISTS admin_users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  totp_secret   TEXT,
  totp_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
  role          TEXT NOT NULL DEFAULT 'admin'
                 CHECK (role IN ('admin','super_admin','viewer')),
  status        TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','disabled')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS admin_login_history (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  email      TEXT NOT NULL,
  ip         TEXT,
  user_agent TEXT,
  success    BOOLEAN NOT NULL,
  reason     TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_login_user_time
  ON admin_login_history(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS admin_audit_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id    UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  actor_email TEXT,
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   TEXT,
  payload     JSONB,
  ip          TEXT,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_audit_actor_time
  ON admin_audit_log(actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_action_time
  ON admin_audit_log(action, created_at DESC);

-- Seed the always-on `global` domain. Sub-domains are seeded by Policy Engine at boot
-- by reading <POLICY_DIR>/<domain>/<category>/<io>.<locale>.json bundles.
INSERT INTO domains (domain_key, display_name, description, regulation_tags, inherits_from)
VALUES (
  'global',
  '{"ko-KR":"공통(전역)","en":"Global"}'::jsonb,
  'Domain-agnostic privacy and safety baseline applied to every request.',
  ARRAY['KR_PIPA','EU_GDPR','US_CCPA','JP_APPI'],
  ARRAY[]::TEXT[]
)
ON CONFLICT (domain_key) DO NOTHING;
