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

# Self-heal a git repo corrupted by an unclean shutdown (0-byte loose objects /
# bad HEAD — happened 2026-07-18, froze the live page for hours). Detect it and
# rebuild .git from origin while keeping the working files, so a power loss can
# never again silently stop the page from updating.
ensure_git_healthy() {
  # Healthy = HEAD resolves to a real commit OBJECT (cat-file -e verifies the
  # object exists, unlike rev-parse which is happy with a dangling ref) AND no
  # loose object file has been truncated to 0 bytes.
  if git -C "$REPO" cat-file -e "HEAD^{commit}" 2>/dev/null \
     && ! find "$REPO/.git/objects" -type f -empty 2>/dev/null | grep -q .; then
    return 0   # healthy
  fi
  echo "⚠️  git repo corrupt — self-healing from origin"
  local url tmp
  url=$(git -C "$REPO" config --get remote.origin.url 2>/dev/null || echo "https://github.com/Saurishg/links-page.git")
  tmp=$(mktemp -d)
  if GIT_ASKPASS=echo git clone --quiet --bare "$url" "$tmp/g" 2>/dev/null; then
    rm -rf "$REPO/.git" && mv "$tmp/g" "$REPO/.git"
    git -C "$REPO" config core.bare false
    git -C "$REPO" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    GIT_ASKPASS=echo git -C "$REPO" fetch --quiet origin 2>/dev/null || true
    # --mixed: fix HEAD/index from origin but KEEP working files (urls.json,
    # go/, trading.json); the commit/push logic below then republishes them.
    git -C "$REPO" reset --mixed origin/main >/dev/null 2>&1 || true
    echo "✓ git restored from origin (working files preserved)"
  else
    echo "✗ self-heal clone failed — leaving repo untouched"
  fi
  rm -rf "$tmp"
}

# Tunnels we know about. Add new tunnel names here — no other code changes needed.
# ipmi dropped 2026-08-22 (SECURITY — public BMC; see check_tunnels.sh)
TUNNELS=(chat dashboard grafana obsidian)

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
ensure_git_healthy   # rebuild .git from origin if an unclean shutdown corrupted it

# index.html cards point at the stable ./go/<name>/ paths and never change.
# Write urls.json — the single source of truth the redirect pages fetch with
# a cache-busting query, so a rotation is picked up instantly even though
# GitHub Pages serves everything with cache-control: max-age=600.
python3 - "$REPO/urls.json" "${PAIRS[@]}" <<'PY'
import json, sys
urls = dict(p.split('=', 1) for p in sys.argv[2:])
# Preserve entries for tunnels with no URL on disk right now (e.g. right
# after a reboot) — last known beats missing
try:
    old = json.load(open(sys.argv[1]))
except Exception:
    old = {}
old.update(urls)
open(sys.argv[1], 'w').write(json.dumps(old, indent=1, sort_keys=True) + "\n")
PY

# Regenerate the stable redirect pages: /go/<name>/ never changes, always
# forwards to the current tunnel URL. These are the URLs users bookmark.
# JS fetches urls.json fresh (unique query defeats browser + CDN cache);
# the baked-in meta refresh is the no-JS / fetch-failure fallback.
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
<meta http-equiv="refresh" content="2;url=$url">
<title>$name — redirecting…</title>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#0b0f1a;color:#e2e8f0;font-family:Inter,system-ui,sans-serif}
  a{color:#818cf8}
</style>
</head>
<body>
<p>Connecting to <strong>$name</strong>… <a href="$url">tap here</a> if nothing happens.</p>
<script>
fetch("../../urls.json?" + Date.now(), {cache: "no-store"})
  .then(function(r){ return r.json(); })
  .then(function(j){ location.replace(j["$name"] || "$url"); })
  .catch(function(){ location.replace("$url"); });
</script>
</body>
</html>
EOF
done

# Commit if anything changed
git add index.html go/ urls.json
if ! git diff --cached --quiet; then
  git commit -m "auto-update tunnel URLs ($(date '+%Y-%m-%d %H:%M'))"
else
  echo "✓ URLs unchanged"
fi

# Single publisher for this repo: push anything unpushed (our commit and/or
# trading.json commits from export_dashboard.py, which no longer pushes itself).
# One push per run = one Pages deployment = no more racing deploys.
# Self-heal DIVERGED history. ensure_git_healthy() above only covers a *corrupt*
# repo; it does not cover a repo whose history has forked from origin. That
# happened 2026-08-14: the root disk was cloned at ~11:42, the old disk kept
# committing and pushing until 12:22, then the box rebooted onto the clone at
# 12:36 with a repo missing those 14 commits. Every later commit built on the
# stale base, so `git push` was rejected ("fetch first") for ~21h / 125 runs
# while the audit correctly screamed live-page-stale and could not fix itself.
#
# This box is the ONLY writer of this repo and every tracked file here is
# generated locally (urls.json, trading.json, index.html, go/*), so on
# divergence the local side is authoritative. `-s ours` keeps local content but
# records origin as a parent, so the push fast-forwards and origin's commits
# stay reachable in history — nothing is actually lost.
GIT_ASKPASS=echo git fetch --quiet origin 2>/dev/null || true
behind=$(git rev-list --count main..origin/main 2>/dev/null || echo 0)
if [ "${behind:-0}" -gt 0 ]; then
  echo "⚠️  history diverged — origin has $behind commit(s) we lack; reconciling (-s ours)"
  if git merge -s ours origin/main \
       -m "auto-reconcile diverged history ($(date '+%Y-%m-%d %H:%M'), origin was $behind ahead)"; then
    echo "✓ history reconciled — local content kept, origin history preserved"
  else
    echo "✗ auto-reconcile FAILED — manual git intervention needed"
  fi
fi

if [ -n "$(git rev-list origin/main..main 2>/dev/null)" ]; then
  GIT_ASKPASS=echo git push origin main
  echo "✓ Pushed pending commits to GitHub Pages"
else
  echo "✓ Nothing to push"
fi
