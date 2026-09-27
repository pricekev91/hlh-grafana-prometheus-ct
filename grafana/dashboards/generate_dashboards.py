#!/usr/bin/env python3
"""Generate the llama.cpp engine dashboards (v100/egpu + igpu).

One parameterized build; profiles differ by instance label, model tier
pricing, and power estimates. Classic gridPos schema (Grafana 11.5.2),
DGX Spark layout + NVIDIA theme.

Usage:
    python3 generate_dashboards.py            # write both JSONs next to this file
    python3 generate_dashboards.py out.json   # write just the egpu profile

Profiles are the single source of truth for the cost strip and power
math — edit PRICING / POWER there when you get Kill-A-Watt numbers.
"""
import json, sys

DS = {"type": "prometheus", "uid": "PBFA97CFB590B2093"}

# ---- palette (DGX / NVIDIA theme) ----
GREEN  = "#76B900"
LGREEN = "#A4D65E"
XLGREEN= "#C8E399"
AMBER  = "#E5C100"
AMBER2 = "#D9A400"
RED    = "#FF4D4D"

PROFILES = {
    "egpu": {
        "instance": "hlh-ai-engine-epu",
        "title": "hlh-llama.cpp-egpu (v100 \u00b7 Qwen3.8-27B)",
        "uid": "hlh-llama-cpp-egpu",
        "host_ip": "192.168.1.11",
        "model": "Qwen3.8-27B-MTP-Q4_K_M",
        "pricing": {"in_low": 0.30, "in_high": 0.50, "out_low": 2.00, "out_high": 3.00},
        "power": {"busy_w": 350, "idle_w": 50, "note": "V100 + HX 370 (~320-380W busy / ~40-60W idle, VRM/fans/RAM/SSD incl.)"},
        "tags": ["llama.cpp", "v100", "qwen3.8-27b", "hlh", "prometheus", "nvidia-theme", "speculative-decoding", "cost"],
    },
    "igpu": {
        "instance": "hlh-ai-engine",
        "title": "hlh-llama.cpp-igpu (Qwen3.6-35B-A3B)",
        "uid": "hlh-llama-cpp-igpu",
        "host_ip": "192.168.1.12",
        "model": "Qwen3.6-35B-A3B-MTP-Q4_K_M",
        "pricing": {"in_low": 0.10, "in_high": 0.25, "out_low": 0.70, "out_high": 1.50},
        "power": {"busy_w": 250, "idle_w": 35, "note": "HX 370 iGPU (placeholder ~250W busy / ~35W idle - confirm with Kill-A-Watt)"},
        "tags": ["llama.cpp", "igpu", "qwen3.6-35b-a3b", "hlh", "prometheus", "nvidia-theme", "speculative-decoding", "cost"],
    },
}
RATE = 0.151  # $/kWh

def ds(): return json.loads(json.dumps(DS))

def q(expr, legend, refId):
    return {"datasource": ds(), "expr": expr, "refId": refId,
            "legendFormat": legend, "editorMode": "code", "range": True}

def stat_defaults(color=GREEN, unit="short", minv=None, maxv=None, decimals=None,
                  thresholds=None):
    d = {"color": {"mode": "fixed", "fixedColor": color}, "noValue": "\u2014",
         "thresholds": {"mode": "absolute",
                        "steps": thresholds or [{"color": color, "value": 0}]},
         "unit": unit}
    if minv is not None: d["min"] = minv
    if maxv is not None: d["max"] = maxv
    if decimals is not None: d["decimals"] = decimals
    return d

def cost_stat(pid, title, x, expr, color, legend, desc, w=8, y=0):
    return {
        "id": pid, "title": title, "type": "stat", "datasource": ds(),
        "gridPos": {"h": 3, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": stat_defaults(color, "currencyUSD",
                                                  decimals=2), "overrides": []},
        "options": {"colorMode": "value", "graphMode": "none",
                    "justifyMode": "center", "orientation": "horizontal",
                    "percentChangeColorMode": "standard",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showPercentChange": False, "textMode": "value_and_name",
                    "wideLayout": True},
        "targets": [q(expr, legend, "A")],
        "description": desc, "pluginVersion": "11.5.2",
    }

def range_stat(pid, title, x, w, expr, legend, color=GREEN, unit="short",
               desc="", graph="area", y=3):
    return {
        "id": pid, "title": title, "type": "stat", "datasource": ds(),
        "gridPos": {"h": 5, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": stat_defaults(color, unit), "overrides": []},
        "options": {"colorMode": "value", "graphMode": graph,
                    "justifyMode": "center", "orientation": "auto",
                    "percentChangeColorMode": "standard",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showPercentChange": False, "textMode": "value_and_name",
                    "wideLayout": True},
        "targets": [q(expr, legend, "A")],
        "description": desc, "pluginVersion": "11.5.2",
    }

def gauge(pid, title, x, w, expr, legend, unit="percent",
          thresholds=None, desc="", y=8, h=5):
    t = thresholds or [
        {"color": GREEN, "value": 0},
        {"color": AMBER, "value": 70},
        {"color": RED, "value": 90},
    ]
    return {
        "id": pid, "title": title, "type": "gauge", "datasource": ds(),
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {
            "color": {"mode": "thresholds"}, "min": 0, "max": 100,
            "noValue": "\u2014", "unit": unit,
            "thresholds": {"mode": "absolute", "steps": t}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showThresholdMarkers": True, "orientation": "auto",
                    "sizing": "auto", "displayMode": "gradient"},
        "targets": [q(expr, legend, "A")],
        "description": desc, "pluginVersion": "11.5.2",
    }

def multistat(pid, title, x, w, targets, color=GREEN, unit="short",
              minv=None, maxv=None, desc="", y=8, h=5, textmode="value_and_name"):
    d = {"color": {"mode": "fixed", "fixedColor": color}, "noValue": "\u2014",
         "thresholds": {"mode": "absolute", "steps": [{"color": color, "value": 0}]},
         "unit": unit}
    if minv is not None: d["min"] = minv
    if maxv is not None: d["max"] = maxv
    return {
        "id": pid, "title": title, "type": "stat", "datasource": ds(),
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": d, "overrides": []},
        "options": {"colorMode": "value", "graphMode": "none",
                    "justifyMode": "center", "orientation": "auto",
                    "percentChangeColorMode": "standard",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showPercentChange": False, "textMode": textmode, "wideLayout": True},
        "targets": targets, "description": desc, "pluginVersion": "11.5.2",
    }

TS_CUSTOM = {
    "axisBorderShow": False, "axisCenteredZero": False, "axisColorMode": "text",
    "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "barWidthFactor": 0.6,
    "drawStyle": "line", "fillOpacity": 6, "gradientMode": "opacity",
    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
    "insertNulls": False, "lineInterpolation": "smooth", "lineWidth": 1,
    "pointSize": 4, "scaleDistribution": {"type": "linear"}, "showPoints": "never",
    "showValues": False, "spanNulls": True,
    "stacking": {"group": "A", "mode": "none"},
    "thresholdsStyle": {"mode": "off"},
}

def ts(pid, title, x, w, targets, unit="short", y=13, h=7, color=GREEN,
       desc="", overrides=None, legend_show=True):
    return {
        "id": pid, "title": title, "type": "timeseries", "datasource": ds(),
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {
            "color": {"mode": "fixed", "fixedColor": color}, "noValue": "\u2014",
            "unit": unit, "custom": dict(TS_CUSTOM),
            "thresholds": {"mode": "absolute", "steps": [{"color": color, "value": 0}]},
        }, "overrides": overrides or []},
        "options": {
            "annotations": {"clustering": -1, "multiLane": False},
            "legend": {"calcs": ["lastNotNull", "mean", "max"], "displayMode": "table",
                       "enableFacetedFilter": False, "overflow": "ellipsis",
                       "placement": "bottom", "showLegend": legend_show},
            "tooltip": {"hideZeros": False, "mode": "multi", "sort": "desc"},
        },
        "targets": targets, "description": desc, "pluginVersion": "11.5.2",
    }

def color_override(name, color):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}]}

def bargauge(pid, title, x, w, targets, y=20, h=7, desc="", unit="percent"):
    return {
        "id": pid, "title": title, "type": "bargauge", "datasource": ds(),
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {
            "color": {"mode": "fixed", "fixedColor": GREEN}, "noValue": "\u2014",
            "unit": unit, "min": 0, "max": 100,
            "thresholds": {"mode": "absolute", "steps": [
                {"color": GREEN, "value": 0}, {"color": AMBER, "value": 70},
                {"color": RED, "value": 90}]}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "orientation": "horizontal", "displayMode": "gradient",
                    "showUnfilled": True},
        "targets": targets, "description": desc, "pluginVersion": "11.5.2",
    }

def build(profile_name):
    P = PROFILES[profile_name]
    INST = f'instance="{P["instance"]}"'
    P_BUSY, P_IDLE = P["power"]["busy_w"], P["power"]["idle_w"]
    PR = P["pricing"]
    panels = []

    # ---------- Row 0: cost strip (4 x w6) ----------
    inp = f"sum(increase(llamacpp:prompt_tokens_total{{{INST}}}[$__range])) + sum(increase(llamacpp:prompt_tokens_cached_total{{{INST}}}[$__range]))"
    out = f"sum(increase(llamacpp:tokens_predicted_total{{{INST}}}[$__range]))"
    panels.append(cost_stat(1, f"CLOUD \u00b7 LOW (${PR['in_low']:.2f} in / ${PR['out_low']:.2f} out)", 0,
        f"(({inp}) * {PR['in_low']} + ({out}) * {PR['out_low']}) / 1000000", XLGREEN, "cloud low",
        f"What this range would cost on a low-tier {P['model']} host: "
        f"${PR['in_low']:.2f} input / ${PR['out_low']:.2f} output per 1M tokens. Input = prompt + cached tokens.", w=6))
    panels.append(cost_stat(2, f"CLOUD \u00b7 HIGH (${PR['in_high']:.2f} in / ${PR['out_high']:.2f} out)", 6,
        f"(({inp}) * {PR['in_high']} + ({out}) * {PR['out_high']}) / 1000000", AMBER, "cloud high",
        f"What this range would cost at the high end of {P['model']} pricing: "
        f"${PR['in_high']:.2f} input / ${PR['out_high']:.2f} output per 1M tokens.", w=6))

    # Busy seconds come straight from the engine's own prompt/generation timers.
    # `or vector(0)` keeps a value present even if the range has no samples, so the
    # idle floor is ALWAYS shown (never a blank).
    BUSY_S = (f"((sum(increase(llamacpp:prompt_seconds_total{{{INST}}}[$__range])) or vector(0))"
              f" + (sum(increase(llamacpp:tokens_predicted_seconds_total{{{INST}}}[$__range])) or vector(0)))")
    ENERGY_W = f"(clamp(({BUSY_S}) / $__range_s, 0, 1) * {P_BUSY} + (1 - clamp(({BUSY_S}) / $__range_s, 0, 1)) * {P_IDLE})"

    panels.append({
        "id": 3, "title": "LOCAL POWER \u00b7 DUTY-WEIGHTED (avg W)", "type": "stat", "datasource": ds(),
        "gridPos": {"h": 3, "w": 6, "x": 12, "y": 0},
        "fieldConfig": {"defaults": stat_defaults(GREEN, "watt", decimals=0), "overrides": []},
        "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center",
                    "orientation": "horizontal", "percentChangeColorMode": "standard",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showPercentChange": False, "textMode": "value_and_name", "wideLayout": True},
        "targets": [q(ENERGY_W, "avg W", "A")],
        "description": (f"Duty-weighted average system draw over the range: ~{P_BUSY}W busy / ~{P_IDLE}W idle "
                        f"({P['power']['note']}). Idle always shows the ~{P_IDLE}W floor; "
                        f"blended by the engine's actual busy fraction (prompt + generation timers)."),
        "pluginVersion": "11.5.2",
    })
    panels.append({
        "id": 33, "title": "LOCAL ENERGY COST ($)", "type": "stat", "datasource": ds(),
        "gridPos": {"h": 3, "w": 6, "x": 18, "y": 0},
        "fieldConfig": {"defaults": stat_defaults(GREEN, "currencyUSD", decimals=2), "overrides": []},
        "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center",
                    "orientation": "horizontal", "percentChangeColorMode": "standard",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showPercentChange": False, "textMode": "value_and_name", "wideLayout": True},
        "targets": [q(f"(({ENERGY_W}) / 1000) * ($__range_s / 3600) * {RATE}", "cost $", "A")],
        "description": (f"Electricity for the selected range at ${RATE}/kWh, using the duty-weighted "
                        f"average draw shown beside it."),
        "pluginVersion": "11.5.2",
    })

    # ---------- Row 1: range tokens (6 x w4) ----------
    panels.append(range_stat(4, "TOTAL TOKENS (RANGE)", 0, 4,
        f"({inp}) + ({out})", "total", GREEN, "short",
        "Prompt + cached + output tokens in the selected range."))
    panels.append(range_stat(5, "INPUT TOKENS (RANGE)", 4, 4, inp, "input", LGREEN, "short",
        "Billable input: prompt + cached tokens in range."))
    panels.append(range_stat(6, "CACHED TOKENS (RANGE)", 8, 4,
        f"sum(increase(llamacpp:prompt_tokens_cached_total{{{INST}}}[$__range]))", "cached", XLGREEN, "short",
        "Prompt tokens reused from cache (free compute, still counted as input for cloud comparison)."))
    panels.append(range_stat(7, "OUTPUT TOKENS (RANGE)", 12, 4, out, "output", GREEN, "short",
        "Generated tokens in range."))
    panels.append(range_stat(8, "TOTAL TOKENS / SEC", 16, 4,
        f"sum(rate(llamacpp:prompt_tokens_total{{{INST}}}[$__rate_interval])) + sum(rate(llamacpp:prompt_tokens_cached_total{{{INST}}}[$__rate_interval])) + sum(rate(llamacpp:tokens_predicted_total{{{INST}}}[$__rate_interval]))",
        "tokens/sec", GREEN, "tps"))
    panels.append(range_stat(9, "OUTPUT TOKENS / SEC", 20, 4,
        f"sum(rate(llamacpp:tokens_predicted_total{{{INST}}}[$__rate_interval]))", "output/sec", GREEN, "tps"))

    # ---------- Row 2: gauges + live state + PEAK speed (6 x w4, h=5) ----------
    panels.append(gauge(10, "CACHE HIT RATE", 0, 4,
        f"(100 * sum(rate(llamacpp:prompt_tokens_cached_total{{{INST}}}[5m])) / clamp_min(sum(rate(llamacpp:prompt_tokens_total{{{INST}}}[5m])) + sum(rate(llamacpp:prompt_tokens_cached_total{{{INST}}}[5m])), 0.0001))",
        "hit %", thresholds=[{"color": GREEN, "value": 0}],
        desc="Share of input tokens served from cache over the last 5m (rate-based)."))
    panels.append(gauge(11, "SPEC DECODE ACCEPTANCE", 4, 4,
        f"100 * sum(rate(llamacpp:spec_decode_num_accepted_tokens_total{{{INST}}}[5m])) / clamp_min(sum(rate(llamacpp:spec_decode_num_draft_tokens_total{{{INST}}}[5m])), 0.0001)",
        "accept %", thresholds=[{"color": GREEN, "value": 0}],
        desc="Accepted draft tokens / proposed draft tokens over the last 5m (MTP)."))
    panels.append(multistat(12, "REQUESTS PROCESSING / DEFERRED", 8, 4,
        [q(f"sum(llamacpp:requests_processing{{{INST}}})", "processing", "A"),
         q(f"sum(llamacpp:requests_deferred{{{INST}}})", "deferred", "B")],
        unit="none", desc="Live slot activity on the engine."))
    panels.append(multistat(13, "N_TOKENS_MAX (HIGH-WATER)", 12, 4,
        [q(f"max(llamacpp:n_tokens_max{{{INST}}})", "max seq len", "A")],
        unit="none", desc="Largest observed sequence length (prompt + generation)."))
    panels.append(multistat(32, "MAX OUTPUT TOK/S (PEAK)", 16, 4,
        [q(f"max_over_time((sum(rate(llamacpp:tokens_predicted_total{{{INST}}}[1m])))[$__range:1m])",
           "peak out t/s", "A")],
        unit="tps",
        desc="Highest output tok/s reached over the selected range (peak of the 1m rate)."))
    panels.append(multistat(14, "DECODE CALLS / SLOTS", 20, 4,
        [q(f"sum(rate(llamacpp:n_decode_total{{{INST}}}[5m]))", "decodes/s", "A"),
         q(f"avg(llamacpp:n_busy_slots_per_decode{{{INST}}})", "busy slots", "B"),
         q(f"sum(llamacpp:requests_processing{{{INST}}})", "processing", "C"),
         q(f"sum(llamacpp:requests_deferred{{{INST}}})", "deferred", "D")],
        unit="short", desc="llama_decode() call rate and concurrency."))

    # ---------- Row 3: throughput (2 x w12) ----------
    panels.append(ts(15, "TOKEN THROUGHPUT OVER TIME", 0, 12,
        [q(f"sum(rate(llamacpp:prompt_tokens_total{{{INST}}}[5m]))", "prompt t/s", "A"),
         q(f"sum(rate(llamacpp:prompt_tokens_cached_total{{{INST}}}[5m]))", "cached t/s", "B"),
         q(f"sum(rate(llamacpp:tokens_predicted_total{{{INST}}}[5m]))", "output t/s", "C"),
         q(f"sum(rate(llamacpp:prompt_tokens_total{{{INST}}}[5m])) + sum(rate(llamacpp:prompt_tokens_cached_total{{{INST}}}[5m])) + sum(rate(llamacpp:tokens_predicted_total{{{INST}}}[5m]))", "total t/s", "D")],
        unit="tps",
        overrides=[color_override("prompt t/s", LGREEN),
                   color_override("cached t/s", XLGREEN),
                   color_override("output t/s", GREEN),
                   color_override("total t/s", AMBER)]))
    panels.append(ts(16, "PROMPT vs GENERATION TIME", 12, 12,
        [q(f"sum(rate(llamacpp:prompt_seconds_total{{{INST}}}[5m]))", "prompt s/s", "A"),
         q(f"sum(rate(llamacpp:tokens_predicted_seconds_total{{{INST}}}[5m]))", "generation s/s", "B"),
         q(f"sum(rate(llamacpp:prompt_seconds_total{{{INST}}}[5m])) + sum(rate(llamacpp:tokens_predicted_seconds_total{{{INST}}}[5m]))", "total s/s", "C")],
        unit="s",
        overrides=[color_override("prompt s/s", LGREEN),
                   color_override("generation s/s", GREEN),
                   color_override("total s/s", AMBER)],
        desc="Wall-clock seconds per second spent on prompt processing vs generation (>1 = busy)."))

    # ---------- Row 4: spec decode + decode detail (3 x w8) ----------
    panels.append(ts(17, "SPEC DRAFTS & ACCEPTED", 0, 8,
        [q(f"sum(rate(llamacpp:spec_decode_num_drafts_total{{{INST}}}[5m]))", "draft steps/s", "A"),
         q(f"sum(rate(llamacpp:spec_decode_num_draft_tokens_total{{{INST}}}[5m]))", "draft tokens/s", "B"),
         q(f"sum(rate(llamacpp:spec_decode_num_accepted_tokens_total{{{INST}}}[5m]))", "accepted/s", "C")],
        unit="tps", y=20, h=7,
        overrides=[color_override("draft steps/s", LGREEN),
                   color_override("draft tokens/s", AMBER2),
                   color_override("accepted/s", GREEN)]))
    panels.append(bargauge(18, "SPEC ACCEPTANCE BY POSITION", 8, 8,
        [q(f"100 * sum by (position) (rate(llamacpp:spec_decode_num_accepted_tokens_per_pos_total{{{INST}}}[5m])) / scalar(clamp_min(sum(rate(llamacpp:spec_decode_num_drafts_total{{{INST}}}[5m])), 0.0001))",
           "pos {{position}}", "A")],
        desc="MTP head acceptance rate per draft position (last 5m)."))
    panels.append(ts(19, "DECODE CALLS & BUSY SLOTS", 16, 8,
        [q(f"sum(rate(llamacpp:n_decode_total{{{INST}}}[5m]))", "decodes/s", "A"),
         q(f"avg(llamacpp:n_busy_slots_per_decode{{{INST}}})", "busy slots", "B"),
         q(f"sum(llamacpp:requests_processing{{{INST}}})", "processing", "C"),
         q(f"sum(llamacpp:requests_deferred{{{INST}}})", "deferred", "D")],
        unit="short", y=20, h=7,
        overrides=[color_override("decodes/s", GREEN),
                   color_override("busy slots", LGREEN),
                   color_override("processing", AMBER),
                   color_override("deferred", RED)]))

    # ---------- Rows 5-6: host (node-exporter, $host_instance) ----------
    def H(extra=""):
        if extra:
            return '{instance="$host_instance", %s}' % extra
        return '{instance="$host_instance"}'

    panels.append(ts(20, "CPU: USER / SYSTEM / IOWAIT", 0, 8,
        [q('100 * avg(rate(node_cpu_seconds_total' + H('mode="user"') + '[$__rate_interval]))', "user %", "A"),
         q('100 * avg(rate(node_cpu_seconds_total' + H('mode="system"') + '[$__rate_interval]))', "system %", "B"),
         q('100 * avg(rate(node_cpu_seconds_total' + H('mode="iowait"') + '[$__rate_interval]))', "iowait %", "C")],
        unit="percent", y=27, h=7,
        overrides=[color_override("user %", GREEN),
                   color_override("system %", LGREEN),
                   color_override("iowait %", RED)],
        desc="Host: $host_instance (currently the monitor CT; add a per-engine node-exporter to re-point)."))
    panels.append(ts(21, "MEMORY: USED / AVAILABLE / CACHE", 8, 8,
        [q('node_memory_MemTotal_bytes' + H() + ' - node_memory_MemAvailable_bytes' + H(), "used", "A"),
         q('node_memory_MemAvailable_bytes' + H(), "available", "B"),
         q('node_memory_Cached_bytes' + H(), "cache", "C")],
        unit="bytes", y=27, h=7,
        overrides=[color_override("used", GREEN),
                   color_override("available", LGREEN),
                   color_override("cache", XLGREEN)]))
    panels.append(ts(22, "NETWORK: RX / TX", 16, 8,
        [q('sum(rate(node_network_receive_bytes_total' + H('device!~"lo|docker.*|br.*|veth.*"') + '[$__rate_interval]))', "receive", "A"),
         q('sum(rate(node_network_transmit_bytes_total' + H('device!~"lo|docker.*|br.*|veth.*"') + '[$__rate_interval]))', "transmit", "B")],
        unit="Bps", y=27, h=7,
        overrides=[color_override("receive", GREEN),
                   color_override("transmit", LGREEN)]))
    panels.append(ts(23, "DISK: READ / WRITE BYTES", 0, 8,
        [q('sum(rate(node_disk_read_bytes_total' + H() + '[$__rate_interval]))', "read", "A"),
         q('sum(rate(node_disk_written_bytes_total' + H() + '[$__rate_interval]))', "write", "B")],
        unit="Bps", y=34, h=7,
        overrides=[color_override("read", GREEN),
                   color_override("write", LGREEN)]))
    panels.append(ts(24, "DISK IOPS", 8, 8,
        [q('sum(rate(node_disk_reads_completed_total' + H() + '[$__rate_interval]))', "reads/sec", "A"),
         q('sum(rate(node_disk_writes_completed_total' + H() + '[$__rate_interval]))', "writes/sec", "B")],
        unit="iops", y=34, h=7,
        overrides=[color_override("reads/sec", GREEN),
                   color_override("writes/sec", LGREEN)]))
    panels.append(bargauge(25, "FILESYSTEM SPACE BY MOUNT", 16, 8,
        [q('100 * (1 - node_filesystem_avail_bytes' + H('fstype!~"tmpfs|overlay|squashfs"') + ' / node_filesystem_size_bytes' + H('fstype!~"tmpfs|overlay|squashfs"') + ')',
           "{{mountpoint}}", "A")],
        y=34, h=7, desc="Percent used per mount."))

    return {
        "title": P["title"],
        "uid": P["uid"],
        "description": (f"{P['title']} \u2014 {P['model']} on llama.cpp ({P['host_ip']}:80, instance {P['instance']}). "
                        f"DGX Spark layout + NVIDIA theme; cost strip = {P['model']} cloud pricing "
                        f"(${PR['in_low']:.2f}-{PR['in_high']:.2f} in / ${PR['out_low']:.2f}-{PR['out_high']:.2f} out per M) "
                        f"vs local power/energy (duty-weighted, ~{P_BUSY}W busy / ~{P_IDLE}W idle, ${RATE}/kWh). "
                        f"Host rows follow $host_instance (currently the monitor CT). "
                        f"Generated by generate_dashboards.py - edit profiles there, not the JSON."),
        "tags": P["tags"],
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 0,
        "refresh": "5s",
        "time": {"from": "now-1h", "to": "now"},
        "timepicker": {},
        "weekStart": "",
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "editable": True,
        "preload": False,
        "links": [],
        "annotations": {"list": [{
            "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True, "hide": True, "iconColor": GREEN,
            "name": "Annotations & Alerts", "type": "dashboard"}]},
        "templating": {"list": [{
            "name": "host_instance", "label": "Host",
            "type": "query", "query": "label_values(node_time_seconds, instance)",
            "refresh": 2, "regex": "", "sort": 1, "group": "All",
            "current": {"text": "hlh-docker", "value": "hlh-docker"},
            "options": [], "hide": 0, "includeAll": False, "multi": False,
            "allValue": None, "definition": "label_values(node_time_seconds, instance)",
        }]},
        "panels": panels,
    }

if __name__ == "__main__":
    import os
    outdir = os.path.dirname(os.path.abspath(__file__))
    if len(sys.argv) > 1:
        paths = [sys.argv[1]]
        profs = [None]  # caller-specified single file, write egpu unless name says igpu
        if "igpu" in sys.argv[1]: profs = ["igpu"]
        else: profs = ["egpu"]
    else:
        profs = ["egpu", "igpu"]
        paths = [os.path.join(outdir, f"hlh-llama.cpp-{p}.json") for p in profs]
    for name, path in zip(profs, paths):
        dash = build(name)
        json.dump(dash, open(path, "w"), indent=1)
        print("wrote", path, f"({len(dash['panels'])} panels)")
