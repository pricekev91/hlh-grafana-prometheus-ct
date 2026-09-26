#!/usr/bin/env bash
# ============================================================================
# hlh-grafana-prometheus-ct — Deploy Prometheus + Grafana to hlh-docker
# ============================================================================
# Target: hlh-docker LXC 109 (192.168.1.9) → macvlan dedicated IP 192.168.1.14
#   Grafana  http://192.168.1.14:3000  (macvlan, dedicated IP per user request)
#   Prometheus internal http://prometheus:9090 (Grafana datasource)
# Storage: /srv/data/grafana-prometheus on host ZFS RaidZ1-6TB/hlh-docker-data (mp0)
#
# Runs in two modes:
#   1. Inside hlh-docker (recommended): run directly on LXC 109 (root@hlh-docker)
#      — uses docker directly, DATA_DIR=/srv/data/grafana-prometheus
#   2. On prox01: via pct exec 109 (requires pct)
#
# Usage (inside hlh-docker):
#   ./deploy-hlh-grafana-prometheus.sh --plan    # dry-run
#   ./deploy-hlh-grafana-prometheus.sh --apply   # deploy
#   ./deploy-hlh-grafana-prometheus.sh --nuke    # down -v + rm data + redeploy
#
# Env overrides: MONITOR_IP=192.168.1.14, PROM_RETENTION=15d, MACVLAN_* etc.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LXC_VMID="${HLH_LXC_VMID:-109}"
LXC_IP="${HLH_LXC_IP:-192.168.1.9}"
MONITOR_IP="${MONITOR_IP:-192.168.1.14}"
MACVLAN_NAME="${MACVLAN_NAME:-macvlan}"
MACVLAN_PARENT="${MACVLAN_PARENT:-eth0}"
MACVLAN_SUBNET="${MACVLAN_SUBNET:-192.168.1.0/24}"
MACVLAN_GATEWAY="${MACVLAN_GATEWAY:-192.168.1.1}"
DATA_DIR="/srv/data/grafana-prometheus"
PROM_RETENTION="${PROM_RETENTION:-15d}"

MODE="plan"
NUKE=0

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
  --apply         Deploy stack (creates macvlan, copies configs, docker compose up -d)
  --nuke          Down stack, remove volumes + data, then redeploy
  -h, --help      Show this help

Examples:
  # inside hlh-docker:
  ./deploy-hlh-grafana-prometheus.sh --plan
  ./deploy-hlh-grafana-prometheus.sh --apply

  # on prox01:
  pct push 109 deploy-hlh-grafana-prometheus.sh /root/deploy.sh && pct exec 109 -- bash /root/deploy.sh --apply

Env:
  MONITOR_IP=${MONITOR_IP}  MACVLAN_NAME=${MACVLAN_NAME}  PROM_RETENTION=${PROM_RETENTION}

Grafana:  http://${MONITOR_IP}:3000
Prometheus (internal): http://prometheus:9090
Data:     ${DATA_DIR}/prometheus_data + ${DATA_DIR}/grafana_data (ZFS bind via mp0)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) MODE="plan" ;;
    --apply) MODE="apply" ;;
    --nuke) MODE="apply"; NUKE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# --- detect execution context ---
HAS_PCT=0; IN_LXC=0
if command -v pct >/dev/null 2>&1; then HAS_PCT=1; fi
# Inside hlh-docker: hostname is hlh-docker, or pct missing but docker present and /srv/data exists
if [[ "$(hostname 2>/dev/null)" == "hlh-docker" ]]; then IN_LXC=1; fi
if [[ $HAS_PCT -eq 0 ]] && command -v docker >/dev/null 2>&1 && [[ -d "/srv/data" ]]; then IN_LXC=1; fi
# If no explicit mode and no pct, assume direct LXC execution for --apply pre-flight later

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
docker_cmd() {
  # run docker command in target context
  if [[ $HAS_PCT -eq 1 ]] && [[ $IN_LXC -eq 0 ]]; then
    pct exec "$LXC_VMID" -- bash -lc "docker $*"
  else
    docker "$@"
  fi
}
docker_compose_cmd() {
  if [[ $HAS_PCT -eq 1 ]] && [[ $IN_LXC -eq 0 ]]; then
    pct exec "$LXC_VMID" -- bash -lc "cd '${DATA_DIR}' && docker compose $*"
  else
    (cd "${DATA_DIR}" && docker compose "$@")
  fi
}

# --- plan mode (works anywhere — no pct/docker daemon required except config check) ---
if [[ "$MODE" == "plan" ]]; then
  section "Plan (what would be done)"
  for req in docker-compose.yml prometheus.yml grafana/provisioning/datasources/datasource.yml grafana/provisioning/dashboards/dashboards.yml; do
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
  info "  docker network inspect ${MACVLAN_NAME} || docker network create -d macvlan --subnet ${MACVLAN_SUBNET} --gateway ${MACVLAN_GATEWAY} -o parent=${MACVLAN_PARENT} ${MACVLAN_NAME}"
  info "Would copy into ${DATA_DIR}:"
  info "  docker-compose.yml, prometheus.yml, grafana/provisioning/*, grafana/dashboards/*, .env (if present)"
  info "Would deploy:"
  info "  cd ${DATA_DIR} && docker compose down --remove-orphans && docker compose pull && docker compose up -d"
  info "Would verify:"
  info "  docker ps --filter name=prometheus/grafana"
  info "  docker inspect grafana → IP ${MONITOR_IP} on ${MACVLAN_NAME}"
  info "  curl -sf http://${MONITOR_IP}:3000/api/health (Grafana)"
  info "  docker exec prometheus wget -qO- http://localhost:9090/-/healthy (Prometheus)"
  printf "\n"
  printf "  %-22s %s\n" "Host LXC:" "${LXC_VMID} hlh-docker ${LXC_IP}"
  printf "  %-22s %s\n" "Context:" "$([[ $IN_LXC -eq 1 ]] && echo "inside hlh-docker (direct)" || ([[ $HAS_PCT -eq 1 ]] && echo "prox01 via pct" || echo "laptop"))"
  printf "  %-22s %s\n" "Service IP (macvlan):" "${MONITOR_IP} (${MACVLAN_NAME} parent ${MACVLAN_PARENT})"
  printf "  %-22s %s\n" "Grafana:" "http://${MONITOR_IP}:3000"
  printf "  %-22s %s\n" "Prometheus:" "http://prometheus:9090 internal"
  printf "  %-22s %s\n" "Scrape targets:" "vllm 192.168.1.13:8000, llamacpp 192.168.1.12:80"
  printf "  %-22s %s\n" "Retention:" "${PROM_RETENTION}"
  printf "  %-22s %s\n" "Data (ZFS mp0):" "${DATA_DIR}"
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

for req in docker-compose.yml prometheus.yml grafana/provisioning/datasources/datasource.yml grafana/provisioning/dashboards/dashboards.yml; do
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
if [[ "$NUKE" -eq 1 ]]; then
  section "Nuke: tearing down existing stack"
  lxc_exec "cd '${DATA_DIR}' 2>/dev/null && docker compose down -v --remove-orphans 2>/dev/null || docker rm -f prometheus grafana 2>/dev/null || true"
  lxc_exec "rm -rf '${DATA_DIR}/prometheus_data' '${DATA_DIR}/grafana_data' 2>/dev/null || true"
  ok "nuke complete — data removed, will redeploy fresh"
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
  # Reuse an existing macvlan network already claiming this subnet (e.g. bench_lan).
  # Docker refuses a second macvlan on the same pool: "Pool overlaps with other
  # one on this address space". Reusing keeps Grafana on .14 without overlap.
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
      lxc_exec "ip link; docker network ls; docker network inspect bench_lan 2>&1 | head -30 || true"
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
ok "copied docker-compose.yml"

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

if compgen -G "${SCRIPT_DIR}/grafana/dashboards/*.json" >/dev/null 2>&1; then
  for f in "${SCRIPT_DIR}"/grafana/dashboards/*.json; do
    push_file "$f" "${DATA_DIR}/grafana/dashboards/$(basename "$f")"
  done
  ok "copied grafana dashboards"
else
  info "no custom dashboards to push (import via Grafana UI after deploy)"
fi

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  push_file "${SCRIPT_DIR}/.env" "${DATA_DIR}/.env"
  ok "copied .env"
else
  warn ".env not found locally — using defaults admin/admin (create .env from .env.example)"
  if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
    push_file "${SCRIPT_DIR}/.env.example" "${DATA_DIR}/.env.example"
  fi
fi

# Compose resolves the external macvlan name via ${MACVLAN_NAME:-macvlan}, so the
# target .env must pin the effective network (e.g. bench_lan when reusing).
lxc_exec "touch '${DATA_DIR}/.env' && (grep -q '^MACVLAN_NAME=' '${DATA_DIR}/.env' && sed -i 's/^MACVLAN_NAME=.*/MACVLAN_NAME=${EFFECTIVE_MACVLAN}/' '${DATA_DIR}/.env' || echo 'MACVLAN_NAME=${EFFECTIVE_MACVLAN}' >> '${DATA_DIR}/.env') && grep '^MACVLAN_NAME=' '${DATA_DIR}/.env'"
ok "pinned MACVLAN_NAME=${EFFECTIVE_MACVLAN} in target .env"

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
GRAFANA_IP="$(lxc_exec "docker inspect -f '{{with index .NetworkSettings.Networks \"${MACVLAN_NAME}\"}}{{.IPAddress}}{{end}}' grafana 2>/dev/null" | tr -d '\r' | xargs || true)"
if [[ "$GRAFANA_IP" == "$MONITOR_IP" ]]; then
  ok "grafana IP ${GRAFANA_IP} == ${MONITOR_IP}"
else
  warn "grafana IP '${GRAFANA_IP}' expected '${MONITOR_IP}' — check parent/IP conflict"
  lxc_exec "docker inspect grafana | grep -A2 IPAddress || true"
fi

info "Networks:"
lxc_exec "docker network inspect ${MACVLAN_NAME} 2>&1 | head -40 || true"

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

info "Prometheus targets:"
lxc_exec "docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null | head -c 2000 || echo 'targets not yet ready'"

info "Grafana health (macvlan)..."
for i in 1 2 3 4 5 6; do
  if lxc_exec "curl -sf http://${MONITOR_IP}:3000/api/health 2>/dev/null | grep -q ok || curl -sf http://localhost:3000/api/health 2>/dev/null | grep -q ok || wget -qO- http://${MONITOR_IP}:3000/api/health 2>/dev/null | grep -q ok"; then
    ok "Grafana healthy at http://${MONITOR_IP}:3000"
    break
  fi
  sleep 3
  if [[ $i -eq 6 ]]; then
    warn "Grafana health check failed after 18s"
    lxc_exec "docker logs grafana 2>&1 | tail -30 || true"
    lxc_exec "curl -v http://${MONITOR_IP}:3000/api/health 2>&1 | head -20 || curl -v http://localhost:3000/api/health 2>&1 | head -20 || true"
  fi
done

lxc_exec "docker exec grafana wget -qO- http://prometheus:9090/-/healthy 2>/dev/null | head -5 && echo 'grafana->prometheus ok' || echo 'grafana->prometheus pending'"

info "Data volumes:"
lxc_exec "ls -lh '${DATA_DIR}/prometheus_data' 2>&1 | head -5; ls -lh '${DATA_DIR}/grafana_data' 2>&1 | head -5; df -h '${DATA_DIR}' 2>&1 | tail -5"

# --- summary ---
section "Deploy summary"
printf "  %-22s %s\n" "Host LXC:" "${LXC_VMID} hlh-docker ${LXC_IP}"
printf "  %-22s %s\n" "Context:" "$([[ $IN_LXC -eq 1 ]] && echo "inside hlh-docker (direct)" || echo "prox01 via pct")"
printf "  %-22s %s\n" "Service IP (macvlan):" "${MONITOR_IP} (${MACVLAN_NAME} parent ${MACVLAN_PARENT})"
printf "  %-22s %s\n" "Grafana:" "http://${MONITOR_IP}:3000 (admin via .env or admin/admin)"
printf "  %-22s %s\n" "Prometheus:" "http://prometheus:9090 internal"
printf "  %-22s %s\n" "Data (ZFS mp0):" "${DATA_DIR}"
printf "  %-22s %s\n" "Scrape:" "vllm 192.168.1.13:8000, llamacpp 192.168.1.12:80 (15s)"
printf "  %-22s %s\n" "Retention:" "${PROM_RETENTION}"
echo ""
ok "Deploy complete — Grafana at http://${MONITOR_IP}:3000"
info "Next: open Grafana, datasource http://prometheus:9090 already provisioned, import dashboards"
if [[ $IN_LXC -eq 1 ]]; then
  info "Logs: docker logs -f grafana / prometheus"
  info "Down: cd ${DATA_DIR} && docker compose down"
else
  info "Logs: pct exec ${LXC_VMID} -- docker logs -f grafana / prometheus"
  info "Down: pct exec ${LXC_VMID} -- bash -lc 'cd ${DATA_DIR} && docker compose down'"
fi
