#!/usr/bin/env bash
# ============================================================================
# hlh-grafana-prometheus-ct — Deploy Prometheus + Grafana to hlh-docker
# ============================================================================
# Target: hlh-docker LXC 109 (192.168.1.9)
#   Grafana      http://192.168.1.14:80  (macvlan dedicated IP — CANONICAL, LAN;
#                this is what grafana.mizertech.net resolves to)
#              http://192.168.1.9:3000   (nginx grafana-proxy — VPN + inside-LXC
#                path; .14 is unreachable there: macvlan-on-veth can't hairpin
#                ARP and the VPN endpoint drops .14)
#   Prometheus   http://192.168.1.9:9090 (external UI)
#                http://prometheus:9090  (internal, Grafana datasource)
#   2026-10-08: vLLM (192.168.1.13) decommissioned — no longer scraped.
# Storage: /vault/grafana on host ZFS RaidZ1-6TB/vault (mp1) — vault dataset,
#          survives LXC rebuilds
#
# Runs in two modes:
#   1. Inside hlh-docker (recommended): run directly on LXC 109 (root@hlh-docker)
#      — note: .14 CANNOT be health-checked from inside the LXC (ARP hairpin),
#      so in this mode the macvlan check degrades to IP-assignment + in-container
#      checks; verify .14 from a LAN client afterwards.
#   2. On prox01: via pct exec 109 — .14 IS checkable from here (LAN side).
#
# Usage:
#   ./deploy-hlh-grafana-prometheus.sh --plan    # dry-run
#   ./deploy-hlh-grafana-prometheus.sh --apply   # deploy
#   ./deploy-hlh-grafana-prometheus.sh --nuke    # down + redeploy (data PRESERVED —
#                                                 #   DATA_DIR is durable vault storage,
#                                                 #   greenfield containers reuse it)
#   ./deploy-hlh-grafana-prometheus.sh --nuke --wipe-data
#                                                 #   ALSO destroy data (old behavior)
#
# Env overrides: MONITOR_IP=192.168.1.14, MACVLAN_NAME, PROM_RETENTION=15d
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LXC_VMID="${HLH_LXC_VMID:-109}"
LXC_IP="${HLH_LXC_IP:-192.168.1.9}"
MONITOR_IP="${MONITOR_IP:-192.168.1.14}"
GRAFANA_PORT="${GRAFANA_PORT:-80}"
MONITOR_URL="http://${MONITOR_IP}:${GRAFANA_PORT}"
PROXY_PORT="${PROXY_PORT:-3000}"
PROXY_URL="http://${LXC_IP}:${PROXY_PORT}"
MACVLAN_NAME="${MACVLAN_NAME:-macvlan}"
MACVLAN_PARENT="${MACVLAN_PARENT:-eth0}"
MACVLAN_SUBNET="${MACVLAN_SUBNET:-192.168.1.0/24}"
MACVLAN_GATEWAY="${MACVLAN_GATEWAY:-192.168.1.1}"
DATA_DIR="/vault/grafana"
PROM_RETENTION="${PROM_RETENTION:-15d}"

MODE="plan"
NUKE=0
WIPE_DATA=0

# --- colour helpers ---
COLOUR_RESET=""; COLOUR_GREEN=""; COLOUR_RED=""; COLOUR_YELLOW=""; COLOUR_BOLD=""
if [[ -t 1 ]]; then
  COLOUR_GREEN=$(printf '\033[32m'); COLOUR_RED=$(printf '\033[31m')
  COLOUR_YELLOW=$(printf '\033[33m'); COLOUR_BOLD=$(printf '\033[1m')
  COLOUR_RESET=$(printf '\033[0m')
fi
info()    { printf "${COLOUR_BOLD}[INFO]${COLOUR_RESET}  %s\n" "$*"; }
ok()      { printf "${COLOUR_GREEN}[ OK ]${COLOUR_RESET}  %s\n" "$*"; }
warn()    { printf "${COLOUR_YELLOW}[WARN]${COLOUR_RESET}  %s\n" "$*"; }
fail()    { printf "${COLOUR_RED}[FAIL]${COLOUR_RESET}  %s\n" "$*" >&2; }
section() { printf "\n${COLOUR_BOLD}=== %s ===${COLOUR_RESET}\n" "$*"; }

usage() {
  cat <<USAGE
Usage: $0 [options]

Run inside hlh-docker (recommended) or on prox01 via pct:

  --plan          Dry-run (default) — validates compose, shows what would be done
  --apply         Deploy stack (creates/reuses macvlan, copies configs, up -d)
  --nuke          Down stack, then redeploy — DATA PRESERVED (lives on durable vault)
  --wipe-data     With --nuke: also destroy the data dirs (pre-2026-10-08 behavior)
  -h, --help      Show this help

Examples:
  # inside hlh-docker:
  ./deploy-hlh-grafana-prometheus.sh --plan
  ./deploy-hlh-grafana-prometheus.sh --apply

  # on prox01:
  bash deploy-hlh-grafana-prometheus.sh --apply

Env:
  MONITOR_IP=${MONITOR_IP}  MACVLAN_NAME=${MACVLAN_NAME}  PROM_RETENTION=${PROM_RETENTION}

Grafana:      ${MONITOR_URL}  (macvlan, LAN canonical — grafana.mizertech.net)
              ${PROXY_URL}    (proxy — VPN + inside LXC)
Prometheus:   http://${LXC_IP}:9090 (UI) / http://prometheus:9090 (internal)
Data:         ${DATA_DIR}/prometheus_data + ${DATA_DIR}/grafana_data (ZFS vault via mp1)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) MODE="plan" ;;
    --apply) MODE="apply" ;;
    --nuke) MODE="apply"; NUKE=1 ;;
    --wipe-data) WIPE_DATA=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

if [[ "$WIPE_DATA" -eq 1 && "$NUKE" -eq 0 ]]; then
  fail "--wipe-data only applies with --nuke" >&2
  exit 1
fi

# --- detect execution context ---
HAS_PCT=0; IN_LXC=0
if command -v pct >/dev/null 2>&1; then HAS_PCT=1; fi
if [[ "$(hostname 2>/dev/null)" == "hlh-docker" ]]; then IN_LXC=1; fi
if [[ $HAS_PCT -eq 0 ]] && command -v docker >/dev/null 2>&1 && [[ -d "/srv/data" ]]; then IN_LXC=1; fi

# --- helpers: abstract pct vs direct ---
lxc_exec() {
  if [[ $HAS_PCT -eq 1 ]] && [[ $IN_LXC -eq 0 ]]; then
    pct exec "$LXC_VMID" -- bash -lc "$1"
  else
    bash -lc "$1"
  fi
}
push_file() {
  local src="$1" dst="$2"
  if [[ $HAS_PCT -eq 1 ]] && [[ $IN_LXC -eq 0 ]]; then
    if pct push "$LXC_VMID" "$src" "$dst" --perms 0644 >/dev/null 2>&1; then return 0; fi
    if command -v base64 >/dev/null 2>&1; then
      base64 -w0 "$src" | pct exec "$LXC_VMID" -- bash -lc "base64 -d > '$dst' && chmod 0644 '$dst'"
      return $?
    fi
    cat "$src" | pct exec "$LXC_VMID" -- bash -lc "cat > '$dst' && chmod 0644 '$dst'"
  else
    # direct inside LXC
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    chmod 0644 "$dst"
  fi
}

# --- plan mode (works anywhere — no pct/docker daemon required except config check) ---
if [[ "$MODE" == "plan" ]]; then
  section "Plan (what would be done)"
  for req in docker-compose.yml grafana-proxy.conf prometheus.yml grafana/provisioning/datasources/datasource.yml grafana/provisioning/dashboards/dashboards.yml; do
    if [[ ! -f "${SCRIPT_DIR}/${req}" ]]; then fail "Missing ${req} in ${SCRIPT_DIR}" >&2; exit 1; fi
  done
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found locally — skipping local compose validation (will validate in target on --apply)"
  elif ! docker compose version >/dev/null 2>&1; then
    warn "docker compose plugin not found locally — skipping local compose validation (will validate in target on --apply)"
  elif docker compose -f "${SCRIPT_DIR}/docker-compose.yml" config >/dev/null; then
    ok "docker-compose.yml valid (config check)"
  else
    fail "docker-compose.yml invalid — see error above (run: docker compose -f ${SCRIPT_DIR}/docker-compose.yml config)" >&2; exit 1
  fi
  if command -v promtool >/dev/null 2>&1; then
    promtool check config "${SCRIPT_DIR}/prometheus.yml" >/dev/null && ok "prometheus.yml valid (promtool)" || { fail "prometheus.yml invalid"; exit 1; }
  else
    info "promtool not installed — syntax not checked (will validate if available)"
  fi
  if [[ $IN_LXC -eq 1 ]]; then
    info "Context: inside hlh-docker (direct docker, no pct)"
  elif [[ $HAS_PCT -eq 1 ]]; then
    info "Context: on prox01 (will use pct exec ${LXC_VMID})"
  else
    info "Context: laptop (no pct, no docker daemon — plan only)"
  fi
  info "Would ensure data dirs:"
  info "  ${DATA_DIR}/prometheus_data (0755)"
  info "  ${DATA_DIR}/grafana_data (0755, chown 472:472 for grafana UID)"
  info "Would ensure macvlan network:"
  info "  docker network inspect ${MACVLAN_NAME} || create (or reuse an existing macvlan on ${MACVLAN_SUBNET})"
  info "Would copy into ${DATA_DIR}:"
  info "  docker-compose.yml, grafana-proxy.conf, prometheus.yml,"
  info "  grafana/provisioning/*, grafana/dashboards/* (stale .json removed first), .env (if present)"
  info "Would deploy:"
  info "  cd ${DATA_DIR} && docker compose down --remove-orphans && docker compose pull && docker compose up -d"
  info "Would verify:"
  info "  docker ps --filter name=prometheus/grafana"
  info "  docker inspect grafana → IP ${MONITOR_IP} on ${MACVLAN_NAME}"
  info "  curl -sf ${MONITOR_URL}/api/health (macvlan; from LAN side in pct mode)"
  info "  curl -sf ${PROXY_URL}/api/health (proxy; inside LXC + LAN side)"
  info "  docker exec prometheus wget -qO- http://localhost:9090/-/healthy (Prometheus)"
  info "  /api/v1/targets — all scrape targets must be up (fail otherwise)"
  printf "\n"
  printf "  %-22s %s\n" "Host LXC:" "${LXC_VMID} hlh-docker ${LXC_IP}"
  printf "  %-22s %s\n" "Context:" "$([[ $IN_LXC -eq 1 ]] && echo "inside hlh-docker (direct)" || ([[ $HAS_PCT -eq 1 ]] && echo "prox01 via pct" || echo "laptop"))"
  printf "  %-22s %s\n" "Grafana (LAN):" "${MONITOR_URL} (macvlan, grafana.mizertech.net)"
  printf "  %-22s %s\n" "Grafana (VPN):" "${PROXY_URL} (proxy)"
  printf "  %-22s %s\n" "Prometheus:" "http://${LXC_IP}:9090 (UI) / http://prometheus:9090 (datasource)"
  printf "  %-22s %s\n" "Scrape targets:" "llamacpp 192.168.1.12:80 + 192.168.1.11:80 (epu)"
  printf "  %-22s %s\n" "Retention:" "${PROM_RETENTION}"
  printf "  %-22s %s\n" "Data (ZFS vault):" "${DATA_DIR}"
  info "Plan complete — no changes made. Run with --apply to deploy."
  info "Inside hlh-docker: ./deploy-hlh-grafana-prometheus.sh --apply"
  exit 0
fi

# --- pre-flight for --apply / --nuke (must run on target host) ---
section "Pre-flight checks"
if [[ $IN_LXC -eq 1 ]]; then
  ok "Running inside hlh-docker (direct mode)"
  # Confirm we are actually on hlh-docker (hostname or IP check, non-fatal)
  if [[ "$(hostname 2>/dev/null)" != "hlh-docker" ]]; then
    warn "hostname is $(hostname 2>/dev/null), expected hlh-docker — continuing"
  fi
elif [[ $HAS_PCT -eq 1 ]]; then
  ok "Running on prox01 (pct mode, target LXC ${LXC_VMID})"
  if ! pct status "$LXC_VMID" >/dev/null 2>&1; then
    fail "LXC ${LXC_VMID} does not exist. Deploy hlh-docker first." >&2; exit 1
  fi
  if [[ "$(pct status "$LXC_VMID" 2>/dev/null)" != *"running"* ]]; then
    fail "LXC ${LXC_VMID} not running. pct start ${LXC_VMID}" >&2; exit 1
  fi
  ok "LXC ${LXC_VMID} exists and running"
else
  fail "Cannot determine context. Run inside hlh-docker (root@hlh-docker) or on prox01 with pct." >&2
  exit 1
fi

# Docker must be available in target
if ! lxc_exec "command -v docker >/dev/null 2>&1"; then
  fail "docker not found in target. Ensure hlh-docker has Docker Engine." >&2; exit 1
fi
ok "docker found"

# /srv/data must be on the ZFS data dataset. (2026-09-28 incident: a manual
# `mount` of the dataset does not survive host reboots — /srv/data silently
# reverted to a plain rpool directory and all docker state landed on the
# 108G NVMe boot pool. Full rpool = host won't boot.)
DATA_SRC=$(lxc_exec "df --output=source /srv/data 2>/dev/null | tail -1")
if [[ "$DATA_SRC" != *hlh-docker-data* ]]; then
  fail "/srv/data source is '${DATA_SRC}' (expected *hlh-docker-data*).\n  Fix on prox01: zfs set mountpoint=/srv/data RaidZ1-6TB/hlh-docker-data\n  Refusing to deploy onto rpool." >&2
  exit 1
fi
ok "/srv/data is on ZFS: ${DATA_SRC}"

for req in docker-compose.yml grafana-proxy.conf prometheus.yml grafana/provisioning/datasources/datasource.yml grafana/provisioning/dashboards/dashboards.yml; do
  if [[ ! -f "${SCRIPT_DIR}/${req}" ]]; then fail "Missing ${req} in ${SCRIPT_DIR}" >&2; exit 1; fi
done
ok "local compose + configs present"

if command -v promtool >/dev/null 2>&1; then
  promtool check config "${SCRIPT_DIR}/prometheus.yml" >/dev/null && ok "prometheus.yml valid (local promtool)" || { fail "prometheus.yml invalid"; exit 1; }
else
  info "promtool not installed locally — will validate in target if available"
fi

if ! lxc_exec "docker compose version >/dev/null 2>&1"; then
  warn "docker compose plugin not found in target — may fail"
else
  ok "docker compose plugin available in target"
fi

if ! command -v docker >/dev/null 2>&1; then
  warn "docker not found locally — skipping local compose check (target check runs below)"
elif ! docker compose version >/dev/null 2>&1; then
  warn "docker compose plugin not found locally — skipping local compose check (target check runs below)"
elif docker compose -f "${SCRIPT_DIR}/docker-compose.yml" config >/dev/null; then
  ok "docker-compose.yml valid (local config check)"
else
  fail "docker-compose.yml invalid locally — see error above" >&2; exit 1
fi

# --- nuke mode ---
# 2026-10-08: nuke no longer deletes data. DATA_DIR lives on durable vault
# storage (RaidZ1-6TB/vault) — the whole point of the 2026-10-07 migration
# was that data survives teardowns and CT rebuilds. Nuke = fresh containers,
# same data. The old rm -rf silently destroyed durable data (and 14h of
# history). Explicit --wipe-data restores that behavior when it's actually wanted.
if [[ "$NUKE" -eq 1 ]]; then
  section "Nuke: tearing down existing stack (data PRESERVED at ${DATA_DIR})"
  lxc_exec "cd '${DATA_DIR}' 2>/dev/null && docker compose down --remove-orphans 2>/dev/null || docker rm -f prometheus grafana 2>/dev/null || true"
  if [[ "$WIPE_DATA" -eq 1 ]]; then
    warn "--wipe-data: destroying durable data at ${DATA_DIR}" >&2
    lxc_exec "rm -rf '${DATA_DIR}/prometheus_data' '${DATA_DIR}/grafana_data' 2>/dev/null || true"
    ok "data destroyed (--wipe-data) — redeploy starts fresh"
  else
    ok "containers torn down — data preserved on durable vault; redeploy reuses it"
  fi
fi

# --- ensure data dirs ---
section "Data directories"
lxc_exec "mkdir -p '${DATA_DIR}/prometheus_data' '${DATA_DIR}/grafana_data' '${DATA_DIR}/grafana/provisioning/datasources' '${DATA_DIR}/grafana/provisioning/dashboards' '${DATA_DIR}/grafana/dashboards'"
lxc_exec "chmod 0755 '${DATA_DIR}' '${DATA_DIR}/prometheus_data' '${DATA_DIR}/grafana_data' 2>/dev/null || true"
lxc_exec "chown -R 472:472 '${DATA_DIR}/grafana_data' 2>/dev/null || chown -R 472 '${DATA_DIR}/grafana_data' 2>/dev/null || true"
ok "data dirs ready: ${DATA_DIR}/prometheus_data + grafana_data (472:472)"

# --- ensure macvlan network ---
section "Macvlan network (${MACVLAN_NAME})"
EFFECTIVE_MACVLAN="${MACVLAN_NAME}"
if lxc_exec "docker network inspect '${MACVLAN_NAME}' >/dev/null 2>&1"; then
  ok "macvlan network ${MACVLAN_NAME} already exists"
  lxc_exec "docker network inspect '${MACVLAN_NAME}' | grep -q '${MACVLAN_SUBNET}' && echo 'subnet ok' || echo 'subnet differs (manual check)'"
else
  # Reuse an existing macvlan network already claiming this subnet (e.g. direct_lan,
  # shared with jellyfin). Docker refuses a second macvlan on the same pool:
  # "Pool overlaps with other one on this address space". Reusing keeps Grafana
  # on .14 without overlap.
  OVERLAP="$(lxc_exec "docker network ls --filter driver=macvlan --format '{{.Name}}' 2>/dev/null | while read -r n; do if docker network inspect \"\$n\" 2>/dev/null | grep -q '${MACVLAN_SUBNET}'; then echo \"\$n\"; break; fi; done" | tr -d '\r' | xargs || true)"
  if [[ -n "${OVERLAP:-}" ]]; then
    warn "network ${MACVLAN_NAME} missing but existing macvlan '${OVERLAP}' already uses ${MACVLAN_SUBNET} — reusing it"
    EFFECTIVE_MACVLAN="${OVERLAP}"
    ok "macvlan network ${EFFECTIVE_MACVLAN} reused (subnet ${MACVLAN_SUBNET})"
  else
    info "Creating macvlan ${MACVLAN_NAME} parent=${MACVLAN_PARENT} subnet=${MACVLAN_SUBNET} gw=${MACVLAN_GATEWAY}"
    if lxc_exec "docker network create -d macvlan --subnet '${MACVLAN_SUBNET}' --gateway '${MACVLAN_GATEWAY}' -o parent='${MACVLAN_PARENT}' '${MACVLAN_NAME}' >/dev/null"; then
      ok "macvlan network created"
    else
      fail "Failed to create macvlan ${MACVLAN_NAME}. Check parent: ip link" >&2
      lxc_exec "ip link; docker network ls"
      exit 1
    fi
  fi
fi
if [[ "${EFFECTIVE_MACVLAN}" != "${MACVLAN_NAME}" ]]; then
  info "Effective macvlan network: ${EFFECTIVE_MACVLAN} (requested ${MACVLAN_NAME}) — compose will use it via MACVLAN_NAME"
fi

if lxc_exec "getent hosts ${MONITOR_IP} >/dev/null 2>&1 || ping -c1 -W2 ${MONITOR_IP} >/dev/null 2>&1"; then
  warn "IP ${MONITOR_IP} appears responsive — will verify after deploy it belongs to grafana"
else
  ok "IP ${MONITOR_IP} appears free (pre-deploy ping failed as expected)"
fi

# --- push compose + configs ---
section "Copying stack files to ${DATA_DIR}"

push_file "${SCRIPT_DIR}/docker-compose.yml" "${DATA_DIR}/docker-compose.yml"
push_file "${SCRIPT_DIR}/grafana-proxy.conf" "${DATA_DIR}/grafana-proxy.conf"
ok "copied docker-compose.yml + grafana-proxy.conf"

if [[ "$PROM_RETENTION" != "15d" ]]; then
  info "Overriding retention to ${PROM_RETENTION}"
  lxc_exec "sed -i 's/--storage.tsdb.retention.time=15d/--storage.tsdb.retention.time=${PROM_RETENTION}/' '${DATA_DIR}/docker-compose.yml'"
fi

push_file "${SCRIPT_DIR}/prometheus.yml" "${DATA_DIR}/prometheus.yml"
ok "copied prometheus.yml"

lxc_exec "mkdir -p '${DATA_DIR}/grafana/provisioning/datasources' '${DATA_DIR}/grafana/provisioning/dashboards' '${DATA_DIR}/grafana/dashboards'"
push_file "${SCRIPT_DIR}/grafana/provisioning/datasources/datasource.yml" "${DATA_DIR}/grafana/provisioning/datasources/datasource.yml"
push_file "${SCRIPT_DIR}/grafana/provisioning/dashboards/dashboards.yml" "${DATA_DIR}/grafana/provisioning/dashboards/dashboards.yml"
ok "copied grafana provisioning"

# Dashboards dir is deploy-managed: remove stale JSON (e.g. retired vLLM
# dashboards) so Grafana's file provisioner drops the matching dashboards.
lxc_exec "rm -f '${DATA_DIR}/grafana/dashboards/'*.json 2>/dev/null || true"
if compgen -G "${SCRIPT_DIR}/grafana/dashboards/*.json" >/dev/null 2>&1; then
  for f in "${SCRIPT_DIR}"/grafana/dashboards/*.json; do
    push_file "$f" "${DATA_DIR}/grafana/dashboards/$(basename "$f")"
  done
  ok "copied grafana dashboards (stale .json removed first)"
else
  info "no custom dashboards to push (import via Grafana UI after deploy)"
fi

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  push_file "${SCRIPT_DIR}/.env" "${DATA_DIR}/.env"
  ok "copied .env"
else
  warn ".env not found locally — using defaults admin/admin (copy .env.example to .env and set GF_SECURITY_ADMIN_PASSWORD; only applies to a FRESH grafana_data)"
fi

# Compose resolves ${MACVLAN_NAME} and ${GRAFANA_PORT} from the project .env,
# so the target .env must pin the effective values.
pin_env() {
  local key="$1" val="$2"
  lxc_exec "touch '${DATA_DIR}/.env' && (grep -q '^${key}=' '${DATA_DIR}/.env' && sed -i 's/^${key}=.*/${key}=${val}/' '${DATA_DIR}/.env' || echo '${key}=${val}' >> '${DATA_DIR}/.env') && grep '^${key}=' '${DATA_DIR}/.env'"
}
pin_env MACVLAN_NAME "${EFFECTIVE_MACVLAN}"
pin_env GRAFANA_PORT "${GRAFANA_PORT}"
ok "pinned MACVLAN_NAME=${EFFECTIVE_MACVLAN} + GRAFANA_PORT=${GRAFANA_PORT} in target .env"

if lxc_exec "command -v promtool >/dev/null 2>&1"; then
  if lxc_exec "promtool check config '${DATA_DIR}/prometheus.yml' >/dev/null 2>&1"; then
    ok "prometheus.yml valid in target (promtool)"
  else
    fail "prometheus.yml invalid in target" >&2
    lxc_exec "promtool check config '${DATA_DIR}/prometheus.yml' || true"
    exit 1
  fi
fi

if lxc_exec "cd '${DATA_DIR}' && docker compose config >/dev/null 2>&1"; then
  ok "docker compose config valid in target"
else
  fail "docker compose config invalid in target" >&2
  lxc_exec "cd '${DATA_DIR}' && docker compose config || true"
  exit 1
fi

# --- deploy ---
section "Deploying stack"
info "Pulling images (prometheus v3.5.0 + grafana 11.5.2)..."
lxc_exec "cd '${DATA_DIR}' && docker compose pull 2>&1 | tail -20"
ok "images pulled"

info "Starting containers (down --remove-orphans + up -d)..."
lxc_exec "cd '${DATA_DIR}' && docker compose down --remove-orphans 2>/dev/null || true"
if lxc_exec "cd '${DATA_DIR}' && docker compose up -d 2>&1 | tail -20"; then
  ok "docker compose up -d succeeded"
else
  fail "docker compose up -d failed" >&2
  lxc_exec "cd '${DATA_DIR}' && docker compose logs --tail 50 || docker ps -a"
  exit 1
fi

info "Waiting for containers..."
for i in 1 2 3 4 5 6; do
  if lxc_exec "docker ps --format '{{.Names}}' | grep -q prometheus && docker ps --format '{{.Names}}' | grep -q grafana"; then
    ok "prometheus + grafana running (attempt $i)"
    break
  fi
  sleep 3
  if [[ $i -eq 6 ]]; then
    fail "Containers not running after 18s" >&2
    lxc_exec "docker ps -a; cd '${DATA_DIR}' && docker compose ps; docker logs prometheus 2>&1 | tail -30; docker logs grafana 2>&1 | tail -30"
    exit 1
  fi
done

# --- verification ---
section "Verification"

info "Container status:"
lxc_exec "docker ps --filter name=prometheus --filter name=grafana --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

info "Grafana macvlan IP:"
GRAFANA_IP="$(lxc_exec "docker inspect -f '{{with index .NetworkSettings.Networks \"${EFFECTIVE_MACVLAN}\"}}{{.IPAddress}}{{end}}' grafana 2>/dev/null" | tr -d '\r' | xargs || true)"
if [[ "$GRAFANA_IP" == "$MONITOR_IP" ]]; then
  ok "grafana IP ${GRAFANA_IP} == ${MONITOR_IP}"
else
  fail "grafana IP '${GRAFANA_IP}' expected '${MONITOR_IP}' — check network/IP conflict" >&2
  lxc_exec "docker inspect grafana | grep -A2 IPAddress || true"
  exit 1
fi

info "Prometheus health..."
for i in 1 2 3 4 5; do
  if lxc_exec "docker exec prometheus wget -qO- http://localhost:9090/-/healthy 2>/dev/null | grep -qi healthy"; then
    ok "Prometheus healthy"
    break
  fi
  sleep 3
  if [[ $i -eq 5 ]]; then
    warn "Prometheus health check failed after 15s"
    lxc_exec "docker logs prometheus 2>&1 | tail -20 || true"
  fi
done

# Parse target health locally (python3 on the script host). Prints one line
# per active target; exits 0 only if at least one target exists and ALL are up.
parse_targets() {
  local json="$1"
  python3 - "$json" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    sys.exit(2)
ts = d["data"]["activeTargets"]
for t in ts:
    print("%-12s %-40s %-6s %s" % (
        t["labels"].get("job", "?"),
        t["scrapeUrl"],
        t["health"],
        t.get("lastError", "")[:70]))
if not ts:
    sys.exit(1)
sys.exit(0 if all(t["health"] == "up" for t in ts) else 1)
PYEOF
}

info "Prometheus targets (all must be up)..."
TARGETS_JSON=""
TARGETS_OUT=""
TARGETS_OK=0
for i in $(seq 1 10); do
  TARGETS_JSON="$(lxc_exec "docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null" | tr -d '\r')"
  if TARGETS_OUT="$(parse_targets "$TARGETS_JSON" 2>/dev/null)"; then
    TARGETS_OK=1
    break
  fi
  sleep 4
done
if [[ $TARGETS_OK -eq 1 ]]; then
  info "Target health:"
  printf '%s\n' "$TARGETS_OUT"
  ok "all scrape targets up"
else
  fail "scrape targets not all up — dashboards will show no data for down targets" >&2
  if [[ -n "$TARGETS_OUT" ]]; then
    printf '%s\n' "$TARGETS_OUT" >&2
  else
    printf '%s\n' "${TARGETS_JSON:0:1500}" >&2
  fi
  info "Fix the engine (e.g. pct start <vmid>) or remove the job from prometheus.yml, then re-run --apply"
  exit 1
fi

# Grafana service itself (in-container; always valid regardless of network).
info "Grafana service (in-container :${GRAFANA_PORT})..."
if lxc_exec "docker exec grafana wget -qO- http://localhost:${GRAFANA_PORT}/api/health 2>/dev/null | grep -q ok"; then
  ok "grafana responding in-container"
else
  fail "grafana not responding in-container on :${GRAFANA_PORT}" >&2
  lxc_exec "docker logs grafana 2>&1 | tail -20 || true"
  exit 1
fi

# Proxy path — works from LAN, VPN, and inside the LXC.
proxy_healthy_in_lxc() {
  lxc_exec "curl -sf -m 5 'http://${LXC_IP}:${PROXY_PORT}/api/health' 2>/dev/null | grep -q ok"
}
proxy_healthy_from_host() {
  curl -sf -m 5 "http://${LXC_IP}:${PROXY_PORT}/api/health" 2>/dev/null | grep -q ok
}
info "Grafana via proxy (${PROXY_URL})..."
PROXY_OK=0
for i in 1 2 3 4 5 6; do
  IN_OK=0; HOST_OK=0
  proxy_healthy_in_lxc && IN_OK=1
  if [[ $HAS_PCT -eq 1 && $IN_LXC -eq 0 ]]; then proxy_healthy_from_host && HOST_OK=1; fi
  if [[ $IN_OK -eq 1 ]] && [[ $HAS_PCT -eq 0 || $HOST_OK -eq 1 ]]; then
    EXTRA=""
    [[ $HAS_PCT -eq 1 && $IN_LXC -eq 0 ]] && EXTRA=" + LAN side"
    ok "proxy healthy (${PROXY_URL}, inside LXC${EXTRA})"
    PROXY_OK=1
    break
  fi
  sleep 3
  if [[ $i -eq 6 ]]; then
    warn "proxy health check failed after 18s"
    lxc_exec "docker logs grafana-proxy 2>&1 | tail -20 || true"
  fi
done
if [[ $PROXY_OK -ne 1 ]]; then
  fail "Grafana proxy not reachable at ${PROXY_URL}" >&2
  exit 1
fi

# Macvlan path — the canonical LAN URL (grafana.mizertech.net). The LXC's own
# eth0 (veth) cannot ARP its macvlan children, so this can only be checked
# from the LAN side: prox01 in pct mode. In in-LXC mode we degrade to a
# warning and ask for a manual LAN check.
info "Grafana via macvlan (${MONITOR_URL})..."
MACVLAN_OK=0
if [[ $HAS_PCT -eq 1 && $IN_LXC -eq 0 ]]; then
  for i in 1 2 3 4 5 6; do
    if curl -sf -m 5 "${MONITOR_URL}/api/health" 2>/dev/null | grep -q ok; then
      ok "macvlan healthy (${MONITOR_URL}, LAN side)"
      MACVLAN_OK=1
      break
    fi
    sleep 3
    if [[ $i -eq 6 ]]; then
      warn "macvlan health check failed after 18s"
      lxc_exec "docker inspect grafana --format '{{range .NetworkSettings.Networks}}{{.Name}}: {{.IPAddress}}{{end}}' || true"
    fi
  done
  if [[ $MACVLAN_OK -ne 1 ]]; then
    fail "Grafana not reachable at ${MONITOR_URL} from the LAN — check ARP/switch/firewall on ${MONITOR_IP}" >&2
    exit 1
  fi
else
  warn "cannot check ${MONITOR_URL} from inside the LXC (macvlan-on-veth ARP hairpin) — IP assignment verified above; verify from a LAN client: curl -sf ${MONITOR_URL}/api/health"
fi

info "Grafana → Prometheus datasource..."
if lxc_exec "docker exec grafana wget -qO- http://prometheus:9090/-/healthy 2>/dev/null | grep -qi healthy"; then
  ok "grafana -> prometheus ok"
else
  fail "grafana cannot reach prometheus:9090 — dashboards will not query" >&2
  exit 1
fi

info "Data volumes:"
lxc_exec "ls -lh '${DATA_DIR}/prometheus_data' 2>&1 | head -5; ls -lh '${DATA_DIR}/grafana_data' 2>&1 | head -5; df -h '${DATA_DIR}' 2>&1 | tail -5"

# --- summary ---
section "Deploy summary"
printf "  %-22s %s\n" "Host LXC:" "${LXC_VMID} hlh-docker ${LXC_IP}"
printf "  %-22s %s\n" "Context:" "$([[ $IN_LXC -eq 1 ]] && echo "inside hlh-docker (direct)" || echo "prox01 via pct")"
printf "  %-22s %s\n" "Grafana (LAN):" "${MONITOR_URL} (macvlan, grafana.mizertech.net)"
printf "  %-22s %s\n" "Grafana (VPN):" "${PROXY_URL} (proxy — also works inside LXC)"
printf "  %-22s %s\n" "Prometheus:" "http://${LXC_IP}:9090 (UI) / http://prometheus:9090 (datasource)"
printf "  %-22s %s\n" "Scrape:" "llamacpp 192.168.1.12:80 + 192.168.1.11:80 (epu), 15s"
printf "  %-22s %s\n" "Retention:" "${PROM_RETENTION}"
printf "  %-22s %s\n" "Data (ZFS vault):" "${DATA_DIR}"
echo ""
ok "Deploy complete — Grafana at ${MONITOR_URL} (LAN) and ${PROXY_URL} (VPN/inside LXC)"
info "Credentials: .env or default admin/admin — change the password in the Grafana UI (UI persists it in grafana_data)"
info "Next: open ${MONITOR_URL} (grafana.mizertech.net), datasource http://prometheus:9090 already provisioned, dashboards auto-provisioned"
if [[ $IN_LXC -eq 1 ]]; then
  info "Logs: docker logs -f grafana / prometheus"
  info "Down: cd ${DATA_DIR} && docker compose down"
else
  info "Logs: pct exec ${LXC_VMID} -- docker logs -f grafana / prometheus"
  info "Down: pct exec ${LXC_VMID} -- bash -lc 'cd ${DATA_DIR} && docker compose down'"
fi
