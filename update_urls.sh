#!/bin/bash
# Auto-update links-page index.html with current Cloudflare tunnel URLs.
# Uses data-tunnel="<name>" attributes on <a> tags for reliable replacement.
# Called automatically by start_tunnel.sh after tunnels come up.
#
# To add a new tunnel: just add its name to the TUNNELS list below.
# Each name N expects /tmp/cf_url_N to contain the live URL (or be missing/empty).

set -e

# Prevent concurrent runs from corrupting the git repo
exec 200>/tmp/links-page-update.lock
flock -n 200 || { echo "Another update already running — skipping"; exit 0; }

REPO=/home/work/links-page
HTML=$REPO/index.html

# Tunnels we know about. Add new tunnel names here — no other code changes needed.
TUNNELS=(chat comfyui dashboard grafana obsidian ipmi atinus)

# Build "name=url" pairs for each tunnel that has a URL on disk
PAIRS=()
ANY=0
for name in "${TUNNELS[@]}"; do
  url=$(cat "/tmp/cf_url_${name}" 2>/dev/null || echo "")
  if [ -n "$url" ]; then
    PAIRS+=("${name}=${url}")
    ANY=1
  fi
done

if [ "$ANY" -eq 0 ]; then
  echo "No tunnel URLs found — skipping update"
  exit 0
fi

cd "$REPO"

python3 - "$HTML" "${PAIRS[@]}" <<'PY'
import sys, re

path = sys.argv[1]
urls = dict(p.split('=', 1) for p in sys.argv[2:])

content = open(path).read()

# For each data-tunnel anchor, replace the href URL.
# Supports both attribute orders (data-tunnel before href, or after).
def replace_tunnel(content, tunnel_name, new_url):
    if not new_url:
        return content, 0
    pat_a = (r'(<a\s[^>]*data-tunnel="' + re.escape(tunnel_name) +
             r'"[^>]*href=")https://[a-z0-9\-]+\.trycloudflare\.com(")')
    pat_b = (r'(<a\s[^>]*href=")https://[a-z0-9\-]+\.trycloudflare\.com'
             r'("[^>]*data-tunnel="' + re.escape(tunnel_name) + r'")')
    new, n = re.subn(pat_a, r'\g<1>' + new_url + r'\g<2>', content)
    if n == 0:
        new, n = re.subn(pat_b, r'\g<1>' + new_url + r'\g<2>', content)
    return new, n

changed = 0
for name, url in urls.items():
    content, n = replace_tunnel(content, name, url)
    if n > 0:
        print(f"  [{name}] → {url}")
        changed += n
    else:
        print(f"  [{name}] (no anchor with data-tunnel='{name}' — skipped)", file=sys.stderr)

open(path, 'w').write(content)
print(f"✓ {changed} URL replacement(s) applied")
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
