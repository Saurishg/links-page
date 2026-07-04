#!/bin/bash
# Regenerate the stable redirect pages (go/<name>/index.html) with current
# Cloudflare tunnel URLs and push. index.html cards link to ./go/<name>/ and
# never change — only the redirect targets rotate.
# Called automatically by start_tunnel.sh and check_tunnels.sh.
#
# To add a new tunnel: add its name to the TUNNELS list below and give
# index.html a card pointing at ./go/<name>/.
# Each name N expects /tmp/cf_url_N to contain the live URL (or be missing/empty).

set -e

# Prevent concurrent runs from corrupting the git repo
exec 200>/tmp/links-page-update.lock
flock -n 200 || { echo "Another update already running — skipping"; exit 0; }

REPO=/home/work/links-page

# Tunnels we know about. Add new tunnel names here — no other code changes needed.
TUNNELS=(chat comfyui dashboard grafana obsidian ipmi atinus comfyui_rocm mpt)

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

# index.html cards point at the stable ./go/<name>/ paths and never change.
# Regenerate the stable redirect pages: /go/<name>/ never changes, always
# forwards to the current tunnel URL. These are the URLs users bookmark.
for pair in "${PAIRS[@]}"; do
  name="${pair%%=*}"
  url="${pair#*=}"
  echo "  [$name] → $url"
  mkdir -p "$REPO/go/$name"
  cat > "$REPO/go/$name/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0;url=$url">
<title>$name — redirecting…</title>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#0b0f1a;color:#e2e8f0;font-family:Inter,system-ui,sans-serif}
  a{color:#818cf8}
</style>
</head>
<body>
<p>Connecting to <strong>$name</strong>… <a href="$url">tap here</a> if nothing happens.</p>
<script>location.replace("$url");</script>
</body>
</html>
EOF
done

# Commit if anything changed
git add index.html go/
if ! git diff --cached --quiet; then
  git commit -m "auto-update tunnel URLs ($(date '+%Y-%m-%d %H:%M'))"
else
  echo "✓ URLs unchanged"
fi

# Single publisher for this repo: push anything unpushed (our commit and/or
# trading.json commits from export_dashboard.py, which no longer pushes itself).
# One push per run = one Pages deployment = no more racing deploys.
if [ -n "$(git rev-list origin/main..main 2>/dev/null)" ]; then
  GIT_ASKPASS=echo git push origin main
  echo "✓ Pushed pending commits to GitHub Pages"
else
  echo "✓ Nothing to push"
fi
