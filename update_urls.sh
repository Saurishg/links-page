#!/bin/bash
# Auto-update links-page index.html with current Cloudflare tunnel URLs.
# Uses data-tunnel="<name>" attributes on <a> tags for reliable replacement.
# Called automatically by start_tunnel.sh after tunnels come up.

set -e

REPO=/home/work/links-page
HTML=$REPO/index.html

CHAT=$(cat /tmp/cf_url_chat 2>/dev/null || echo "")
COMFY=$(cat /tmp/cf_url_comfyui 2>/dev/null || echo "")
DASH=$(cat /tmp/cf_url_dashboard 2>/dev/null || echo "")
GRAFANA=$(cat /tmp/cf_url_grafana 2>/dev/null || echo "")
OBSIDIAN=$(cat /tmp/cf_url_obsidian 2>/dev/null || echo "")
IPMI=$(cat /tmp/cf_url_ipmi 2>/dev/null || echo "")

if [ -z "$CHAT" ] && [ -z "$COMFY" ] && [ -z "$DASH" ] && [ -z "$GRAFANA" ] && [ -z "$OBSIDIAN" ] && [ -z "$IPMI" ]; then
  echo "No tunnel URLs found — skipping update"
  exit 0
fi

cd $REPO

python3 - "$HTML" "$CHAT" "$COMFY" "$DASH" "$GRAFANA" "$OBSIDIAN" "$IPMI" <<'PY'
import sys, re

path = sys.argv[1]
urls = {
    'chat':      sys.argv[2],
    'comfyui':   sys.argv[3],
    'dashboard': sys.argv[4],
    'grafana':   sys.argv[5],
    'obsidian':  sys.argv[6],
    'ipmi':      sys.argv[7],
}

content = open(path).read()

# For each data-tunnel anchor, replace the href URL
def replace_tunnel(content, tunnel_name, new_url):
    if not new_url:
        return content
    # Match the anchor tag with this data-tunnel value and replace its href
    pattern = r'(<a\s[^>]*data-tunnel="' + tunnel_name + r'"[^>]*href=")https://[a-z0-9\-]+\.trycloudflare\.com(")'
    alt_pattern = r'(<a\s[^>]*href=")https://[a-z0-9\-]+\.trycloudflare\.com("[^>]*data-tunnel="' + tunnel_name + r'")'
    new, n = re.subn(pattern, r'\g<1>' + new_url + r'\g<2>', content)
    if n == 0:
        new, n = re.subn(alt_pattern, r'\g<1>' + new_url + r'\g<2>', content)
    if n > 0:
        old = re.search(r'https://[a-z0-9\-]+\.trycloudflare\.com', content)
        print(f"  [{tunnel_name}] → {new_url}")
    return new

for name, url in urls.items():
    content = replace_tunnel(content, name, url)

open(path, 'w').write(content)
PY

# Commit + push only if file changed
if ! git diff --quiet index.html; then
  git add index.html
  git commit -m "auto-update tunnel URLs ($(date '+%Y-%m-%d %H:%M'))"
  GIT_ASKPASS=echo git push origin main
  echo "✓ Pushed updated URLs to GitHub Pages"
else
  echo "✓ URLs unchanged — no push needed"
fi
