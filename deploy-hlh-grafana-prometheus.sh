#!/usr/bin/env bash
# ============================================================================
# hlh-grafana-prometheus-ct — Deploy Prometheus + Grafana to hlh-docker LXC 111
# ============================================================================
# Target: hlh-docker LXC 111 (192.168.1.11) → macvlan dedicated IP 192.168.1.14
#   Grafana  http://192.168.1.14:3000  (macvlan, dedicated IP per user request)
#   Prometheus internal http://prometheus:9090 (Grafana datasource), optional external via macvlan
# Storage: /srv/data/grafana-prometheus on host ZFS RaidZ1-6TB/hlh-docker-data (mp0)
# Pattern: pure-bash, pct exec — mirrors hlh-docker/deploy-hlh-docker.sh:1
#
# Usage:
#   ./deploy-hlh-grafana-prometheus.sh --plan    # dry-run, no changes (Stage 0)
#   ./deploy-hlh-grafana-prometheus.sh --apply   # deploy stack into running LXC 111 (Stage 1)
#   ./deploy-hlh-grafana-prometheus.sh --nuke    # down -v + rm data + redeploy
#   ./deploy-hlh-grafana-prometheus.sh --help
#
# Env overrides:
#   HLH_LXC_VMID=111 HLH_LXC_IP=192.168.1.11 MONITOR_IP=192.168.1.14
#   MACVLAN_NAME=macvlan MACVLAN_PARENT=eth0 MACVLAN_SUBNET=192.168.1.0/24 MACVLAN_GATEWAY=192.168.1.1
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LXC_VMID="${HLH_LXC_VMID:-111}"
LXC_IP="${HLH_LXC_IP:-192.168.1.11}"
MONITOR_IP="${MONITOR_IP:-192.168.1.14}"
MACVLAN_NAME="${MACVLAN_NAME:-macvlan}"
MACVLAN_PARENT="${MACVLAN_PARENT:-eth0}"
MACVLAN_SUBNET="${MACVLAN_SUBNET:-192.168.1.0/24}"
MACVLAN_GATEWAY="${MACVLAN_GATEWAY:-192.168.1.1}"
DATA_DIR="/srv/data/grafana-prometheus"
PROM_RETENTION="${PROM_RETENTION:-15d}"

MODE="plan"
NUKE=0

# --- colour helpers (safe when not tty) — mirrors hlh-docker/deploy-hlh-docker.sh:69 ---
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

Options:
  --plan          Dry-run: show what would be deployed (default)
  --apply         Deploy stack into LXC ${LXC_VMID} via pct exec
  --nuke          Down stack, remove volumes + data, then redeploy
  -h, --help      Show this help

Env:
  HLH_LXC_VMID=${LXC_VMID}  HLH_LXC_IP=${LXC_IP}  MONITOR_IP=${MONITOR_IP}
  MACVLAN_NAME=${MACVLAN_NAME}  MACVLAN_PARENT=${MACVLAN_PARENT}
  MACVLAN_SUBNET=${MACVLAN_SUBNET}  MACVLAN_GATEWAY=${MACVLAN_GATEWAY}
  PROM_RETENTION=${PROM_RETENTION}  GF_SECURITY_ADMIN_USER/PASSWORD via .env

Compose:  prometheus prom/prometheus:v3.5.0 + grafana grafana/grafana:11.5.2
Grafana:  http://${MONITOR_IP}:3000
Prometheus (internal): http://prometheus:9090 (external optional)
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

# --- helpers ---
pct_ok() { pct "$@" >/dev/null 2>&1; }
lxc_exists() { pct_ok status "$LXC_VMID"; }
lxc_running() { [[ "$(pct status "$LXC_VMID" 2>/dev/null)" == *"running"* ]]; }
lxc_exec() { pct exec "$LXC_VMID" -- bash -lc "$1"; }

# pct push wrapper with fallback to base64 via pct exec
push_file() {
  local src="$1" dst="$2"
  if pct push "$LXC_VMID" "$src" "$dst" --perms 0644 >/dev/null 2>&1; then
    return 0
  fi
  # fallback: base64 encode and decode inside LXC (handles binary + special chars)
  if command -v base64 >/dev/null 2>&1; then
    base64 -w0 "$src" | pct exec "$LXC_VMID" -- bash -lc "base64 -d > '$dst' && chmod 0644 '$dst'"
    return $?
  fi
  # last resort: cat
  cat "$src" | pct exec "$LXC_VMID" -- bash -lc "cat > '$dst' && chmod 0644 '$dst'"
}

push_dir() {
  local src_dir="$1" dst_dir="$2"
  lxc_exec "mkdir -p '$dst_dir'"
  for f in "$src_dir"/*; do
    [[ -f "$f" ]] || continue
    push_file "$f" "$dst_dir/$(basename "$f")"
  done
}

# --- plan mode (laptop-friendly, no pct required) ---
if [[ "$MODE" == "plan" ]]; then
  section "Plan (what would be done)"
  for req in docker-compose.yml prometheus.yml grafana/provisioning/datasources/datasource.yml grafana/provisioning/dashboards/dashboards.yml; do
    if [[ ! -f "${SCRIPT_DIR}/${req}" ]]; then fail "Missing ${req} in ${SCRIPT_DIR}" >&2; exit 1; fi
  done
  if docker compose -f "${SCRIPT_DIR}/docker-compose.yml" config >/dev/null 2>&1; then
    ok "docker-compose.yml valid (local config check)"
  else
    fail "docker-compose.yml invalid — run: docker compose config" >&2; exit 1
  fi
  if command -v promtool >/dev/null 2>&1; then
    promtool check config "${SCRIPT_DIR}/prometheus.yml" >/dev/null && ok "prometheus.yml valid (local promtool)" || { fail "prometheus.yml invalid"; exit 1; }
  else
    info "promtool not installed locally — syntax not checked (will validate inside LXC if available)"
  fi
  info "Would ensure data dirs via pct exec ${LXC_VMID}:"
  info "  ${DATA_DIR}/prometheus_data (0755)"
  info "  ${DATA_DIR}/grafana_data (0755, chown 472:472 for grafana UID)"
  info "Would ensure macvlan network inside LXC:"
  info "  docker network inspect ${MACVLAN_NAME} || docker network create -d macvlan --subnet ${MACVLAN_SUBNET} --gateway ${MACVLAN_GATEWAY} -o parent=${MACVLAN_PARENT} ${MACVLAN_NAME}"
  info "Would push into LXC ${LXC_VMID}:${DATA_DIR}:"
  info "  docker-compose.yml, prometheus.yml, grafana/provisioning/*, grafana/dashboards/*, .env (if present)"
  info "Would deploy inside LXC:"
  info "  cd ${DATA_DIR} && docker compose down --remove-orphans && docker compose pull && docker compose up -d"
  info "Would verify:"
  info "  docker ps --filter name=prometheus/grafana"
  info "  docker inspect -f '{{.NetworkSettings.Networks.${MACVLAN_NAME}.IPAddress}}' grafana == ${MONITOR_IP}"
  info "  curl -sf http://${MONITOR_IP}:3000/api/health (Grafana)"
  info "  docker exec prometheus wget -qO- http://localhost:9090/-/healthy (Prometheus)"
  info "  docker logs prometheus | grep 'Server is ready to receive web requests'"
  printf "\n"
  printf "  %-22s %s\n" "Host LXC:" "${LXC_VMID} hlh-docker ${LXC_IP}"
  printf "  %-22s %s\n" "Service IP (macvlan):" "${MONITOR_IP} (${MACVLAN_NAME} parent ${MACVLAN_PARENT})"
  printf "  %-22s %s\n" "Grafana:" "http://${MONITOR_IP}:3000"
  printf "  %-22s %s\n" "Prometheus:" "http://prometheus:9090 internal (add macvlan .15 to expose)"
  printf "  %-22s %s\n" "Scrape targets:" "vllm 192.168.1.13:8000, llamacpp 192.168.1.12:80"
  printf "  %-22s %s\n" "Retention:" "${PROM_RETENTION}"
  printf "  %-22s %s\n" "Data (ZFS mp0):" "${DATA_DIR}"
  if command -v pct >/dev/null 2>&1; then
    info "pct found — on prox01, pre-flight will run with --apply"
  else
    info "pct not found (laptop) — pre-flight will run on prox01 with --apply"
  fi
  info "Plan complete — no changes made. Run --apply on prox01 to deploy."
  exit 0
fi

# --- pre-flight (requires prox01) ---
section "Pre-flight checks"

if ! command -v pct >/dev/null 2>&1; then
  fail "pct not found. Run on prox01 (Proxmox host)." >&2
  exit 1
fi
ok "pct found"

if ! lxc_exists; then
  fail "LXC ${LXC_VMID} does not exist. Deploy hlh-docker first: ~/git/hlh-docker/deploy-hlh-docker.sh --apply" >&2
  exit 1
fi
ok "LXC ${LXC_VMID} exists"

if ! lxc_running; then
  fail "LXC ${LXC_VMID} not running. pct start ${LXC_VMID}" >&2
  exit 1
fi
ok "LXC ${LXC_VMID} running"

if ! lxc_exec "command -v docker >/dev/null 2>&1"; then
  fail "docker not found inside LXC ${LXC_VMID}. Ensure hlh-docker deployed Docker Engine." >&2
  exit 1
fi
ok "docker found inside LXC"

# Verify compose files exist locally
for req in docker-compose.yml prometheus.yml grafana/provisioning/datasources/datasource.yml grafana/provisioning/dashboards/dashboards.yml; do
  if [[ ! -f "${SCRIPT_DIR}/${req}" ]]; then
    fail "Missing ${req} in ${SCRIPT_DIR}" >&2; exit 1
  fi
done
ok "local compose + configs present"

# Validate prometheus.yml syntax if promtool available locally or inside LXC
if command -v promtool >/dev/null 2>&1; then
  promtool check config "${SCRIPT_DIR}/prometheus.yml" >/dev/null && ok "prometheus.yml valid (local promtool)" || { fail "prometheus.yml invalid"; exit 1; }
else
  info "promtool not installed locally — will validate inside LXC if available"
fi

if ! docker compose version >/dev/null 2>&1 && ! lxc_exec "docker compose version >/dev/null 2>&1"; then
  warn "docker compose plugin not found inside LXC — may fail"
else
  ok "docker compose plugin available"
fi

# Docker compose config check locally (does not require daemon)
if docker compose -f "${SCRIPT_DIR}/docker-compose.yml" config >/dev/null 2>&1; then
  ok "docker-compose.yml valid (local config check)"
else
  fail "docker-compose.yml invalid — run: docker compose config" >&2; exit 1
fi


# --- nuke mode ---
if [[ "$NUKE" -eq 1 ]]; then
  section "Nuke: tearing down existing stack in LXC ${LXC_VMID}"
  lxc_exec "cd '${DATA_DIR}' 2>/dev/null && docker compose down -v --remove-orphans 2>/dev/null || docker rm -f prometheus grafana 2>/dev/null || true"
  lxc_exec "rm -rf '${DATA_DIR}/prometheus_data' '${DATA_DIR}/grafana_data' 2>/dev/null || true"
  ok "nuke complete — data removed, will redeploy fresh"
fi

# --- ensure data dirs ---
section "Data directories in LXC ${LXC_VMID}"
lxc_exec "mkdir -p '${DATA_DIR}/prometheus_data' '${DATA_DIR}/grafana_data' '${DATA_DIR}/grafana/provisioning/datasources' '${DATA_DIR}/grafana/provisioning/dashboards' '${DATA_DIR}/grafana/dashboards'"
lxc_exec "chmod 0755 '${DATA_DIR}' '${DATA_DIR}/prometheus_data' '${DATA_DIR}/grafana_data' 2>/dev/null || true"
# Grafana runs as UID 472
lxc_exec "chown -R 472:472 '${DATA_DIR}/grafana_data' 2>/dev/null || chown -R 472 '${DATA_DIR}/grafana_data' 2>/dev/null || true"
ok "data dirs ready: ${DATA_DIR}/prometheus_data + grafana_data (472:472)"

# --- ensure macvlan network inside LXC ---
section "Macvlan network inside LXC ${LXC_VMID}"
if lxc_exec "docker network inspect '${MACVLAN_NAME}' >/dev/null 2>&1"; then
  ok "macvlan network ${MACVLAN_NAME} already exists"
  # Verify subnet/parent if needed (non-fatal)
  lxc_exec "docker network inspect '${MACVLAN_NAME}' | grep -q '${MACVLAN_SUBNET}' && echo 'subnet ok' || echo 'subnet differs (manual check)'"
else
  info "Creating macvlan network ${MACVLAN_NAME} parent=${MACVLAN_PARENT} subnet=${MACVLAN_SUBNET} gw=${MACVLAN_GATEWAY}"
  if lxc_exec "docker network create -d macvlan --subnet '${MACVLAN_SUBNET}' --gateway '${MACVLAN_GATEWAY}' -o parent='${MACVLAN_PARENT}' '${MACVLAN_NAME}' >/dev/null"; then
    ok "macvlan network created"
  else
    fail "Failed to create macvlan network ${MACVLAN_NAME} inside LXC ${LXC_VMID}" >&2
    fail "Check parent interface inside LXC: pct exec ${LXC_VMID} -- ip link" >&2
    exit 1
  fi
fi

# Check if MONITOR_IP already in use on macvlan (arping/ping check inside LXC)
if lxc_exec "getent hosts ${MONITOR_IP} >/dev/null 2>&1 || ping -c1 -W2 ${MONITOR_IP} >/dev/null 2>&1"; then
  # Non-fatal — might be self after prior deploy
  warn "IP ${MONITOR_IP} appears responsive — will verify after deploy it belongs to grafana container"
else
  ok "IP ${MONITOR_IP} appears free (pre-deploy ping failed as expected)"
fi

# --- push compose + configs ---
section "Pushing stack files into LXC ${LXC_VMID}:${DATA_DIR}"

push_file "${SCRIPT_DIR}/docker-compose.yml" "${DATA_DIR}/docker-compose.yml"
ok "pushed docker-compose.yml"

# Inject retention override if PROM_RETENTION != 15d — patch command in compose inside LXC
if [[ "$PROM_RETENTION" != "15d" ]]; then
  info "Overriding Prometheus retention to ${PROM_RETENTION}"
  lxc_exec "sed -i 's/--storage.tsdb.retention.time=15d/--storage.tsdb.retention.time=${PROM_RETENTION}/' '${DATA_DIR}/docker-compose.yml'"
fi

push_file "${SCRIPT_DIR}/prometheus.yml" "${DATA_DIR}/prometheus.yml"
ok "pushed prometheus.yml"

lxc_exec "mkdir -p '${DATA_DIR}/grafana/provisioning/datasources' '${DATA_DIR}/grafana/provisioning/dashboards' '${DATA_DIR}/grafana/dashboards'"
push_file "${SCRIPT_DIR}/grafana/provisioning/datasources/datasource.yml" "${DATA_DIR}/grafana/provisioning/datasources/datasource.yml"
push_file "${SCRIPT_DIR}/grafana/provisioning/dashboards/dashboards.yml" "${DATA_DIR}/grafana/provisioning/dashboards/dashboards.yml"
ok "pushed grafana provisioning"

# Push dashboards if any
if compgen -G "${SCRIPT_DIR}/grafana/dashboards/*.json" >/dev/null 2>&1; then
  for f in "${SCRIPT_DIR}"/grafana/dashboards/*.json; do
    push_file "$f" "${DATA_DIR}/grafana/dashboards/$(basename "$f")"
  done
  ok "pushed grafana dashboards"
else
  info "no custom dashboards to push (import via Grafana UI after deploy)"
fi

# Push .env if present (contains Grafana admin password — never commit)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  push_file "${SCRIPT_DIR}/.env" "${DATA_DIR}/.env"
  ok "pushed .env (Grafana admin creds)"
else
  warn ".env not found locally — using defaults admin/admin (create .env from .env.example to override)"
  if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
    push_file "${SCRIPT_DIR}/.env.example" "${DATA_DIR}/.env.example"
  fi
fi

# Validate prometheus.yml inside LXC if promtool exists there
if lxc_exec "command -v promtool >/dev/null 2>&1"; then
  if lxc_exec "promtool check config '${DATA_DIR}/prometheus.yml' >/dev/null 2>&1"; then
    ok "prometheus.yml valid inside LXC (promtool)"
  else
    fail "prometheus.yml invalid inside LXC — check syntax" >&2
    lxc_exec "promtool check config '${DATA_DIR}/prometheus.yml' || true"
    exit 1
  fi
fi

# Validate compose inside LXC
if lxc_exec "cd '${DATA_DIR}' && docker compose config >/dev/null 2>&1"; then
  ok "docker compose config valid inside LXC"
else
  fail "docker compose config invalid inside LXC" >&2
  lxc_exec "cd '${DATA_DIR}' && docker compose config || true"
  exit 1
fi

# --- deploy ---
section "Deploying stack in LXC ${LXC_VMID}"
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

# Wait for containers to be running
info "Waiting for containers to be running..."
for i in 1 2 3 4 5 6; do
  if lxc_exec "docker ps --filter name=prometheus --filter name=grafana --format '{{.Names}}' | grep -q prometheus && docker ps --format '{{.Names}}' | grep -q grafana"; then
    ok "prometheus + grafana containers running (attempt $i)"
    break
  fi
  sleep 3
  if [[ $i -eq 6 ]]; then
    fail "Containers not running after 18s" >&2
    lxc_exec "docker ps -a; docker compose -f '${DATA_DIR}/docker-compose.yml' ps; docker logs prometheus 2>&1 | tail -30; docker logs grafana 2>&1 | tail -30"
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
  ok "grafana IP ${GRAFANA_IP} matches expected ${MONITOR_IP}"
else
  warn "grafana IP is '${GRAFANA_IP}' expected '${MONITOR_IP}' — check macvlan parent or IP conflict"
  lxc_exec "docker inspect grafana | grep -A2 IPAddress || true"
fi

info "Networks:"
lxc_exec "docker network inspect ${MACVLAN_NAME} 2>&1 | head -40 || true"

# Health checks with retries
info "Prometheus health (inside prometheus container)..."
for i in 1 2 3 4 5; do
  if lxc_exec "docker exec prometheus wget -qO- http://localhost:9090/-/healthy 2>/dev/null | grep -q 'Prometheus Server is Healthy' || docker exec prometheus wget -qO- http://localhost:9090/-/healthy 2>/dev/null | grep -q Healthy || curl -sf http://localhost:9090/-/healthy 2>/dev/null | grep -q Healthy"; then
    ok "Prometheus healthy"
    break
  fi
  # fallback: check via localhost on host network
  if lxc_exec "curl -sf http://localhost:9090/-/healthy 2>/dev/null | head -5 | grep -q -i healthy || wget -qO- http://127.0.0.1:9090/-/healthy 2>&1 | grep -q -i healthy"; then
    ok "Prometheus healthy (via localhost)"
    break
  fi
  sleep 3
  if [[ $i -eq 5 ]]; then
    warn "Prometheus health check failed after 15s — checking logs"
    lxc_exec "docker logs prometheus 2>&1 | tail -20 || true"
  fi
done
# Directly check prometheus targets via internal network from grafana
info "Prometheus targets (via prometheus API):"
lxc_exec "docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null | head -c 2000 || curl -sf http://localhost:9090/api/v1/targets 2>/dev/null | head -c 2000 || echo 'targets not yet ready'"

info "Grafana health (macvlan IP)..."
for i in 1 2 3 4 5 6; do
  if lxc_exec "curl -sf http://${MONITOR_IP}:3000/api/health 2>/dev/null | grep -q ok || curl -sf http://localhost:3000/api/health 2>/dev/null | grep -q ok || wget -qO- http://${MONITOR_IP}:3000/api/health 2>/dev/null | grep -q ok"; then
    ok "Grafana healthy at http://${MONITOR_IP}:3000"
    break
  fi
  sleep 3
  if [[ $i -eq 6 ]]; then
    warn "Grafana health check failed after 18s — checking logs"
    lxc_exec "docker logs grafana 2>&1 | tail -30 || true"
    lxc_exec "curl -v http://${MONITOR_IP}:3000/api/health 2>&1 | head -20 || curl -v http://localhost:3000/api/health 2>&1 | head -20 || true"
  fi
done

lxc_exec "docker exec grafana wget -qO- http://prometheus:9090/-/healthy 2>/dev/null | head -5 && echo 'grafana->prometheus connectivity ok' || echo 'grafana->prometheus check pending'"

info "Data volumes:"
lxc_exec "ls -lh '${DATA_DIR}/prometheus_data' 2>&1 | head -5; ls -lh '${DATA_DIR}/grafana_data' 2>&1 | head -5; df -h '${DATA_DIR}' 2>&1 | tail -5"

# --- summary ---
section "Deploy summary"
printf "  %-22s %s\n" "Host LXC:" "${LXC_VMID} hlh-docker ${LXC_IP}"
printf "  %-22s %s\n" "Service IP (macvlan):" "${MONITOR_IP} (${MACVLAN_NAME} parent ${MACVLAN_PARENT} subnet ${MACVLAN_SUBNET})"
printf "  %-22s %s\n" "Grafana:" "http://${MONITOR_IP}:3000 (admin via .env or admin/admin)"
printf "  %-22s %s\n" "Prometheus:" "http://prometheus:9090 internal; external via http://${MONITOR_IP}:9090 if exposed"
printf "  %-22s %s\n" "Data (ZFS mp0):" "${DATA_DIR} (RaidZ1-6TB/hlh-docker-data)"
printf "  %-22s %s\n" "Scrape:" "vllm 192.168.1.13:8000, llamacpp 192.168.1.12:80 (15s, labels engine=*)"
printf "  %-22s %s\n" "Retention:" "${PROM_RETENTION}"
echo ""
ok "Deploy complete — Grafana at http://${MONITOR_IP}:3000"
info "Next: open Grafana, add Prometheus datasource test (http://prometheus:9090), import vLLM + llama.cpp dashboards"
info "Logs: pct exec ${LXC_VMID} -- docker logs -f grafana / prometheus"
info "Down: pct exec ${LXC_VMID} -- bash -lc 'cd ${DATA_DIR} && docker compose down'"
