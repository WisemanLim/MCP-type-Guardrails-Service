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
  if [[ "${OS_KIND}" == "linux" ]]; then
    local me="${USER:-$(id -un)}"
    if ! id -nG "${me}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      log "Adding ${me} to 'docker' group"
      if sudo usermod -aG docker "${me}"; then
        DAEMON_NEEDS_SG=1
        warn "Added ${me} to 'docker'. Change applies to NEW shells only."
        warn "Current shell still lacks group — script will run docker via 'sg docker -c'."
      else
        warn "usermod failed — docker calls may need sudo"
      fi
    else
      ok "${me} in 'docker' group"
      DAEMON_NEEDS_SG=0
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

  # If current shell lacks 'docker' group (Linux), wrap exec in `sg docker -c`
  # so the make recipes can talk to /var/run/docker.sock without a re-login.
  local cmd="make -C \"${OPS_DIR}\" ${target}"
  local wrapped="${cmd}"
  if [[ "${OS_KIND}" == "linux" ]] \
     && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker \
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
  log "Running: ${wrapped}"
  if [[ "${wrapped}" == sg* ]]; then
    eval "${wrapped}"
  else
    ( cd "${OPS_DIR}" && make "${target}" )
  fi
}

# ─────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────
main() {
  log "Dist-Guardrails-Service: workspace=${WORKSPACE_DIR}"
  detect_os
  bootstrap_tools
  sync_all_repos
  write_compose_env
  load_compose_files
  generate_makefile
  choose_and_run
  ok "Done."
}

main "$@"
