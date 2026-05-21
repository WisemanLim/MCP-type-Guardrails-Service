#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Dist-Guardrails-Service.sh
#
# Bootstrap the Guardrails Service workspace:
#   1. Detect OS (macOS / Debian / Fedora family)
#   2. Verify git + gh are installed; prompt `gh auth login` if needed
#   3. Clone or pull every component repo
#   4. Load the ops project's Makefile / docker-compose configuration
#   5. If Makefile is missing, auto-generate one from docker-compose*.yml
#   6. Interactive menu to choose a compose profile and run it
#   7. Persist last choice as the default for next run
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_DIR="${SCRIPT_DIR}"                    # ops project (this repo)
WORKSPACE_DIR="$(cd "${OPS_DIR}/.." && pwd)"
CONF_FILE="${OPS_DIR}/.dist-guardrails.conf"

# ── Repo map: name → clone-target (relative to WORKSPACE_DIR) ────────
# Ops repo lives at $OPS_DIR; everything else as a sibling.
declare -a REPOS=(
  "MCP-type-Guardrails-Service|MCP-type-Guardrails-Service"
  "Guardrails-Service-Server|Guardrails-Service-Server"
  "Guardrails-Service-Policy-Engine|Guardrails-Service-Policy-Engine"
  "Guardrails-Service-Detection-Engine|Guardrails-Service-Detection-Engine"
  "Guardrails-Service-Audit-Service|Guardrails-Service-Audit-Service"
  "Guardrails-Service-Admin|Guardrails-Service-Admin"
  "Guardrails-Service-Admin-Web|Guardrails-Service-Admin-Web"
)
GH_OWNER="WisemanLim"

# ── Pretty print helpers ─────────────────────────────────────────────
c_reset=$'\033[0m'; c_b=$'\033[1m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_c=$'\033[36m'
log()  { printf '%s▶%s %s\n' "${c_c}" "${c_reset}" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "${c_g}" "${c_reset}" "$*" >&2; }
warn() { printf '%s!%s %s\n' "${c_y}" "${c_reset}" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "${c_r}" "${c_reset}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────
# 1. Detect OS
# ─────────────────────────────────────────────────────────────────────
detect_os() {
  OS_KIND=""; OS_FAMILY=""; PKG_MGR=""; PKG_INSTALL=""
  case "$(uname -s)" in
    Darwin)
      OS_KIND="macos"; OS_FAMILY="bsd"
      if command -v brew >/dev/null 2>&1; then
        PKG_MGR="brew"; PKG_INSTALL="brew install"
      else
        warn "Homebrew not found. Install from https://brew.sh"
      fi
      ;;
    Linux)
      OS_KIND="linux"
      if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID_LIKE:-$ID}" in
          *debian*|*ubuntu*)
            OS_FAMILY="debian"; PKG_MGR="apt"
            PKG_INSTALL="sudo apt-get update && sudo apt-get install -y"
            ;;
          *fedora*|*rhel*|*centos*)
            OS_FAMILY="fedora"
            if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
            PKG_INSTALL="sudo ${PKG_MGR} install -y"
            ;;
          *arch*)
            OS_FAMILY="arch"; PKG_MGR="pacman"
            PKG_INSTALL="sudo pacman -S --noconfirm"
            ;;
          *)
            OS_FAMILY="unknown"
            ;;
        esac
      fi
      ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  ok "OS: ${OS_KIND} (${OS_FAMILY:-unknown}), pkg=${PKG_MGR:-none}"
}

# ─────────────────────────────────────────────────────────────────────
# 2. Ensure git + gh + docker
# ─────────────────────────────────────────────────────────────────────
install_pkg() {
  local pkg="$1"
  [[ -n "${PKG_INSTALL}" ]] || die "No package manager — install ${pkg} manually."
  log "Installing ${pkg} via ${PKG_MGR} …"
  # shellcheck disable=SC2086
  eval "${PKG_INSTALL} ${pkg}"
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd} found: $(command -v "${cmd}")"
  else
    warn "${cmd} missing — attempting install"
    install_pkg "${pkg}"
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} still missing after install"
    ok "${cmd} installed"
  fi
}

ensure_gh_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    log "gh not logged in — launching 'gh auth login'"
    gh auth login
    gh auth status >/dev/null 2>&1 || die "gh auth login failed"
    return
  fi

  local cur
  cur="$(gh api user --jq .login 2>/dev/null || echo 'unknown')"
  ok "gh already authenticated as: ${cur}"

  echo ""
  echo "${c_b}── gh account action ──${c_reset}"
  echo "   1) Keep current account (${cur})  [default]"
  echo "   2) Re-login (gh auth login)"
  echo "   3) Switch account (gh auth switch)"

  local pick
  read -r -p "Selection [1]: " pick
  case "${pick:-1}" in
    1|"")
      ok "Keeping ${cur}"
      ;;
    2)
      log "Re-running gh auth login"
      gh auth login
      ;;
    3)
      log "Available accounts:"
      gh auth status 2>&1 | grep -E 'Logged in to' || true
      if ! gh auth switch; then
        warn "gh auth switch failed — falling back to 'gh auth login'"
        gh auth login
      fi
      ;;
    *)
      warn "Invalid selection — keeping ${cur}"
      ;;
  esac
  gh auth status >/dev/null 2>&1 || die "gh not authenticated after action"
  local now
  now="$(gh api user --jq .login 2>/dev/null || echo 'unknown')"
  ok "Active gh user: ${now}"
}

# Detect / repair the GitHub CLI APT repo keyring on Debian/Ubuntu.
# Symptom: 'apt-get update' emits NO_PUBKEY 23F3D4EA75716059 or
# "cli.github.com … is not signed" — every subsequent install fails.
# Strategy: if gh is already installed, prefer fixing keyring; if the fix
# fails, disable the gh repo (gh keeps working from the existing binary).
repair_apt_gh_keyring() {
  [[ "${OS_FAMILY}" == "debian" ]] || return 0
  local out
  out="$(sudo apt-get update 2>&1 || true)"
  if ! grep -qE 'NO_PUBKEY[[:space:]]+23F3D4EA75716059|cli\.github\.com.*not signed' <<<"${out}"; then
    return 0
  fi
  warn "Broken GitHub CLI APT keyring detected — repairing"
  sudo mkdir -p /etc/apt/keyrings
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null; then
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    if sudo apt-get update -y 2>&1 | grep -qE 'NO_PUBKEY|not signed'; then
      warn "Keyring refresh did not clear apt — disabling gh APT repo (gh binary still works)"
      sudo rm -f /etc/apt/sources.list.d/github-cli.list \
                 /usr/share/keyrings/githubcli-archive-keyring.gpg \
                 /etc/apt/keyrings/githubcli-archive-keyring.gpg
      sudo apt-get update -y >/dev/null
    else
      ok "GitHub CLI keyring restored"
    fi
  else
    warn "Could not fetch gh keyring — disabling gh APT repo"
    sudo rm -f /etc/apt/sources.list.d/github-cli.list \
               /usr/share/keyrings/githubcli-archive-keyring.gpg \
               /etc/apt/keyrings/githubcli-archive-keyring.gpg
    sudo apt-get update -y >/dev/null
  fi
}

# Install Docker on Debian/Ubuntu via Docker's official APT repo.
# Required because the Ubuntu base repo does NOT ship docker-compose-plugin.
install_docker_debian() {
  log "Installing Docker via Docker official APT repo"
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local distro codename arch
  distro="$(. /etc/os-release && echo "${ID}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  case "${distro}" in
    ubuntu|debian) ;;
    *) distro="ubuntu" ;;
  esac
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
  # 1. binary
  if ! command -v docker >/dev/null 2>&1; then
    log "docker missing — installing"
    case "${OS_KIND}" in
      macos) install_pkg "--cask docker" ;;
      linux)
        case "${OS_FAMILY}" in
          debian)
            repair_apt_gh_keyring
            install_docker_debian
            ;;
          fedora) install_pkg "docker docker-compose-plugin" ;;
          arch)   install_pkg "docker docker-compose" ;;
          *)      die "Unsupported Linux family for docker install: ${OS_FAMILY}" ;;
        esac
        ;;
      *) die "Unsupported OS for docker install: ${OS_KIND}" ;;
    esac
    command -v docker >/dev/null 2>&1 || die "docker install failed"
  fi
  ok "docker: $(command -v docker)"

  # 2. daemon + socket access
  # Distinguish three states:
  #   a) docker info OK as current user           → daemon up + group OK
  #   b) docker info fails, but `sudo docker info` OK → daemon up, current
  #      shell lacks 'docker' group access (perm denied on /var/run/docker.sock)
  #   c) `sudo docker info` also fails             → daemon truly offline
  DAEMON_NEEDS_SG=0
  if docker info >/dev/null 2>&1; then
    ok "docker daemon: running"
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    warn "Docker daemon is running, but current shell can't reach the socket"
    warn "Likely cause: ${USER:-$(id -un)} not in the 'docker' group yet"
    DAEMON_NEEDS_SG=1
    ok "docker daemon: running (via sudo probe)"
  else
    case "${OS_KIND}" in
      linux)
        log "Starting docker daemon (systemctl enable --now docker)"
        sudo systemctl enable --now docker || die "Failed to start docker daemon"
        ;;
      macos)
        warn "Docker daemon not running. Launching Docker.app …"
        open -ga Docker 2>/dev/null || true
        log "Waiting up to 60s for docker daemon …"
        local i
        for i in {1..30}; do
          docker info >/dev/null 2>&1 && break
          sleep 2
        done
        ;;
    esac
    docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1 \
      || die "docker daemon offline — start it manually and re-run"
    ok "docker daemon: running"
  fi

  # 3. user in docker group (Linux only)
  # Two distinct checks:
  #   a) /etc/group via `getent group docker` — file-level membership
  #   b) current process supplementary groups via `id -nG` (no arg) — what
  #      the kernel actually uses for socket ACL decisions
  # `id -nG <username>` reads /etc/group and lies about active access:
  # after `usermod -aG` the username is in (a) but the existing shell still
  # lacks (b) until logout/login or `newgrp`. So we treat (b) as truth for
  # the DAEMON_NEEDS_SG decision.
  if [[ "${OS_KIND}" == "linux" ]]; then
    local me="${USER:-$(id -un)}"
    if ! getent group docker 2>/dev/null | grep -qE "(:|,)${me}(,|\$)"; then
      log "Adding ${me} to 'docker' group (/etc/group)"
      if ! sudo usermod -aG docker "${me}"; then
        warn "usermod failed — docker calls may need sudo"
      fi
    else
      ok "${me} is in /etc/group docker"
    fi
    # Truth check: does THIS shell actually carry the docker group?
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      ok "current shell has 'docker' supplementary group"
      DAEMON_NEEDS_SG=0
    else
      warn "Current shell lacks 'docker' supplementary group — docker socket calls will use 'sg docker -c'"
      DAEMON_NEEDS_SG=1
    fi
  fi
  export DAEMON_NEEDS_SG

  # 4. docker compose v2 plugin
  if ! docker compose version >/dev/null 2>&1; then
    log "docker compose v2 missing — installing plugin"
    case "${OS_FAMILY}" in
      debian)
        # Ubuntu base repo lacks docker-compose-plugin. Go through Docker
        # official repo path — also repairs gh keyring on the way.
        repair_apt_gh_keyring
        install_docker_debian
        ;;
      fedora) install_pkg "docker-compose-plugin" ;;
      arch)   install_pkg "docker-compose" ;;
      *)      warn "Install 'docker compose' v2 plugin manually for ${OS_KIND}" ;;
    esac
    docker compose version >/dev/null 2>&1 || die "docker compose v2 still missing"
  fi
  ok "docker compose: $(docker compose version --short 2>/dev/null || echo unknown)"
}

ensure_make() {
  if command -v make >/dev/null 2>&1; then
    ok "make: $(command -v make)"
    return
  fi
  log "make missing — installing"
  install_pkg make
  command -v make >/dev/null 2>&1 || die "make install failed"
}

bootstrap_tools() {
  ensure_cmd git
  ensure_cmd gh
  ensure_gh_auth
  ensure_docker
  ensure_make
}

# ─────────────────────────────────────────────────────────────────────
# 3. Clone / pull every repo
# ─────────────────────────────────────────────────────────────────────
sync_repo() {
  local name="$1" rel="$2"
  local target="${WORKSPACE_DIR}/${rel}"
  local url="https://github.com/${GH_OWNER}/${name}.git"

  if [[ -d "${target}/.git" ]]; then
    log "pull ${name}"
    git -C "${target}" fetch --all --prune >&2
    local branch
    branch="$(git -C "${target}" symbolic-ref --quiet --short HEAD || echo main)"
    git -C "${target}" pull --ff-only origin "${branch}" >&2 || warn "${name}: pull skipped (non-FF or detached)"
  elif [[ -e "${target}" && ! -d "${target}/.git" ]]; then
    warn "${target} exists but is not a git repo — skipping"
  else
    log "clone ${name} → ${target}"
    git clone "${url}" "${target}" >&2
  fi
}

sync_all_repos() {
  log "Workspace: ${WORKSPACE_DIR}"
  local entry name rel
  for entry in "${REPOS[@]}"; do
    name="${entry%%|*}"; rel="${entry##*|}"
    sync_repo "${name}" "${rel}"
  done
  ok "All repos synced"
}

# ─────────────────────────────────────────────────────────────────────
# Known-issue fixups applied after every clone/pull. Idempotent.
# Forces the Admin Docker build to succeed even on hosts that cloned
# before the upstream fix landed.
#
# Currently handled:
#   Guardrails-Service-Admin/
#     - .gitignore line '*.sqlite*' masked src/db/schema.sqlite.ts so the
#       TS source was never committed, breaking `npm run build` inside
#       admin-service Docker image (TS2307: Cannot find module
#       './schema.sqlite'). Patch:
#         a) append '!src/db/schema.sqlite.ts' un-ignore exception
#         b) if the file is missing locally, fetch it from GitHub via
#            authenticated 'gh api' (uses raw content type)
# ─────────────────────────────────────────────────────────────────────
apply_repo_fixups() {
  local admin_dir="${WORKSPACE_DIR}/Guardrails-Service-Admin"
  [[ -d "${admin_dir}/.git" ]] || return 0
  log "Applying known fixups for Guardrails-Service-Admin"

  # Fixup 1: .gitignore exception for the TS schema source.
  local gi="${admin_dir}/.gitignore"
  if [[ -f "${gi}" ]] && grep -qE '^\*\.sqlite\*' "${gi}" \
       && ! grep -qE '^!src/db/schema\.sqlite\.ts' "${gi}"; then
    {
      echo ""
      echo "# Added by Dist-Guardrails-Service.sh — TS source must not match *.sqlite*"
      echo "!src/db/schema.sqlite.ts"
    } >> "${gi}"
    ok "Patched ${gi} with un-ignore for src/db/schema.sqlite.ts"
  fi

  # Fixup 2: materialize the file if remote/local tree still lacks it.
  # Strategy: try gh api raw first; if remote doesn't have it (push hasn't
  # landed), fall back to the bundled canonical content embedded below.
  local f="${admin_dir}/src/db/schema.sqlite.ts"
  if [[ ! -f "${f}" ]]; then
    warn "schema.sqlite.ts missing locally — fetching via gh api"
    mkdir -p "$(dirname "${f}")"
    if gh api -H 'Accept: application/vnd.github.v3.raw' \
         "repos/${GH_OWNER}/Guardrails-Service-Admin/contents/src/db/schema.sqlite.ts" \
         > "${f}" 2>/dev/null && [[ -s "${f}" ]]; then
      ok "Materialized ${f} via gh api"
    else
      rm -f "${f}"
      warn "gh api fetch failed — writing bundled canonical content"
      write_bundled_admin_schema_sqlite "${f}"
      if [[ -s "${f}" ]]; then
        ok "Materialized ${f} from bundled fallback"
      else
        die "Could not produce ${f} — admin-service Docker build will fail"
      fi
    fi
  fi
}

# Canonical content of Guardrails-Service-Admin/src/db/schema.sqlite.ts.
# Used as last-resort fallback when neither the local clone nor the
# remote 'main' branch contains the file (e.g. fix-commit not pushed yet).
write_bundled_admin_schema_sqlite() {
  local out="$1"
  mkdir -p "$(dirname "${out}")"
  cat > "${out}" <<'__SCHEMA_SQLITE_TS__'
/**
 * SQLite schema for Admin service tables. Bootstrapped on first boot when
 * DB_DRIVER=sqlite. Mirrors Postgres tables in init-db.sql.
 *
 * Includes the `rules` table so Admin can CRUD rules in SQLite-only deployments
 * (single-host PoC). When DB_DRIVER=postgres, the table is shared with Policy
 * Engine via the existing Postgres schema in `scripts/init-db.sql`.
 */
export const ADMIN_SQLITE_SCHEMA = `
CREATE TABLE IF NOT EXISTS admin_users (
  id            TEXT PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  totp_secret   TEXT,
  totp_enabled  INTEGER NOT NULL DEFAULT 0,
  role          TEXT NOT NULL DEFAULT 'admin' CHECK (role IN ('admin','super_admin','viewer')),
  status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  last_login_at TEXT
);

CREATE TABLE IF NOT EXISTS admin_login_history (
  id         TEXT PRIMARY KEY,
  user_id    TEXT,
  email      TEXT NOT NULL,
  ip         TEXT,
  user_agent TEXT,
  success    INTEGER NOT NULL,
  reason     TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_admin_login_user_time ON admin_login_history(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS admin_audit_log (
  id          TEXT PRIMARY KEY,
  actor_id    TEXT,
  actor_email TEXT,
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   TEXT,
  payload     TEXT,
  ip          TEXT,
  user_agent  TEXT,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_admin_audit_actor_time ON admin_audit_log(actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_action_time ON admin_audit_log(action, created_at DESC);

CREATE TABLE IF NOT EXISTS rules (
  rule_id           TEXT PRIMARY KEY,
  domain            TEXT NOT NULL,
  locale            TEXT NOT NULL,
  io_type           TEXT NOT NULL CHECK (io_type IN ('input','output','both')),
  category          TEXT NOT NULL,
  sub_category      TEXT,
  severity          TEXT NOT NULL CHECK (severity IN ('low','medium','high','critical')),
  priority          INTEGER NOT NULL DEFAULT 100,
  action            TEXT NOT NULL,
  pattern_bundle    TEXT NOT NULL DEFAULT '{}',
  message_template  TEXT NOT NULL DEFAULT '{}',
  regulation_tags   TEXT NOT NULL DEFAULT '[]',
  examples_positive TEXT NOT NULL DEFAULT '[]',
  examples_negative TEXT NOT NULL DEFAULT '[]',
  enabled           INTEGER NOT NULL DEFAULT 1,
  version           TEXT NOT NULL DEFAULT '1.0.0',
  source            TEXT NOT NULL DEFAULT 'admin'
                     CHECK (source IN ('file','admin','csv')),
  created_at        TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at        TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_rules_domain_locale_io ON rules(domain, locale, io_type) WHERE enabled = 1;
`;
__SCHEMA_SQLITE_TS__
}

# ─────────────────────────────────────────────────────────────────────
# Detect host's primary IPv4 (non-loopback, default-route iface).
# Used so admin-web can bake the right Admin API base URL.
# ─────────────────────────────────────────────────────────────────────
detect_host_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 -o route get 8.8.8.8 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -z "${ip}" ]] && [[ "${OS_KIND}" == "macos" ]]; then
    ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
  fi
  printf '%s' "${ip}"
}

# Pin ADMIN_WEB_API_BASE_URL so the Next.js bundle calls the right host
# when the browser isn't on the same machine as admin-service. NEXT_PUBLIC_*
# vars are baked at admin-web build time — caller must rebuild the image
# after this env change (the function warns explicitly).
write_admin_web_base_url() {
  local envf="${OPS_DIR}/.env"
  local ip; ip="$(detect_host_ip)"
  if [[ -z "${ip}" ]]; then
    warn "Could not detect host IP — keeping ADMIN_WEB_API_BASE_URL default (localhost)"
    return
  fi
  local url="http://${ip}:8084"
  if [[ -f "${envf}" ]] && grep -q '^ADMIN_WEB_API_BASE_URL=' "${envf}"; then
    local cur; cur="$(grep -E '^ADMIN_WEB_API_BASE_URL=' "${envf}" | head -1)"
    if [[ "${cur}" == "ADMIN_WEB_API_BASE_URL=${url}" ]]; then
      ok "ADMIN_WEB_API_BASE_URL already pinned: ${url}"
      return
    fi
    awk -v repl="ADMIN_WEB_API_BASE_URL=${url}" '
      /^ADMIN_WEB_API_BASE_URL=/ {print repl; next} {print}
    ' "${envf}" > "${envf}.new" && mv "${envf}.new" "${envf}"
  else
    printf 'ADMIN_WEB_API_BASE_URL=%s\n' "${url}" >> "${envf}"
  fi
  ok "Wrote ADMIN_WEB_API_BASE_URL=${url} → ${envf}"
  warn "admin-web bakes NEXT_PUBLIC_* at build time — rebuild required:"
  warn "  docker compose -f docker-compose.yml -f docker-compose.privacy.yml \\"
  warn "                 -f docker-compose.admin.yml -f docker-compose.admin-web.yml \\"
  warn "                 build --no-cache admin-web"
  ADMIN_WEB_URL_CHANGED=1
  export ADMIN_WEB_URL_CHANGED
}

# ─────────────────────────────────────────────────────────────────────
# .env writer: pin layout-dependent build-context paths
# docker-compose.yml's detection-engine build context is now driven by
# DETECTION_ENGINE_PATH (default = sibling layout). Auto-detect the real
# location and write/refresh ${OPS_DIR}/.env so 'docker compose build'
# works on any workspace shape.
# ─────────────────────────────────────────────────────────────────────
write_compose_env() {
  [[ -d "${OPS_DIR}" ]] || return
  local detection_rel=""
  if   [[ -d "${OPS_DIR}/../Guardrails-Service-Detection-Engine" ]]; then
    detection_rel="../Guardrails-Service-Detection-Engine"
  elif [[ -d "${OPS_DIR}/../../DA(Python,R,...)/Guardrails-Service-Detection-Engine" ]]; then
    detection_rel='../../DA(Python,R,...)/Guardrails-Service-Detection-Engine'
  else
    warn "Detection-Engine source not found near ${OPS_DIR}"
    return
  fi
  local envf="${OPS_DIR}/.env"
  if [[ -f "${envf}" ]] && grep -q '^DETECTION_ENGINE_PATH=' "${envf}"; then
    awk -v repl="DETECTION_ENGINE_PATH=${detection_rel}" '
      /^DETECTION_ENGINE_PATH=/ {print repl; next} {print}
    ' "${envf}" > "${envf}.new" && mv "${envf}.new" "${envf}"
  else
    printf 'DETECTION_ENGINE_PATH=%s\n' "${detection_rel}" >> "${envf}"
  fi
  ok "Wrote DETECTION_ENGINE_PATH=${detection_rel} → ${envf}"
}

# ─────────────────────────────────────────────────────────────────────
# 4. Load ops compose / Makefile config
# ─────────────────────────────────────────────────────────────────────
load_compose_files() {
  COMPOSE_FILES=()
  while IFS= read -r _line; do
    COMPOSE_FILES+=("${_line}")
  done < <(find "${OPS_DIR}" -maxdepth 1 -type f -name 'docker-compose*.yml' -exec basename {} \; | sort)
  [[ ${#COMPOSE_FILES[@]} -gt 0 ]] || die "No docker-compose*.yml in ${OPS_DIR}"
  log "Compose files: ${COMPOSE_FILES[*]}"
}

# ─────────────────────────────────────────────────────────────────────
# 5. Generate Makefile if missing
# ─────────────────────────────────────────────────────────────────────
generate_makefile() {
  local mk="${OPS_DIR}/Makefile"
  [[ -f "${mk}" ]] && { ok "Makefile present"; return; }
  warn "Makefile missing — generating one from compose files"

  {
    echo "SHELL := /bin/bash"
    echo ""
    echo "# Auto-generated by Dist-Guardrails-Service.sh"
    echo ""
    local base="docker-compose.yml" f flags=""
    [[ -f "${OPS_DIR}/${base}" ]] && flags="-f ${base}"
    echo ".PHONY: help up down ps logs build clean"
    echo ""
    echo "help:"
    echo -e "\t@grep -E '^[a-zA-Z0-9_-]+:.*?## ' \$(MAKEFILE_LIST) | awk 'BEGIN{FS=\":.*?## \"};{printf \"  %-30s %s\\n\", \$\$1, \$\$2}'"
    echo ""
    for f in "${COMPOSE_FILES[@]}"; do
      [[ "${f}" == "${base}" ]] && continue
      local tag="${f#docker-compose.}"; tag="${tag%.yml}"
      echo "up-${tag}: ## up: ${f}"
      echo -e "\tdocker compose ${flags} -f ${f} up -d"
      echo "down-${tag}: ## down: ${f}"
      echo -e "\tdocker compose ${flags} -f ${f} down"
      echo ""
    done
    echo "up: ## up base"
    echo -e "\tdocker compose ${flags} up -d"
    echo "down: ## down base"
    echo -e "\tdocker compose ${flags} down"
    echo "ps:"
    echo -e "\tdocker compose ${flags} ps"
    echo "logs:"
    echo -e "\tdocker compose ${flags} logs -f --tail=200"
    echo "build:"
    echo -e "\tdocker compose ${flags} build"
    echo "clean:"
    echo -e "\tdocker compose ${flags} down -v --remove-orphans"
  } > "${mk}"
  ok "Generated ${mk}"
}

# ─────────────────────────────────────────────────────────────────────
# 6/7. Interactive menu + persisted default
# ─────────────────────────────────────────────────────────────────────
list_make_up_targets() {
  # Prefer the project's own `list-targets` if defined (handles foreach/eval).
  # Fall back to parsing static rules from the Makefile, then to `make -pn`.
  if grep -qE '^list-targets:' "${OPS_DIR}/Makefile" 2>/dev/null; then
    ( cd "${OPS_DIR}" && make -s list-targets 2>/dev/null ) | grep -E '^up-' | sort -u
    return
  fi
  if command -v make >/dev/null 2>&1; then
    ( cd "${OPS_DIR}" && make -pn 2>/dev/null ) \
      | awk -F: '/^[A-Za-z0-9_.\/-]+:/ && $1 ~ /^up-/ {print $1}' \
      | sort -u
    return
  fi
  awk -F: '/^[A-Za-z0-9_.\/-]+:/ && $1 ~ /^up-/ {print $1}' "${OPS_DIR}/Makefile" | sort -u
}

load_default() {
  [[ -f "${CONF_FILE}" ]] || { DEFAULT_TARGET=""; return; }
  # shellcheck disable=SC1090
  . "${CONF_FILE}"
  DEFAULT_TARGET="${LAST_TARGET:-}"
}

save_default() {
  local target="$1"
  printf 'LAST_TARGET=%q\nLAST_RUN=%q\n' "${target}" "$(date -u +%FT%TZ)" > "${CONF_FILE}"
  ok "Saved default → ${target}"
}

choose_and_run() {
  load_default
  TARGETS=()
  while IFS= read -r _line; do
    TARGETS+=("${_line}")
  done < <(list_make_up_targets)
  [[ ${#TARGETS[@]} -gt 0 ]] || die "No up-* targets found in Makefile"

  echo ""
  echo "${c_b}── Choose compose target to run ──${c_reset}"
  local i=1
  for t in "${TARGETS[@]}"; do
    if [[ "${t}" == "${DEFAULT_TARGET}" ]]; then
      printf '  %s%2d)%s %s %s(default)%s\n' "${c_g}" "$i" "${c_reset}" "$t" "${c_y}" "${c_reset}"
    else
      printf '   %2d) %s\n' "$i" "$t"
    fi
    ((i++))
  done

  local prompt="Selection [Enter = ${DEFAULT_TARGET:-none}]: "
  read -r -p "${prompt}" pick
  local target=""
  if [[ -z "${pick}" ]]; then
    [[ -n "${DEFAULT_TARGET}" ]] || die "No default — pick a number"
    target="${DEFAULT_TARGET}"
  elif [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#TARGETS[@]} )); then
    target="${TARGETS[$((pick-1))]}"
  else
    # treat as literal target name
    target="${pick}"
  fi

  save_default "${target}"

  # If current shell lacks 'docker' supplementary group (Linux), wrap exec
  # in `sg docker -c` so make recipes can talk to /var/run/docker.sock
  # without a re-login. Trust ensure_docker's DAEMON_NEEDS_SG flag.
  local cmd="make -C \"${OPS_DIR}\" ${target}"
  local wrapped="${cmd}"
  if [[ "${OS_KIND}" == "linux" ]] \
     && [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] \
     && command -v sg >/dev/null 2>&1; then
    wrapped="sg docker -c 'cd \"${OPS_DIR}\" && make ${target}'"
  fi

  echo "" >&2
  echo "${c_b}▶ Will execute:${c_reset}  ${wrapped}" >&2
  read -r -p "Run now? [Y/n]: " confirm
  case "${confirm:-Y}" in
    [Nn]*)
      warn "Skipped (target saved as default — re-run script to execute)"
      return
      ;;
  esac

  # If ADMIN_WEB_API_BASE_URL was just changed AND the chosen target builds
  # admin-web (any *-admin-web* target), force a no-cache rebuild so the
  # baked NEXT_PUBLIC_* values pick up the new URL.
  if [[ "${ADMIN_WEB_URL_CHANGED:-0}" -eq 1 ]] && [[ "${target}" == *admin-web* ]]; then
    log "ADMIN_WEB_API_BASE_URL changed — rebuilding admin-web (no-cache)"
    local rebuild="docker compose -f docker-compose.yml -f docker-compose.privacy.yml -f docker-compose.admin.yml -f docker-compose.admin-web.yml build --no-cache admin-web"
    if [[ "${wrapped}" == sg* ]]; then
      sg docker -c "cd \"${OPS_DIR}\" && ${rebuild}" >&2 || warn "admin-web rebuild failed"
    else
      ( cd "${OPS_DIR}" && eval "${rebuild}" ) >&2 || warn "admin-web rebuild failed"
    fi
  fi

  log "Running: ${wrapped}"
  local exit_code=0
  if [[ "${wrapped}" == sg* ]]; then
    eval "${wrapped}" || exit_code=$?
  else
    ( cd "${OPS_DIR}" && make "${target}" ) || exit_code=$?
  fi
  if (( exit_code != 0 )); then
    dump_unhealthy_logs
    return "${exit_code}"
  fi
}

# When make fails, surface logs from any gr-* container that isn't Up+healthy,
# so the root cause is visible without re-running. Tail 80 lines per service.
dump_unhealthy_logs() {
  echo "" >&2
  warn "Compose stack failed — collecting logs from unhealthy gr-* containers"
  local use_sg=0
  if [[ "${OS_KIND}" == "linux" ]] \
     && [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] \
     && command -v sg >/dev/null 2>&1; then
    use_sg=1
  fi

  local listing
  if (( use_sg )); then
    listing="$(sg docker -c 'docker ps -a --filter name=gr- --format "{{.Names}}\t{{.Status}}"' 2>/dev/null || true)"
  else
    listing="$(docker ps -a --filter name=gr- --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)"
  fi
  [[ -n "${listing}" ]] || { warn "No gr-* containers found"; return; }

  echo "${listing}" >&2
  while IFS=$'\t' read -r name status; do
    [[ -z "${name}" ]] && continue
    # Skip clearly-healthy ones
    if [[ "${status}" == *"(healthy)"* ]] || { [[ "${status}" == "Up "* ]] && [[ "${status}" != *"(unhealthy)"* ]]; }; then
      continue
    fi
    echo "" >&2
    log "── logs: ${name} (${status}) ──"
    if (( use_sg )); then
      sg docker -c "docker logs --tail=80 '${name}' 2>&1" >&2 || true
    else
      docker logs --tail=80 "${name}" >&2 2>&1 || true
    fi
  done <<<"${listing}"

  auto_seed_missing_domains "${use_sg}"
}

# Self-heal for pg-data volumes initialised before init-db.sql learned about
# the manufacturing / manufacturing-food domains. Triggered when gr-policy
# logs show the FK violation against domains.domain_key. Seeds the parent
# rows directly via `docker exec gr-postgres psql` and restarts gr-policy.
auto_seed_missing_domains() {
  local use_sg="${1:-0}"
  local out
  if (( use_sg )); then
    out="$(sg docker -c 'docker logs --tail=200 gr-policy 2>&1' 2>/dev/null || true)"
  else
    out="$(docker logs --tail=200 gr-policy 2>&1 2>/dev/null || true)"
  fi
  grep -qE 'rules_domain_fkey|Key \(domain\)=\([^)]+\) is not present in table "domains"' <<<"${out}" || return 0

  log "Detected FK violation — seeding missing domain rows into gr-postgres"
  local psql_sql
  read -r -d '' psql_sql <<'__SEED_SQL__' || true
INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES ('manufacturing', 'global', '{"ko-KR":"제조","en":"Manufacturing"}'::jsonb,
        'Manufacturing-industry baseline. Inherits from global.',
        ARRAY[]::TEXT[], ARRAY['global'])
ON CONFLICT (domain_key) DO NOTHING;

INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
VALUES ('manufacturing-food', 'manufacturing', '{"ko-KR":"제조-식품","en":"Manufacturing - Food"}'::jsonb,
        'Food manufacturing vertical. Inherits from manufacturing > global.',
        ARRAY[]::TEXT[], ARRAY['manufacturing','global'])
ON CONFLICT (domain_key) DO NOTHING;
__SEED_SQL__

  local pg_user="${POSTGRES_USER:-guardrails}"
  local pg_db="${POSTGRES_DB:-guardrails}"
  if (( use_sg )); then
    if ! sg docker -c "docker exec -i gr-postgres psql -U ${pg_user} -d ${pg_db}" <<<"${psql_sql}" >&2; then
      warn "psql seed failed — recover with: docker compose ... down -v"
      return
    fi
  else
    if ! docker exec -i gr-postgres psql -U "${pg_user}" -d "${pg_db}" <<<"${psql_sql}" >&2; then
      warn "psql seed failed — recover with: docker compose ... down -v"
      return
    fi
  fi
  ok "Seeded manufacturing + manufacturing-food into domains table"

  log "Restarting gr-policy"
  if (( use_sg )); then
    sg docker -c 'docker restart gr-policy' >&2 || warn "gr-policy restart failed"
  else
    docker restart gr-policy >&2 || warn "gr-policy restart failed"
  fi

  # Wait for gr-policy healthy so depends_on chain can proceed.
  log "Waiting up to 60s for gr-policy to report healthy"
  local i state
  for i in {1..30}; do
    if (( use_sg )); then
      state="$(sg docker -c "docker inspect -f '{{.State.Health.Status}}' gr-policy" 2>/dev/null || echo unknown)"
    else
      state="$(docker inspect -f '{{.State.Health.Status}}' gr-policy 2>/dev/null || echo unknown)"
    fi
    [[ "${state}" == "healthy" ]] && break
    sleep 2
  done
  if [[ "${state}" != "healthy" ]]; then
    warn "gr-policy did not reach healthy in 60s (state=${state}) — dependents still down"
    return
  fi
  ok "gr-policy healthy — bringing up dependents"

  # gr-admin / gr-mcp were stuck in 'Created' because policy was unhealthy.
  # Re-run the same make target the user picked to start them.
  local target="${LAST_TARGET:-${target:-}}"
  [[ -n "${target}" ]] || { warn "LAST_TARGET unknown — run 'make <target>' manually"; return; }
  log "Re-running make ${target}"
  if (( use_sg )); then
    sg docker -c "cd '${OPS_DIR}' && make ${target}" >&2 || warn "follow-up make ${target} failed"
  else
    ( cd "${OPS_DIR}" && make "${target}" ) >&2 || warn "follow-up make ${target} failed"
  fi
  ok "Auto-recovery complete"
}

# ─────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────
main() {
  log "Dist-Guardrails-Service: workspace=${WORKSPACE_DIR}"
  detect_os
  bootstrap_tools
  sync_all_repos
  apply_repo_fixups
  write_compose_env
  write_admin_web_base_url
  load_compose_files
  generate_makefile
  choose_and_run
  ok "Done."
}

main "$@"
