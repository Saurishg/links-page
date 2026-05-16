#!/bin/bash
# Generate btc.html from the live BTC bot state files
# Reads /home/work/crypto-trading-bot/{live_state.json,pnl_log.json}
# Writes /home/work/links-page/btc.html and pushes to GitHub Pages

set -e

REPO=/home/work/links-page
BOT_DIR=/home/work/crypto-trading-bot

if [ ! -f "$BOT_DIR/live_state.json" ]; then
  echo "No bot state — skipping"
  exit 0
fi

cd $REPO
python3 - <<'PY'
import json, html
from pathlib import Path
from datetime import datetime, timezone

BOT = Path('/home/work/crypto-trading-bot')
OUT = Path('/home/work/links-page/btc.html')

state = json.loads((BOT / 'live_state.json').read_text())
try:
    pnl = json.loads((BOT / 'pnl_log.json').read_text())
except Exception:
    pnl = []

entry = state.get('entry_price') or 0
sl    = state.get('stop_loss') or 0
tp    = state.get('take_profit') or 0
qty   = state.get('qty') or 0
since = state.get('entered_at', '')
news  = state.get('news', {}) or {}
n_score = news.get('score', 0)
n_conf  = news.get('confidence', 0)
n_reason = news.get('reason', '')
headlines = news.get('headlines', [])[:6]

last_pnl = pnl[-1] if pnl else None
last_action = last_pnl.get('action', '-') if last_pnl else '-'
last_pnl_val = last_pnl.get('pnl_after_fees') if last_pnl else None

# Compute pct moves to TP/SL from entry
def pct(a, b):
    if not a or not b: return 0
    return ((b - a) / a) * 100

tp_pct = pct(entry, tp)
sl_pct = pct(entry, sl)

# Sentiment color
if n_score > 0.3:   sent_label, sent_color = 'Bullish', '#10b981'
elif n_score < -0.3: sent_label, sent_color = 'Bearish', '#ef4444'
else:                sent_label, sent_color = 'Mixed',   '#f59e0b'

# Format entered time
try:
    dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
    since_str = dt.strftime('%d %b %Y, %H:%M')
except Exception:
    since_str = since or '—'

# Format last update
try:
    last_news_ts = news.get('timestamp', '')
    nt = datetime.fromisoformat(last_news_ts.replace('Z', '+00:00'))
    news_age = nt.strftime('%d %b %H:%M UTC')
except Exception:
    news_age = '—'

now_str = datetime.now().strftime('%d %b %Y, %H:%M')

pnl_color = '#10b981' if (last_pnl_val or 0) >= 0 else '#ef4444'
pnl_str = f"{'+' if (last_pnl_val or 0) >= 0 else ''}${last_pnl_val:.2f}" if last_pnl_val is not None else '—'

headlines_html = ''.join(
    f'<li style="padding:8px 0; border-bottom:1px solid var(--border); font-size:12.5px; color:var(--text); line-height:1.5;">{html.escape(h)}</li>'
    for h in headlines
)

doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>BTC Bot Status — Saurishg</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet" />
  <style>
    *,*::before,*::after {{ box-sizing:border-box; margin:0; padding:0; }}
    :root {{
      --bg:#07090f; --card:#0f1629; --card2:#131d35; --border:#1c2a47;
      --indigo:#6366f1; --purple:#8b5cf6; --green:#10b981; --amber:#f59e0b;
      --cyan:#06b6d4; --red:#ef4444; --text:#f0f4ff; --muted:#64748b;
    }}
    body {{
      font-family:'Inter',sans-serif; background:var(--bg); color:var(--text);
      min-height:100vh; padding:32px 16px 48px;
      display:flex; align-items:flex-start; justify-content:center;
    }}
    body::before {{
      content:''; position:fixed; inset:0; pointer-events:none; z-index:0;
      background:
        radial-gradient(ellipse 60% 40% at 20% 10%, rgba(245,158,11,.12) 0%, transparent 60%),
        radial-gradient(ellipse 50% 35% at 80% 80%, rgba(99,102,241,.1) 0%, transparent 55%);
    }}
    .wrap {{ position:relative; z-index:1; width:100%; max-width:560px; }}
    .back {{
      display:inline-flex; align-items:center; gap:6px; padding:7px 12px;
      background:var(--card); border:1px solid var(--border); border-radius:8px;
      color:var(--muted); text-decoration:none; font-size:12px; font-weight:600;
      margin-bottom:24px; transition:color .15s;
    }}
    .back:hover {{ color:var(--text); }}
    .header {{ text-align:center; margin-bottom:28px; }}
    .header .emoji {{ font-size:36px; margin-bottom:8px; }}
    .header h1 {{
      font-size:24px; font-weight:800; letter-spacing:-.4px; margin-bottom:6px;
      background:linear-gradient(135deg,#f59e0b,#ef4444);
      -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;
    }}
    .header .sub {{ font-size:12.5px; color:var(--muted); }}
    .live-dot {{
      display:inline-flex; align-items:center; gap:6px; margin-top:10px;
      font-size:11px; color:var(--green); background:rgba(16,185,129,.1);
      border:1px solid rgba(16,185,129,.2); padding:4px 12px; border-radius:99px;
    }}
    .live-dot::before {{
      content:''; width:7px; height:7px; border-radius:50%; background:var(--green);
      animation:pulse 1.6s ease-in-out infinite;
    }}
    @keyframes pulse {{ 0%,100% {{opacity:1}} 50% {{opacity:.4}} }}
    .card {{
      background:var(--card); border:1px solid var(--border); border-radius:14px;
      padding:20px; margin-bottom:14px;
    }}
    .card-title {{
      font-size:11px; font-weight:700; letter-spacing:1.2px; text-transform:uppercase;
      color:var(--muted); margin-bottom:14px;
    }}
    .price-row {{ display:flex; justify-content:space-between; align-items:center; margin-bottom:10px; }}
    .live-price-label {{ font-size:12px; color:var(--muted); }}
    #live-price {{ font-size:24px; font-weight:800; letter-spacing:-.5px; }}
    #live-change {{ font-size:12px; font-weight:600; padding:3px 9px; border-radius:99px; }}
    .grid2 {{ display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-bottom:14px; }}
    .stat {{ background:var(--card2); border:1px solid var(--border); border-radius:10px; padding:12px 14px; }}
    .stat .label {{ font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.6px; margin-bottom:6px; }}
    .stat .value {{ font-size:17px; font-weight:800; letter-spacing:-.3px; }}
    .stat .extra {{ font-size:11px; color:var(--muted); margin-top:3px; }}
    .pnl-card {{ display:flex; justify-content:space-between; align-items:center; }}
    .sent-pill {{
      display:inline-block; padding:3px 10px; border-radius:99px;
      font-size:11px; font-weight:700;
      background:{sent_color}22; color:{sent_color};
    }}
    ul {{ list-style:none; }}
    .footer {{ text-align:center; font-size:11px; color:#334155; margin-top:20px; line-height:1.6; }}
    .footer a {{ color:#475569; text-decoration:none; }}
  </style>
</head>
<body>
  <div class="wrap">

    <a href="./" class="back">← back</a>

    <div class="header">
      <div class="emoji">🪙</div>
      <h1>BTC Trading Bot</h1>
      <div class="sub">Binance Demo · EMA5/13 cross + RSI + ATR + News sentiment</div>
      <div class="live-dot">Position open since {since_str}</div>
    </div>

    <!-- Live price -->
    <div class="card">
      <div class="card-title">Live BTC Price</div>
      <div class="price-row">
        <div>
          <div class="live-price-label">BTC/USDT (CoinGecko)</div>
          <div id="live-price">Loading…</div>
        </div>
        <div id="live-change">—</div>
      </div>
      <div style="font-size:11px;color:var(--muted);">Auto-refreshes every 30s</div>
    </div>

    <!-- Position -->
    <div class="card">
      <div class="card-title">Open Position</div>
      <div class="grid2">
        <div class="stat">
          <div class="label">Entry</div>
          <div class="value">${entry:,.2f}</div>
        </div>
        <div class="stat">
          <div class="label">Size</div>
          <div class="value">{qty:.4f} BTC</div>
          <div class="extra">${entry*qty:,.2f} notional</div>
        </div>
        <div class="stat">
          <div class="label">Take Profit</div>
          <div class="value" style="color:var(--green)">${tp:,.2f}</div>
          <div class="extra">+{tp_pct:.2f}%</div>
        </div>
        <div class="stat">
          <div class="label">Stop Loss</div>
          <div class="value" style="color:var(--red)">${sl:,.2f}</div>
          <div class="extra">{sl_pct:.2f}%</div>
        </div>
      </div>
      <div class="stat pnl-card">
        <div>
          <div class="label">Last Trade P&L (after fees)</div>
          <div class="value" style="color:{pnl_color}">{pnl_str}</div>
        </div>
        <div style="text-align:right;">
          <div class="label">Last Action</div>
          <div style="font-size:14px;font-weight:700;color:var(--text);margin-top:6px;">{last_action}</div>
        </div>
      </div>
    </div>

    <!-- News sentiment -->
    <div class="card">
      <div class="card-title">News Sentiment <span class="sent-pill">{sent_label} · {n_score:+.2f}</span></div>
      <div style="font-size:12.5px;color:var(--text);line-height:1.6;margin-bottom:14px;">{html.escape(n_reason)}</div>
      <div style="font-size:10px;color:var(--muted);margin-bottom:4px;letter-spacing:.5px;">RECENT HEADLINES</div>
      <ul>{headlines_html}</ul>
      <div style="font-size:10.5px;color:#334155;margin-top:10px;">Last news fetch: {news_age}</div>
    </div>

    <div class="footer">
      Generated {now_str} · Demo mode (no real money)<br/>
      <a href="https://github.com/Saurishg" target="_blank" rel="noopener">github.com/Saurishg</a>
    </div>

  </div>

  <script>
    async function fetchPrice() {{
      try {{
        const r = await fetch('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true');
        const d = await r.json();
        const p = d.bitcoin.usd;
        const c = d.bitcoin.usd_24h_change;
        document.getElementById('live-price').textContent = '$' + p.toLocaleString('en-US', {{minimumFractionDigits: 2, maximumFractionDigits: 2}});
        const ch = document.getElementById('live-change');
        ch.textContent = (c >= 0 ? '+' : '') + c.toFixed(2) + '%';
        ch.style.background = c >= 0 ? 'rgba(16,185,129,.12)' : 'rgba(239,68,68,.12)';
        ch.style.color = c >= 0 ? '#10b981' : '#ef4444';
      }} catch(e) {{
        document.getElementById('live-price').textContent = '—';
      }}
    }}
    fetchPrice();
    setInterval(fetchPrice, 30000);
  </script>
</body>
</html>
"""

OUT.write_text(doc)
print(f"✓ Generated btc.html ({len(doc)} chars)")
PY

# Commit + push only if file changed
if ! git diff --quiet btc.html 2>/dev/null || ! git ls-files --error-unmatch btc.html >/dev/null 2>&1; then
  git add btc.html
  git commit -m "auto-update BTC bot status ($(date '+%Y-%m-%d %H:%M'))" || exit 0
  GIT_ASKPASS=echo git push origin main
  echo "✓ Pushed BTC status update"
else
  echo "✓ BTC status unchanged"
fi
