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

4. Open Grafana at `http://localhost:3000` (default credentials: `admin` / `admin`).
5. Import the provided dashboards (or create your own panels filtered by `job` / engine label).

Prometheus will be available at `http://localhost:9090`.

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

- Official / community vLLM Grafana dashboards can be imported directly.
- Community llama.cpp dashboards exist and can be adapted.
- A combined multi-engine dashboard is recommended: rows or variables filtered by engine so both services appear side-by-side.

## License

[Add your license here]

## Contributing

PRs and improvements welcome — especially better unified dashboards, alerting rules, or additional exporters.
