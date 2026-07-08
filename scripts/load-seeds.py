#!/usr/bin/env python3
"""
Seed loader — emit idempotent SQL that loads scripts/*.json into the `rules` table.

Why a standalone loader?
  Rule seeding is normally done by the Policy Engine on first boot
  (PoliciesService.seedIfNeeded). If the DB was started without Policy (e.g. you
  brought up only Postgres/Redis), or Policy could not reach the DB, the `rules`
  table stays empty. This script reproduces the Policy boot-seed exactly — same
  column mapping as DbService.bulkInsertRules, source='file',
  ON CONFLICT (rule_id) DO NOTHING — without needing Node or a running Policy.

It is dependency-free (stdlib only) and does NOT connect to Postgres itself.
It writes SQL to stdout (or --out FILE); the Makefile pipes it into the running
container via `docker compose exec -T postgres psql`. This keeps the loader
runnable anywhere, even with no psql / pg driver on the host.

Each rule row's `domain` FK-references domains.domain_key, so the script first
emits idempotent domain upserts (global → manufacturing → privacy →
manufacturing-food → generic fallback for any other domain found in the seeds).

Seed bundles in this project live alongside this script (scripts/*.json), the
same dir the Policy Engine bind-mounts at /app/seeds. In the current data model
the privacy bundles carry domain="global" (privacy folded into the global
baseline); manufacturing-food bundles carry domain="manufacturing-food". The
loader keys off each bundle's own `domain` field, so either model works.

Usage:
  python3 scripts/load-seeds.py                       # all scripts/*.json -> stdout
  python3 scripts/load-seeds.py --out build/seed.sql  # write to file
  python3 scripts/load-seeds.py --domains global      # only matching domains
  python3 scripts/load-seeds.py --mode reseed         # replace source='file' rows
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
# Current project keeps seed bundles in scripts/ (same dir as this loader),
# which Policy bind-mounts at /app/seeds.
SEED_DIR = SCRIPT_DIR

# Domain metadata for the upsert preamble. parent_key/inherits_from must form a
# valid chain (parent emitted before child). Domains not listed here fall back
# to parent=global, inherits_from={global}.
DOMAIN_META: dict[str, dict] = {
    "global": {
        "parent": None,
        "display": {"ko-KR": "공통(전역)", "en": "Global"},
        "desc": "Domain-agnostic privacy and safety baseline applied to every request.",
        "tags": ["KR_PIPA", "EU_GDPR", "US_CCPA", "JP_APPI"],
        "inherits": [],
    },
    "manufacturing": {
        "parent": "global",
        "display": {"ko-KR": "제조", "en": "Manufacturing"},
        "desc": "Manufacturing-industry baseline. Inherits from global.",
        "tags": [],
        "inherits": ["global"],
    },
    "privacy": {
        "parent": "global",
        "display": {"ko-KR": "개인정보·공통안전", "en": "Privacy & Common Safety"},
        "desc": "PII / safety / compliance baseline. Chains to global.",
        "tags": ["KR_PIPA", "EU_GDPR", "US_HIPAA", "US_CCPA", "JP_APPI", "COPPA", "PCI_DSS"],
        "inherits": ["global"],
    },
    "manufacturing-food": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-식품", "en": "Manufacturing - Food"},
        "desc": "Food manufacturing vertical. Inherits manufacturing > global.",
        "tags": [],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-chemical": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-화학", "en": "Manufacturing - Chemical"},
        "desc": "Chemical manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_CCA", "KR_CERA", "EU_REACH", "US_TSCA", "GHS_SDS"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-pharma": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-제약", "en": "Manufacturing - Pharmaceutical"},
        "desc": "Pharmaceutical manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_PHARMA_ACT", "KR_GMP", "US_FDA_21CFR211", "US_FDA_21CFR11", "ICH_GCP_E6"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-automotive": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-자동차", "en": "Manufacturing - Automotive"},
        "desc": "Automotive manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_VSSA", "UNECE_WP29", "ISO_26262", "ISO_21448", "IATF_16949"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-electronics": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-전자", "en": "Manufacturing - Electronics"},
        "desc": "Electronics manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_EPS", "KR_ROHS", "EU_ROHS2", "EU_CE", "US_FCC_PART15", "EAR", "ITAR"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-beverage": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-음료", "en": "Manufacturing - Beverage"},
        "desc": "Beverage manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_LIQUOR_TAX", "KR_FSC", "KR_OSH"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-tobacco": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-담배", "en": "Manufacturing - Tobacco"},
        "desc": "Tobacco manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_TOBACCO_BUSINESS", "KR_HEALTH_PROMOTION", "WHO_FCTC"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-textile": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-섬유", "en": "Manufacturing - Textile"},
        "desc": "Textile manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_QUALITY_LABEL", "EU_REACH", "KR_CCA", "OEKO_TEX"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-apparel": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-의류", "en": "Manufacturing - Apparel"},
        "desc": "Apparel manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_QUALITY_LABEL", "KR_EPS", "KR_FTA_ORIGIN", "OEKO_TEX"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-rubber-plastics": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-고무플라스틱", "en": "Manufacturing - Rubber & Plastics"},
        "desc": "Rubber/plastics manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_CCA", "EU_REACH", "KR_ROHS", "KR_OSH"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-metal-primary": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-1차금속", "en": "Manufacturing - Primary Metal"},
        "desc": "Primary metal manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_ENV_ACT", "KR_AIR_ACT", "KR_WATER_ACT", "KR_OSH"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-electrical": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-전기장비", "en": "Manufacturing - Electrical Equipment"},
        "desc": "Electrical equipment manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_EPS", "EU_CE", "IEC_60335", "KR_ENERGY_EFFICIENCY"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-machinery": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-기계", "en": "Manufacturing - Machinery"},
        "desc": "Machinery manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_OSH", "EU_MACHINERY_DIRECTIVE", "ISO_12100", "EU_CE"],
        "inherits": ["manufacturing", "global"],
    },
    "manufacturing-other-transport": {
        "parent": "manufacturing",
        "display": {"ko-KR": "제조-기타운송장비", "en": "Manufacturing - Other Transport Equipment"},
        "desc": "Aircraft/ship/rail-vehicle manufacturing vertical. Inherits manufacturing > global.",
        "tags": ["KR_AVIATION_SAFETY", "KR_SHIP_SAFETY", "FAA_14CFR", "IMO_SOLAS", "UNECE"],
        "inherits": ["manufacturing", "global"],
    },
    "finance": {
        "parent": "global",
        "display": {"ko-KR": "금융", "en": "Finance"},
        "desc": "Finance-industry baseline. Inherits from global.",
        "tags": [],
        "inherits": ["global"],
    },
    "finance-banking": {
        "parent": "finance",
        "display": {"ko-KR": "금융-은행", "en": "Finance - Banking"},
        "desc": "Banking vertical. Inherits finance > global.",
        "tags": ["KR_FSCMA", "KR_FCPA", "KR_EFT", "KR_MLPPA", "FATCA", "GLBA"],
        "inherits": ["finance", "global"],
    },
    "finance-insurance": {
        "parent": "finance",
        "display": {"ko-KR": "금융-보험", "en": "Finance - Insurance"},
        "desc": "Insurance vertical. Inherits finance > global.",
        "tags": ["KR_IBA", "KR_FCPA", "KR_IAFA"],
        "inherits": ["finance", "global"],
    },
    "finance-securities-misc": {
        "parent": "finance",
        "display": {"ko-KR": "금융-증권", "en": "Finance - Securities & Misc"},
        "desc": "Securities and other financial services vertical. Inherits finance > global.",
        "tags": ["KR_FSCMA", "MiFID_II", "SEC_REG", "IOSCO_IOSCO"],
        "inherits": ["finance", "global"],
    },
    "healthcare-clinical": {
        "parent": "global",
        "display": {"ko-KR": "의료-임상", "en": "Healthcare - Clinical"},
        "desc": "Clinical healthcare vertical. Inherits from global.",
        "tags": ["KR_MED_ACT", "US_HIPAA", "EU_GDPR_Art9", "KR_BIOETH", "US_FDA_SAMD"],
        "inherits": ["global"],
    },
    "healthcare-residential-welfare": {
        "parent": "global",
        "display": {"ko-KR": "의료-거주복지", "en": "Healthcare - Residential Welfare"},
        "desc": "Residential welfare (nursing homes, long-term care, disability facilities). Inherits from global.",
        "tags": ["KR_LTCI", "KR_ELDERLY_WELFARE", "KR_DISABILITY_WELFARE", "US_HIPAA", "KR_PIPA"],
        "inherits": ["global"],
    },
    "healthcare-non-residential-welfare": {
        "parent": "global",
        "display": {"ko-KR": "의료-비거주복지", "en": "Healthcare - Non-Residential Welfare"},
        "desc": "Non-residential welfare (home care, community social services). Inherits from global.",
        "tags": ["KR_SOCIAL_WELFARE", "KR_CHILD_WELFARE", "KR_DV_PREVENTION", "KR_PIPA"],
        "inherits": ["global"],
    },
    "public-administration": {
        "parent": "global",
        "display": {"ko-KR": "공공행정", "en": "Public Administration"},
        "desc": "Public administration vertical. Inherits from global.",
        "tags": ["KR_APA", "KR_FOIA", "KR_PIPA", "KR_ANTI_CORRUPT"],
        "inherits": ["global"],
    },
    "arts-recreation": {
        "parent": "global",
        "display": {"ko-KR": "예술·스포츠·여가", "en": "Arts, Sports & Recreation"},
        "desc": "Arts/sports/recreation services vertical. Inherits from global.",
        "tags": ["KR_COPYRIGHT", "KR_PERFORMANCE_ACT", "KR_SPORTS_FACILITY", "KR_OSH", "KR_PIPA"],
        "inherits": ["global"],
    },
}

# Fixed emission order so parent rows precede children (FK on parent_key).
DOMAIN_ORDER = [
    "global", "manufacturing", "privacy", "manufacturing-food",
    "manufacturing-chemical", "manufacturing-pharma", "manufacturing-automotive",
    "manufacturing-electronics", "manufacturing-beverage", "manufacturing-tobacco",
    "manufacturing-textile", "manufacturing-apparel", "manufacturing-rubber-plastics",
    "manufacturing-metal-primary", "manufacturing-electrical", "manufacturing-machinery",
    "manufacturing-other-transport",
    "finance", "finance-banking", "finance-insurance", "finance-securities-misc",
    "healthcare-clinical", "healthcare-residential-welfare", "healthcare-non-residential-welfare",
    "public-administration", "arts-recreation",
]


def dollar_quote(s: str) -> str:
    """Postgres dollar-quote a string with a tag guaranteed not to collide."""
    if "$gr$" not in s:
        return f"$gr${s}$gr$"
    i = 0
    while True:
        tag = f"$gr{i}$"
        if tag not in s:
            return f"{tag}{s}{tag}"
        i += 1


def sql_text(s: str) -> str:
    return dollar_quote(s)


def sql_jsonb(obj) -> str:
    return f"{dollar_quote(json.dumps(obj, ensure_ascii=False, sort_keys=True))}::jsonb"


def sql_text_array(items) -> str:
    if not items:
        return "ARRAY[]::text[]"
    inner = ", ".join(dollar_quote(str(x)) for x in items)
    return f"ARRAY[{inner}]::text[]"


def domain_upsert(domain: str) -> str:
    meta = DOMAIN_META.get(domain, {
        "parent": "global",
        "display": {"ko-KR": domain, "en": domain},
        "desc": f"Auto-registered domain {domain}.",
        "tags": [],
        "inherits": ["global"],
    })
    parent = "NULL" if meta["parent"] is None else dollar_quote(meta["parent"])
    return (
        "INSERT INTO domains (domain_key, parent_key, display_name, description, "
        "regulation_tags, inherits_from)\nVALUES (\n"
        f"  {dollar_quote(domain)},\n"
        f"  {parent},\n"
        f"  {sql_jsonb(meta['display'])},\n"
        f"  {sql_text(meta['desc'])},\n"
        f"  {sql_text_array(meta['tags'])},\n"
        f"  {sql_text_array(meta['inherits'])}\n"
        ")\nON CONFLICT (domain_key) DO NOTHING;"
    )


def rule_values(r: dict) -> str:
    return (
        "("
        f"{sql_text(r['ruleId'])}, "
        f"{sql_text(r['domain'])}, "
        f"{sql_text(r['locale'])}, "
        f"{sql_text(r['ioType'])}, "
        f"{sql_text(r['category'])}, "
        f"{sql_text(r['subCategory']) if r.get('subCategory') else 'NULL'}, "
        f"{sql_text(r['severity'])}, "
        f"{int(r['priority'])}, "
        f"{sql_text(r['action'])}, "
        f"{sql_jsonb(r.get('patterns') or {})}, "
        f"{sql_jsonb(r.get('messageTemplate') or {})}, "
        f"{sql_text_array(r.get('regulationTags') or [])}, "
        f"{sql_text_array(r.get('examplesPositive') or [])}, "
        f"{sql_text_array(r.get('examplesNegative') or [])}, "
        f"{'TRUE' if r.get('enabled', True) else 'FALSE'}, "
        f"{sql_text(r.get('version', '1.0.0'))}, "
        "'file'"
        ")"
    )


RULE_COLUMNS = (
    "rule_id, domain, locale, io_type, category, sub_category, "
    "severity, priority, action, pattern_bundle, message_template, "
    "regulation_tags, examples_positive, examples_negative, enabled, version, source"
)


def main() -> int:
    ap = argparse.ArgumentParser(description="Emit SQL to load scripts/*.json into rules.")
    ap.add_argument("--seed-dir", default=str(SEED_DIR), help="dir holding *.json bundles")
    ap.add_argument("--out", default=None, help="write SQL here (default: stdout)")
    ap.add_argument("--domains", default=None,
                    help="comma-separated allowlist of domains to load (default: all)")
    ap.add_argument("--mode", choices=["insert", "reseed"], default="insert",
                    help="insert: ON CONFLICT DO NOTHING. reseed: delete source='file' rows first.")
    args = ap.parse_args()

    seed_dir = Path(args.seed_dir)
    allow = {d.strip() for d in args.domains.split(",")} if args.domains else None

    files = sorted(seed_dir.glob("*.json"))
    if not files:
        print(f"No *.json bundles in {seed_dir}", file=sys.stderr)
        return 1

    domains_seen: list[str] = []
    rows: list[str] = []
    summary: dict[str, int] = {}
    seen_ids: set[str] = set()

    for f in files:
        bundle = json.loads(f.read_text(encoding="utf-8"))
        domain = bundle.get("domain")
        rules = bundle.get("rules") or []
        if not domain or not isinstance(rules, list):
            print(f"skip {f.name}: no domain/rules", file=sys.stderr)
            continue
        if allow is not None and domain not in allow:
            continue
        declared = bundle.get("totalRules")
        if declared is not None and declared != len(rules):
            print(f"WARN {f.name}: totalRules={declared} != len(rules)={len(rules)}", file=sys.stderr)
        if domain not in domains_seen:
            domains_seen.append(domain)
        for r in rules:
            if r.get("domain") != domain:
                print(f"WARN {f.name}: rule {r.get('ruleId')} domain mismatch — skipped", file=sys.stderr)
                continue
            rid = r.get("ruleId")
            if rid in seen_ids:
                print(f"WARN duplicate ruleId {rid} — skipped", file=sys.stderr)
                continue
            seen_ids.add(rid)
            rows.append(rule_values(r))
            summary[domain] = summary.get(domain, 0) + 1

    if not rows:
        print("No rules matched. Nothing to emit.", file=sys.stderr)
        return 1

    # Expand each seen domain to include its parent chain (FK on parent_key),
    # then emit in dependency order (parents first), extras last.
    needed: set[str] = set()
    for d in domains_seen:
        cur = d
        while cur is not None and cur not in needed:
            needed.add(cur)
            cur = DOMAIN_META.get(cur, {}).get("parent")
    ordered_domains = [d for d in DOMAIN_ORDER if d in needed]
    ordered_domains += [d for d in needed if d not in DOMAIN_ORDER]

    out: list[str] = []
    out.append("-- Generated by scripts/load-seeds.py — DO NOT edit by hand.")
    out.append(f"-- domains: {', '.join(f'{d}={summary[d]}' for d in domains_seen)}")
    out.append(f"-- total rules: {len(rows)}  mode: {args.mode}")
    out.append("BEGIN;")
    out.append("")
    out.append("-- Ensure referenced domains exist (rules.domain FK).")
    for d in ordered_domains:
        out.append(domain_upsert(d))
    out.append("")
    if args.mode == "reseed":
        # Only delete domains we actually reinsert (domains_seen), never the
        # ancestor-only rows (e.g. global) that we have no seed file to restore.
        dlist = ", ".join(dollar_quote(d) for d in domains_seen)
        out.append("-- reseed: drop file-sourced rows for these domains (admin rows kept).")
        out.append(f"DELETE FROM rules WHERE source = 'file' AND domain IN ({dlist});")
        out.append("")
    out.append("-- Bulk insert rules. First-writer-wins on rule_id (admin edits preserved).")
    out.append(f"INSERT INTO rules ({RULE_COLUMNS}) VALUES")
    out.append(",\n".join(rows) + "\nON CONFLICT (rule_id) DO NOTHING;")
    out.append("")
    out.append("COMMIT;")
    out.append("")
    # Post-commit visibility (psql echoes this).
    out.append("\\echo 'Rule counts by domain:'")
    out.append("SELECT domain, count(*) FROM rules GROUP BY domain ORDER BY domain;")
    sql = "\n".join(out)

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(sql, encoding="utf-8")
        print(f"Wrote {args.out}: {len(rows)} rules across {len(ordered_domains)} domain(s).",
              file=sys.stderr)
    else:
        sys.stdout.write(sql)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
