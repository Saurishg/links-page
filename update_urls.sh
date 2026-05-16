#!/bin/bash
# Auto-update links-page index.html with current Cloudflare tunnel URLs
# Reads from /tmp/cf_url_* and commits/pushes to GitHub
# Called automatically by start_tunnel.sh after tunnels come up

set -e

REPO=/home/work/links-page
HTML=$REPO/index.html

CHAT=$(cat /tmp/cf_url_chat 2>/dev/null || echo "")
COMFY=$(cat /tmp/cf_url_comfyui 2>/dev/null || echo "")
DASH=$(cat /tmp/cf_url_dashboard 2>/dev/null || echo "")
GRAFANA=$(cat /tmp/cf_url_grafana 2>/dev/null || echo "")

if [ -z "$CHAT" ] && [ -z "$COMFY" ] && [ -z "$DASH" ] && [ -z "$GRAFANA" ]; then
  echo "No tunnel URLs found — skipping update"
  exit 0
fi

cd $REPO

# Read current URLs from the HTML to replace
CUR_CHAT=$(grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' $HTML | sed -n '1p')
CUR_COMFY=$(grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' $HTML | sed -n '2p')
CUR_DASH=$(grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' $HTML | sed -n '3p')
CUR_GRAFANA=$(grep -oP 'https://[a-z0-9\-]+\.trycloudflare\.com' $HTML | sed -n '4p')

[ -n "$CHAT" ]     && [ -n "$CUR_CHAT" ]     && sed -i "s|$CUR_CHAT|$CHAT|g" $HTML
[ -n "$COMFY" ]    && [ -n "$CUR_COMFY" ]    && sed -i "s|$CUR_COMFY|$COMFY|g" $HTML
[ -n "$DASH" ]     && [ -n "$CUR_DASH" ]     && sed -i "s|$CUR_DASH|$DASH|g" $HTML
[ -n "$GRAFANA" ]  && [ -n "$CUR_GRAFANA" ]  && sed -i "s|$CUR_GRAFANA|$GRAFANA|g" $HTML

# Commit + push only if file changed
if ! git diff --quiet index.html; then
  git add index.html
  git commit -m "auto-update tunnel URLs ($(date '+%Y-%m-%d %H:%M'))"
  GIT_ASKPASS=echo git push origin main
  echo "✓ Pushed updated URLs to GitHub Pages"
else
  echo "✓ URLs unchanged — no push needed"
fi
