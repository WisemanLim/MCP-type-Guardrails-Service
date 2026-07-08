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

-- Phase 2 domains. Must be seeded BEFORE Policy Engine bulk-inserts rules
-- whose `domain` column FK-references domains.domain_key. Order matters:
-- parent ('manufacturing') before child ('manufacturing-food').
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES (
  'manufacturing',
  'global',
  '{"ko-KR":"제조","en":"Manufacturing"}'::jsonb,
  'Manufacturing-industry baseline. Inherits from global.',
  ARRAY[]::TEXT[],
  ARRAY['global']
)
ON CONFLICT (domain_key) DO NOTHING;

INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES (
  'manufacturing-food',
  'manufacturing',
  '{"ko-KR":"제조-식품","en":"Manufacturing - Food"}'::jsonb,
  'Food manufacturing vertical. Inherits from manufacturing > global.',
  ARRAY[]::TEXT[],
  ARRAY['manufacturing','global']
)
ON CONFLICT (domain_key) DO NOTHING;

-- Additional manufacturing verticals. All inherit manufacturing > global.
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES
  ('manufacturing-chemical', 'manufacturing',
   '{"ko-KR":"제조-화학","en":"Manufacturing - Chemical"}'::jsonb,
   'Chemical manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_CCA','KR_CERA','EU_REACH','US_TSCA','GHS_SDS'], ARRAY['manufacturing','global']),
  ('manufacturing-pharma', 'manufacturing',
   '{"ko-KR":"제조-제약","en":"Manufacturing - Pharmaceutical"}'::jsonb,
   'Pharmaceutical manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_PHARMA_ACT','KR_GMP','US_FDA_21CFR211','US_FDA_21CFR11','ICH_GCP_E6'], ARRAY['manufacturing','global']),
  ('manufacturing-automotive', 'manufacturing',
   '{"ko-KR":"제조-자동차","en":"Manufacturing - Automotive"}'::jsonb,
   'Automotive manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_VSSA','UNECE_WP29','ISO_26262','ISO_21448','IATF_16949'], ARRAY['manufacturing','global']),
  ('manufacturing-electronics', 'manufacturing',
   '{"ko-KR":"제조-전자","en":"Manufacturing - Electronics"}'::jsonb,
   'Electronics manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_EPS','KR_ROHS','EU_ROHS2','EU_CE','US_FCC_PART15','EAR','ITAR'], ARRAY['manufacturing','global'])
ON CONFLICT (domain_key) DO NOTHING;

-- Finance verticals. Parent 'finance' baseline first, then 3 leaves.
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES (
  'finance',
  'global',
  '{"ko-KR":"금융","en":"Finance"}'::jsonb,
  'Finance-industry baseline. Inherits from global.',
  ARRAY[]::TEXT[],
  ARRAY['global']
)
ON CONFLICT (domain_key) DO NOTHING;

INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES
  ('finance-banking', 'finance',
   '{"ko-KR":"금융-은행","en":"Finance - Banking"}'::jsonb,
   'Banking vertical. Inherits finance > global.',
   ARRAY['KR_FSCMA','KR_FCPA','KR_EFT','KR_MLPPA','FATCA','GLBA'], ARRAY['finance','global']),
  ('finance-insurance', 'finance',
   '{"ko-KR":"금융-보험","en":"Finance - Insurance"}'::jsonb,
   'Insurance vertical. Inherits finance > global.',
   ARRAY['KR_IBA','KR_FCPA','KR_IAFA'], ARRAY['finance','global']),
  ('finance-securities-misc', 'finance',
   '{"ko-KR":"금융-증권","en":"Finance - Securities & Misc"}'::jsonb,
   'Securities and other financial services vertical. Inherits finance > global.',
   ARRAY['KR_FSCMA','MiFID_II','SEC_REG','IOSCO_IOSCO'], ARRAY['finance','global'])
ON CONFLICT (domain_key) DO NOTHING;

-- Healthcare & public-administration leaf domains (inherit global directly).
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES
  ('healthcare-clinical', 'global',
   '{"ko-KR":"의료-임상","en":"Healthcare - Clinical"}'::jsonb,
   'Clinical healthcare vertical. Inherits from global.',
   ARRAY['KR_MED_ACT','US_HIPAA','EU_GDPR_Art9','KR_BIOETH','US_FDA_SAMD'], ARRAY['global']),
  ('public-administration', 'global',
   '{"ko-KR":"공공행정","en":"Public Administration"}'::jsonb,
   'Public administration vertical. Inherits from global.',
   ARRAY['KR_APA','KR_FOIA','KR_PIPA','KR_ANTI_CORRUPT'], ARRAY['global'])
ON CONFLICT (domain_key) DO NOTHING;

-- Healthcare welfare leaves (inherit global directly).
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES
  ('healthcare-residential-welfare', 'global',
   '{"ko-KR":"의료-거주복지","en":"Healthcare - Residential Welfare"}'::jsonb,
   'Residential welfare (nursing homes, long-term care, disability facilities). Inherits from global.',
   ARRAY['KR_LTCI','KR_ELDERLY_WELFARE','KR_DISABILITY_WELFARE','US_HIPAA','KR_PIPA'], ARRAY['global']),
  ('healthcare-non-residential-welfare', 'global',
   '{"ko-KR":"의료-비거주복지","en":"Healthcare - Non-Residential Welfare"}'::jsonb,
   'Non-residential welfare (home care, community social services). Inherits from global.',
   ARRAY['KR_SOCIAL_WELFARE','KR_CHILD_WELFARE','KR_DV_PREVENTION','KR_PIPA'], ARRAY['global'])
ON CONFLICT (domain_key) DO NOTHING;

-- Additional manufacturing verticals (inherit manufacturing > global).
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES
  ('manufacturing-beverage', 'manufacturing',
   '{"ko-KR":"제조-음료","en":"Manufacturing - Beverage"}'::jsonb,
   'Beverage manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_LIQUOR_TAX','KR_FSC','KR_OSH'], ARRAY['manufacturing','global']),
  ('manufacturing-tobacco', 'manufacturing',
   '{"ko-KR":"제조-담배","en":"Manufacturing - Tobacco"}'::jsonb,
   'Tobacco manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_TOBACCO_BUSINESS','KR_HEALTH_PROMOTION','WHO_FCTC'], ARRAY['manufacturing','global']),
  ('manufacturing-textile', 'manufacturing',
   '{"ko-KR":"제조-섬유","en":"Manufacturing - Textile"}'::jsonb,
   'Textile manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_QUALITY_LABEL','EU_REACH','KR_CCA','OEKO_TEX'], ARRAY['manufacturing','global']),
  ('manufacturing-apparel', 'manufacturing',
   '{"ko-KR":"제조-의류","en":"Manufacturing - Apparel"}'::jsonb,
   'Apparel manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_QUALITY_LABEL','KR_EPS','KR_FTA_ORIGIN','OEKO_TEX'], ARRAY['manufacturing','global']),
  ('manufacturing-rubber-plastics', 'manufacturing',
   '{"ko-KR":"제조-고무플라스틱","en":"Manufacturing - Rubber & Plastics"}'::jsonb,
   'Rubber/plastics manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_CCA','EU_REACH','KR_ROHS','KR_OSH'], ARRAY['manufacturing','global']),
  ('manufacturing-metal-primary', 'manufacturing',
   '{"ko-KR":"제조-1차금속","en":"Manufacturing - Primary Metal"}'::jsonb,
   'Primary metal manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_ENV_ACT','KR_AIR_ACT','KR_WATER_ACT','KR_OSH'], ARRAY['manufacturing','global']),
  ('manufacturing-electrical', 'manufacturing',
   '{"ko-KR":"제조-전기장비","en":"Manufacturing - Electrical Equipment"}'::jsonb,
   'Electrical equipment manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_EPS','EU_CE','IEC_60335','KR_ENERGY_EFFICIENCY'], ARRAY['manufacturing','global']),
  ('manufacturing-machinery', 'manufacturing',
   '{"ko-KR":"제조-기계","en":"Manufacturing - Machinery"}'::jsonb,
   'Machinery manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_OSH','EU_MACHINERY_DIRECTIVE','ISO_12100','EU_CE'], ARRAY['manufacturing','global']),
  ('manufacturing-other-transport', 'manufacturing',
   '{"ko-KR":"제조-기타운송장비","en":"Manufacturing - Other Transport Equipment"}'::jsonb,
   'Aircraft/ship/rail-vehicle manufacturing vertical. Inherits manufacturing > global.',
   ARRAY['KR_AVIATION_SAFETY','KR_SHIP_SAFETY','FAA_14CFR','IMO_SOLAS','UNECE'], ARRAY['manufacturing','global'])
ON CONFLICT (domain_key) DO NOTHING;

-- Arts/sports/recreation leaf (inherits global directly).
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES (
  'arts-recreation', 'global',
  '{"ko-KR":"예술·스포츠·여가","en":"Arts, Sports & Recreation"}'::jsonb,
  'Arts/sports/recreation services vertical. Inherits from global.',
  ARRAY['KR_COPYRIGHT','KR_PERFORMANCE_ACT','KR_SPORTS_FACILITY','KR_OSH','KR_PIPA'],
  ARRAY['global']
)
ON CONFLICT (domain_key) DO NOTHING;
