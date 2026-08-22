#!/bin/bash
# Auto-detect stale Cloudflare tunnels, restart them, and update links-page.
# Run via cron every 10 minutes.

LOG="/home/work/links-page/tunnel_health.log"
CF="/usr/local/bin/cloudflared"
UPDATED=0

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Health check starting" >> "$LOG"

# If the uplink itself is down, every tunnel looks dead — bail out instead of
# mass-restarting healthy tunnels (they'd all rotate URLs for nothing)
if ! curl -s -o /dev/null --max-time 10 https://1.1.1.1/; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uplink down (1.1.1.1 unreachable) — skipping run" >> "$LOG"
  exit 0
fi

# Tunnel definitions: name|port|type (systemd or process)
# For systemd tunnels, "port" is the service name suffix (cloudflared-<name>)
# 2026-08-22: chat and dashboard converted from "process" to "systemd".
# The process path spawned tunnels with `disown`, which detached them from
# fraqtoos-tunnel.service and left them parented to tunnel-health.service — a
# ONESHOT unit that had already exited. So a healed tunnel ended up owned by a
# dead cgroup: Restart=always could never revive it, and `systemctl restart
# fraqtoos-tunnel` no longer touched it. Every tunnel is now a real unit.
TUNNELS=(
  "chat|chat|systemd"
  "dashboard|dashboard|systemd"
  # ipmi REMOVED 2026-08-22 — SECURITY. start_tunnel.sh disabled this tunnel on
  # 2026-07-30 ("IPMI = full server control", re-enable only behind an auth
  # layer), but this list was never updated, so every health run silently
  # respawned it and republished the BMC on the public links page. The healer
  # was defeating the security decision. Do NOT re-add without an auth layer;
  # use `tailscale serve` for private BMC access instead.
  # "ipmi|http://192.168.0.103|process"
  "grafana|grafana|systemd"
  "obsidian|obsidian|systemd"
)

# All URL checks resolve via DNS-over-HTTPS: a fresh trycloudflare hostname
# queried before its record exists gets NXDOMAIN negative-cached by
# systemd-resolved/ISP resolvers, making healthy tunnels look dead for up to
# an hour (and DoH also sidesteps the ISP's UDP/DNS drops).
DOH="--doh-url https://1.1.1.1/dns-query"

check_url() {
  local url="$1"
  [ -z "$url" ] && return 1
  local code
  code=$(curl -sL $DOH -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
  [ "$code" -ge 200 ] && [ "$code" -lt 500 ]
}

# A freshly restarted tunnel needs a few seconds before its DNS record exists
# and the edge routes it — wait first (don't seed negative caches), then retry
verify_url() {
  local url="$1" i
  sleep 5
  for i in 1 2 3 4; do
    check_url "$url" && return 0
    sleep 5
  done
  return 1
}

# WhatsApp alert via shared wa-service (:3131), max one per hour so a
# persistent failure doesn't spam every 10-min run
ALERT_STATE="/tmp/tunnel_alert_last"
send_alert() {
  local msg="$1" now last=0
  now=$(date +%s)
  [ -f "$ALERT_STATE" ] && last=$(cat "$ALERT_STATE" 2>/dev/null)
  if [ $((now - ${last:-0})) -lt 3600 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Alert suppressed (cooldown): $msg" >> "$LOG"
    return
  fi
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"phone":"919818187001","message":sys.argv[1]}))' "$msg")
  if curl -s --max-time 20 -X POST http://localhost:3131/send \
       -H 'Content-Type: application/json' -d "$payload" | grep -q '"ok":true'; then
    echo "$now" > "$ALERT_STATE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Alert sent: $msg" >> "$LOG"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Alert send FAILED: $msg" >> "$LOG"
  fi
}
FAILED_TUNNELS=""

restart_systemd_tunnel() {
  local name="$1"
  sudo systemctl restart "cloudflared-${name}"
  sleep 8
  local url
  url=$(journalctl -u "cloudflared-${name}" --since "10 seconds ago" --no-pager 2>/dev/null | grep -oP 'https://(?!api\.)[a-z0-9\-]+\.trycloudflare\.com' | tail -1)
  echo "$url"
}

restart_process_tunnel() {
  local name="$1" target="$2"
  # Kill existing tunnel for this target
  local pids
  if [[ "$target" == http* ]]; then
    pids=$(pgrep -f "cloudflared tunnel --url ${target}" 2>/dev/null)
  else
    pids=$(pgrep -f "cloudflared tunnel --url http://localhost:${target}" 2>/dev/null)
  fi
  [ -n "$pids" ] && kill $pids 2>/dev/null && sleep 2

  local logfile="/home/work/fraqtoos-chat/tunnel_${name}.log"
  local urlfile="/tmp/cf_url_${name}"
  rm -f "$urlfile"

  local tunnel_target
  if [[ "$target" == http* ]]; then
    tunnel_target="$target"
  else
    tunnel_target="http://localhost:${target}"
  fi

  ( $CF tunnel --url "$tunnel_target" --no-autoupdate 2>&1 | \
    tee -a "$logfile" | \
    grep --line-buffered "trycloudflare.com" | \
    while IFS= read -r line; do
      local u
      u=$(echo "$line" | grep -oP 'https://(?!api\.)[a-z0-9\-]+\.trycloudflare\.com')
      [ -n "$u" ] && echo "$u" > "$urlfile"
    done ) </dev/null >/dev/null 2>&1 &
  disown

  # Wait for URL
  for i in $(seq 1 15); do
    sleep 1
    [ -s "$urlfile" ] && break
  done
  cat "$urlfile" 2>/dev/null
}

# Read the URL a systemd-managed tunnel is CURRENTLY advertising, straight from
# its journal, rather than trusting the cached copy.
current_systemd_url() {
  journalctl -u "cloudflared-$1" --no-pager -n 300 2>/dev/null \
    | grep -oP 'https://(?!api\.)[a-z0-9\-]+\.trycloudflare\.com' | tail -1
}

for entry in "${TUNNELS[@]}"; do
  IFS='|' read -r name target type <<< "$entry"
  url=$(cat "/tmp/cf_url_${name}" 2>/dev/null)

  # Adopt-before-restart. Now that every tunnel has Restart=always, systemd
  # revives a dead tunnel in ~15s with a NEW url, long before this 10-minute
  # check runs. The cached url is then stale-but-the-tunnel-is-fine, and the
  # old logic would "heal" a perfectly healthy tunnel — burning a third URL
  # rotation and an extra Pages deploy every time systemd did its job.
  # Pick up what the unit is actually serving first.
  if [ "$type" = "systemd" ]; then
    live_url=$(current_systemd_url "$name")
    if [ -n "$live_url" ] && [ "$live_url" != "$url" ] && check_url "$live_url"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name adopted new url from systemd → $live_url" >> "$LOG"
      echo "$live_url" > "/tmp/cf_url_${name}"
      UPDATED=1
      continue
    fi
  fi

  if check_url "$url"; then
    continue
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name STALE — restarting" >> "$LOG"

  if [ "$type" = "systemd" ]; then
    new_url=$(restart_systemd_tunnel "$name")
  else
    new_url=$(restart_process_tunnel "$name" "$target")
  fi

  if [ -n "$new_url" ] && verify_url "$new_url"; then
    echo "$new_url" > "/tmp/cf_url_${name}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name → $new_url" >> "$LOG"
    UPDATED=1
  elif [ -n "$new_url" ]; then
    # Tunnel registered but never served — dead origin or tunnel died again.
    # Still publish the URL (better than the old dead one) but flag it.
    echo "$new_url" > "/tmp/cf_url_${name}"
    UPDATED=1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name restarted but NOT serving ($new_url)" >> "$LOG"
    FAILED_TUNNELS="$FAILED_TUNNELS $name(not-serving)"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name FAILED to get new URL" >> "$LOG"
    FAILED_TUNNELS="$FAILED_TUNNELS $name(no-url)"
  fi
done

# Update links-page if any tunnel was restarted
if [ "$UPDATED" -eq 1 ]; then
  /home/work/links-page/update_urls.sh >> "$LOG" 2>&1
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Links page updated" >> "$LOG"
fi

# End-to-end check: the LIVE stable redirect pages (/go/<name>/) must forward
# to the current tunnel URLs. Catches failed pushes / stuck Pages deploys that
# the local checks can't see. Tolerate one stale run (deploy may still be
# propagating) — alert only when stale twice in a row (>10 min).
STALE_STATE="/tmp/links_page_stale_runs"
live=$(curl -s --max-time 20 "https://saurishg.github.io/links-page/urls.json?hc=$(date +%s)" 2>/dev/null)
if [ -n "$live" ]; then
  missing=""
  # Iterate the configured TUNNELS, not /tmp/cf_url_* — a removed tunnel leaves
  # its stale /tmp/cf_url_<name> behind, and globbing it kept auditing (and
  # alerting on) a tunnel that no longer exists until the next reboot cleared
  # /tmp. That is what spammed 1299 "not self-healing: atinus" alerts over the
  # 10 days after the atinus origin was disabled (removed entirely 2026-08-09).
  for t in "${TUNNELS[@]}"; do
    n="${t%%|*}"
    u=$(cat "/tmp/cf_url_$n" 2>/dev/null)
    [ -z "$u" ] && continue
    # urls.json is what the redirect pages actually fetch — it must be fresh
    if ! grep -qF "$u" <<< "$live"; then
      missing="$missing $n"
      continue
    fi
    # the baked fallback in the redirect page should catch up too
    page=$(curl -s --max-time 15 "https://saurishg.github.io/links-page/go/${n}/?hc=$(date +%s)" 2>/dev/null)
    grep -qF "$u" <<< "$page" || missing="$missing $n(fallback)"
  done
  if [ -n "$missing" ]; then
    runs=$(( $(cat "$STALE_STATE" 2>/dev/null || echo 0) + 1 ))
    echo "$runs" > "$STALE_STATE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Live page stale (run $runs):$missing" >> "$LOG"
    # Re-run the publisher — it pushes any unpushed commits
    /home/work/links-page/update_urls.sh >> "$LOG" 2>&1
    [ "$runs" -ge 2 ] && FAILED_TUNNELS="$FAILED_TUNNELS live-page-stale($missing )"
  else
    rm -f "$STALE_STATE"
  fi
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Could not fetch live page (network?)" >> "$LOG"
fi

if [ -n "$FAILED_TUNNELS" ]; then
  send_alert "⚠️ Links page health: not self-healing:$FAILED_TUNNELS
Check tunnel_health.log on work-desktop."
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Health check done" >> "$LOG"
