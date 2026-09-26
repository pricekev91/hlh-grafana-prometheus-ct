# PLAN — Stage 1: hlh-grafana-prometheus-ct → hlh-docker (192.168.1.9)

**Date:** 2026-09-21 (Stage 1 built, gated for deploy on prox01)
**Host:** `hlh-docker` LXC 111 `192.168.1.9/24` on `prox01` (`hlh-docker/deploy-hlh-docker.sh:44`)
**Service IP (macvlan, dedicated):** `192.168.1.14` — Grafana `http://192.168.1.14:3000` (user request)
**Constraint:** Ignore other CTs, pure macvlan dedicated IP, no host-bridge port remapping.
**Status:** Stage 0 plan + Stage 1 build complete. `--plan` validates on laptop, `--apply` runs on prox01 via `pct exec 111`.

## 1. Host Inventory (verified)

* `hlh-docker` pure-bash, no Terraform/Ansible `hlh-docker/README.md:2`. Provisions unprivileged LXC 111 `hlh-docker/deploy-hlh-docker.sh:317` with `nesting=1,keyctl=1`, `4c/4096MB/32GB` on `RaidZ1-6TB` `hlh-docker/deploy-hlh-docker.sh:322`.
* Single ZFS dataset `RaidZ1-6TB/hlh-docker-data` (30G) `hlh-docker/deploy-hlh-docker.sh:281` → `mount -t zfs ... /srv/data` `hlh-docker/deploy-hlh-docker.sh:293` and `mp0:/srv/data,mp=/srv/data` `hlh-docker/deploy-hlh-docker.sh:429`. Subdirs `/srv/data/docker` (`daemon.json: data-root` `hlh-docker/deploy-hlh-docker.sh:565`) + `/srv/data/dockhand` `hlh-docker/deploy-hlh-docker.sh:460`.
* Dockhand `fnsys/dockhand:latest` on `80:3000` `hlh-docker/deploy-hlh-docker.sh:590` stays on `192.168.1.9` only. Macvlan `.14` has **zero conflict** — Grafana keeps native `3000` on its own IP.
* `hlh-grafana-prometheus-ct` now has Stage 1 artifacts (compose, prometheus.yml, provisioning, deploy script). `readme.md:1` describes vLLM (`/metrics`) + llama.cpp (`--metrics`) → Prometheus → Grafana `readme.md:22`.

## 2. Target Architecture

```
 Engine LXC 112 (llama.cpp 192.168.1.12:80 /metrics)
 Engine LXC 113 (vLLM       192.168.1.13:8000 /metrics)
                         │
                         ▼
          hlh-docker LXC 111 (192.168.1.9) ── macvlan ──► 192.168.1.14
                            /srv/data (mp0)
                              └─ /srv/data/grafana-prometheus/{prometheus_data,grafana_data}
                                   internal bridge: prometheus (9090) ──► grafana (3000 macvlan)
```

* **Network:** Docker macvlan `macvlan` parent `eth0` `192.168.1.0/24` gw `192.168.1.1`. **Grafana only** gets `192.168.1.14` on macvlan; **Prometheus is internal `bridge`** `docker-compose.yml:22` reachable at `http://prometheus:9090` from Grafana via `internal` network. This avoids macvlan IP conflict (two containers cannot share `.14`). Prometheus UI is internal; expose externally later via `.15` macvlan IP or `network_mode: service:grafana` if needed. Fix applied Stage 1 `docker-compose.yml:1`.
* **Storage:** No new ZFS dataset. Reuse `hlh-docker-data` at `/srv/data/grafana-prometheus`. Two bind volumes `docker-compose.yml:48` via `driver_opts: type none, device: /srv/data/...` — survives `pct destroy 111` per `ADR-001.md:36`.
* **Images (pinned):** `prom/prometheus:v3.5.0`, `grafana/grafana:11.5.2`. Retention `15d` default (`--storage.tsdb.retention.time=15d` `docker-compose.yml:15`), override `PROM_RETENTION=30d`.
* **Scrape:** `prometheus.yml:15` interval `15s`, jobs `vllm` → `192.168.1.13:8000`, `llamacpp` → `192.168.1.12:80`, label `engine`.
* **Grafana:** Provisioned datasource `http://prometheus:9090` `grafana/provisioning/datasources/datasource.yml:5`, dashboards at `/var/lib/grafana/dashboards` `grafana/provisioning/dashboards/dashboards.yml:12`, admin via `.env` (`GF_SECURITY_ADMIN_USER/PASSWORD`).

## 3. Runtime Contract

| Item | Value |
|------|-------|
| Service IP (macvlan) | `192.168.1.14/24` gw `192.168.1.1` parent `eth0` |
| Grafana | `http://192.168.1.14:3000` + `/api/health` (admin/admin default, change via `.env`) |
| Prometheus | `http://prometheus:9090` internal (Grafana datasource); external optional |
| Prometheus API (internal) | `docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets` should show 2 UP |
| hlh-docker host | `http://192.168.1.9:80` Dockhand untouched |
| Data on host | `/srv/data/grafana-prometheus/prometheus_data` + `/grafana_data` (ZFS, `472:472` for grafana) |
| Data in containers | `/prometheus` + `/var/lib/grafana` |

## 4. Stage 1 Artifacts (this directory)

* `PLAN.md` (this file)
* `docker-compose.yml` — Stage 1, grafana `.14` macvlan + prometheus internal, pinned images, `472:472` volume handling
* `prometheus.yml` — 2 scrape jobs, `15s`
* `grafana/provisioning/datasources/datasource.yml` + `grafana/provisioning/dashboards/dashboards.yml`
* `grafana/dashboards/` — empty, import via Grafana UI after deploy
* `.env.example` — `GF_SECURITY_ADMIN_*`, `MONITOR_IP=192.168.1.14`, `PROM_RETENTION`, `VLLM_TARGET`, `LLAMACPP_TARGET`
* `.gitignore` — ignores `.env`, data dirs
* `deploy-hlh-grafana-prometheus.sh` — pure-bash `pct exec 111`, `--plan` (laptop-friendly) / `--apply` / `--nuke` / `--help`, colour helpers like `hlh-docker/deploy-hlh-docker.sh:69`, `pct push` with base64 fallback, macvlan create guard, `chown 472:472`, health checks

## 5. Execution Flow

1. **Pre-flight on prox01:** `pct status 111` running, `docker --version`, `docker network inspect macvlan` or create `docker network create -d macvlan --subnet 192.168.1.0/24 --gateway 192.168.1.1 -o parent=eth0 macvlan`, `docker compose config` validate.
2. **Plan (laptop or prox01):** `./deploy-hlh-grafana-prometheus.sh --plan` — validates compose locally, prints plan, no `pct` required.
3. **Apply (on prox01):** `mkdir -p /srv/data/grafana-prometheus/{prometheus_data,grafana_data}` via `pct exec 111`, `chown 472:472`, `pct push` compose+configs, `docker compose pull && down --remove-orphans && up -d`.
4. **Verify (inside script):** `docker ps`, `docker inspect grafana` IP == `192.168.1.14`, `docker exec prometheus wget -qO- http://localhost:9090/-/healthy`, `curl -sf http://192.168.1.14:3000/api/health`, `grafana->prometheus` connectivity, `ls -lh /srv/data/...`.
5. **Nuke (optional):** `./deploy-hlh-grafana-prometheus.sh --nuke` — `down -v` + `rm -rf prometheus_data grafana_data` + redeploy.
6. **Persistence gate:** `pct stop/start 111` → volumes retained on `RaidZ1-6TB/hlh-docker-data`.

## 6. Decisions Locked

* Ignore other CTs — standalone `hlh-grafana-prometheus-ct` repo.
* macvlan dedicated IP **192.168.1.14** for Grafana (Prometheus internal to avoid IP clash; expose later if needed).
* No changes to `hlh-docker` LXC definition — service deploys into running `111` (preserves `hlh-docker/README.md:18` boundary).

## 7. Next Steps on prox01

```bash
cd ~/git/hlh-grafana-prometheus-ct
cp .env.example .env   # set GF_SECURITY_ADMIN_PASSWORD
./deploy-hlh-grafana-prometheus.sh --plan
./deploy-hlh-grafana-prometheus.sh --apply
# verify
curl -sf http://192.168.1.14:3000/api/health
pct exec 111 -- docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets | head -c 2000
# open Grafana http://192.168.1.14:3000 → datasource Prometheus http://prometheus:9090 → import dashboards
```

Open items: Grafana admin password via `.env`, llama.cpp `--metrics` on `112` (may need `hlh-ai-engine` patch), retention `15d` vs `30d`, dashboards import.

## 8. Verification of Stage 1 Build

* `bash -n deploy-hlh-grafana-prometheus.sh` OK, `docker compose config` OK, `--plan` passes on laptop (pct not required), `--apply` gates on pct/has `111` checks `deploy-hlh-grafana-prometheus.sh:116`.
