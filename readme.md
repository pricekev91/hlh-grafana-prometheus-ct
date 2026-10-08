# LLM Inference Monitoring Stack

Unified Prometheus + Grafana monitoring for **vLLM** and **llama.cpp** in a single instance.

Track the metrics that matter for local / homelab LLM serving — throughput, latency, KV cache pressure, speculative decoding (MTP) success, and historical token usage — with a clean web dashboard.

## Features

- **Single stack for both engines** — one Prometheus, one Grafana
- **Core metrics**
  - Prompt & generation tokens/sec
  - Prompt processing / prefill performance
  - Total token usage (24 h, 7 d, and longer windows)
  - KV cache utilization
  - MTP / speculative decoding acceptance rate
  - Request queue depth, TTFT, TPOT, and success rates
- Ready-to-import Grafana dashboards (or easy to customize)
- Lightweight and homelab-friendly (Docker Compose)

## Architecture

```
vLLM  ──/metrics──┐
                  ├──► Prometheus ──► Grafana (dashboards)
llama.cpp ─/metrics─┘
```

Both engines expose native Prometheus metrics. Prometheus scrapes them on a short interval and stores the time series. Grafana queries Prometheus and renders the visuals.

## Prerequisites

- Docker + Docker Compose
- Running vLLM OpenAI-compatible server (metrics enabled by default)
- Running llama.cpp `llama-server` started with `--metrics`
- Network access from the monitoring host to both `/metrics` endpoints

## Quick Start

1. Clone this repo and enter the directory.
2. Edit `prometheus.yml` (or the compose override) and set the scrape targets for your vLLM and llama.cpp instances.
3. Start the stack:

   ```bash
   docker compose up -d
   ```

4. Open Grafana:
   - `http://192.168.1.14` (a.k.a. `http://grafana.mizertech.net`) — macvlan
     dedicated IP, the canonical URL on the LAN (port 80, no suffix).
   - `http://192.168.1.9:3000` — nginx `grafana-proxy` sidecar; use this from
     the VPN or inside the LXC, where the `.14` macvlan is unreachable
     (macvlan-on-veth can't hairpin ARP; the VPN endpoint drops `.14`).
   Default credentials `admin` / `admin`; set `GF_SECURITY_ADMIN_PASSWORD` in
   `.env` for a fresh deploy.
5. Dashboards are auto-provisioned from `grafana/dashboards/` (llama.cpp + unified;
   the vLLM dashboards were removed 2026-10-08 when the vLLM engine was retired).

Prometheus UI will be available at `http://192.168.1.9:9090` (internal:
`http://prometheus:9090`, the provisioned Grafana datasource).

> Note (2026-10-08): the dedicated macvlan IP (192.168.1.14) is the canonical
> LAN URL (grafana.mizertech.net) but is unreachable from inside the LXC
> (macvlan-on-veth can't hairpin ARP) and from the VPN endpoint (192.168.2.1
> drops it while .9 works) — hence the bridge-side proxy on .9:3000 as the
> VPN/inside-LXC path. The deploy script verifies both paths (macvlan from the
> LAN side in pct mode, proxy from both sides) and fails if any scrape target
> is down.

## Configuration Notes

- **Scrape targets** — Give each engine a distinct `job` name (or custom label such as `engine="vllm"` / `engine="llamacpp"`) so you can filter panels cleanly.
- **Retention** — Set Prometheus retention high enough for your desired history (e.g. 15–30 days). Token totals over 24 h / 1 week are then simple `increase()` queries.
- **Optional extras** — Node Exporter and NVIDIA DCGM exporter can be added for host + GPU hardware metrics alongside the inference metrics.

## Metrics Overview

| Category              | vLLM                              | llama.cpp                          |
|-----------------------|-----------------------------------|------------------------------------|
| Throughput (tok/s)    | Prompt + generation rates         | Prompt + predicted rates           |
| Token totals          | Counters → any time window        | Counters → any time window         |
| KV cache              | Usage %, blocks                   | Usage / slot status                |
| Speculative / MTP     | Acceptance rate, draft stats      | Acceptance rate (recent builds)    |
| Latency               | TTFT, TPOT, E2E histograms        | Derived from timing counters       |
| Requests              | Running / waiting / success       | Processing / deferred              |

Exact metric names differ slightly between the two engines; the dashboards (or a unified custom dashboard) normalize the view.

## Dashboards

The llama.cpp dashboards are generated, not hand-edited:

- `grafana/dashboards/generate_dashboards.py` — single source of truth for the
  `hlh-llama.cpp-egpu` (v100 / Qwen3.8-27B) and `hlh-llama.cpp-igpu`
  (Qwen3.6-35B-A3B) dashboards. It parameterizes the DGX Spark layout + NVIDIA
  theme per engine: instance label, cloud-pricing tier, and power draw
  (duty-weighted busy/idle watts). Edit the `PROFILES` dict there, re-run the
  script, and re-copy the JSONs into the CT — do not hand-edit the JSON.
- `hlh-llama.cpp-egpu.json` / `hlh-llama.cpp-igpu.json` — generated output.
  Provisioned automatically by Grafana (file provider, 10 s interval).
- `hlh-vllm-igpu.json` — vLLM dashboard.

To update pricing or power figures after measuring with a Kill-A-Watt, change
the `power` / `pricing` values in `generate_dashboards.py` and regenerate.

## License

[Add your license here]

## Contributing

PRs and improvements welcome — especially better unified dashboards, alerting rules, or additional exporters.
