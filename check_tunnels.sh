#!/bin/bash
# Auto-detect stale Cloudflare tunnels, restart them, and update links-page.
# Run via cron every 10 minutes.

LOG="/home/work/links-page/tunnel_health.log"
CF="/usr/local/bin/cloudflared"
UPDATED=0

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Health check starting" >> "$LOG"

# Tunnel definitions: name|port|type (systemd or process)
# For systemd tunnels, "port" is the service name suffix (cloudflared-<name>)
TUNNELS=(
  "chat|8080|process"
  "comfyui|8188|process"
  "dashboard|3000|process"
  "ipmi|http://192.168.2.103|process"
  "atinus|8765|process"
  "mpt|8501|process"
  "grafana|grafana|systemd"
  "obsidian|obsidian|systemd"
)

check_url() {
  local url="$1"
  [ -z "$url" ] && return 1
  local code
  code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
  [ "$code" -ge 200 ] && [ "$code" -lt 500 ]
}

restart_systemd_tunnel() {
  local name="$1"
  sudo systemctl restart "cloudflared-${name}"
  sleep 8
  local url
  url=$(journalctl -u "cloudflared-${name}" --since "10 seconds ago" --no-pager 2>/dev/null | grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' | tail -1)
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

  $CF tunnel --url "$tunnel_target" --no-autoupdate 2>&1 | \
    tee -a "$logfile" | \
    grep --line-buffered "trycloudflare.com" | \
    while IFS= read -r line; do
      local u
      u=$(echo "$line" | grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com')
      [ -n "$u" ] && echo "$u" > "$urlfile"
    done &

  # Wait for URL
  for i in $(seq 1 15); do
    sleep 1
    [ -s "$urlfile" ] && break
  done
  cat "$urlfile" 2>/dev/null
}

for entry in "${TUNNELS[@]}"; do
  IFS='|' read -r name target type <<< "$entry"
  url=$(cat "/tmp/cf_url_${name}" 2>/dev/null)

  if check_url "$url"; then
    continue
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name STALE — restarting" >> "$LOG"

  if [ "$type" = "systemd" ]; then
    new_url=$(restart_systemd_tunnel "$name")
  else
    new_url=$(restart_process_tunnel "$name" "$target")
  fi

  if [ -n "$new_url" ]; then
    echo "$new_url" > "/tmp/cf_url_${name}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name → $new_url" >> "$LOG"
    UPDATED=1
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $name FAILED to get new URL" >> "$LOG"
  fi
done

# Update links-page if any tunnel was restarted
if [ "$UPDATED" -eq 1 ]; then
  /home/work/links-page/update_urls.sh >> "$LOG" 2>&1
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Links page updated" >> "$LOG"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Health check done" >> "$LOG"
