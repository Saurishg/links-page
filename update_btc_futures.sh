#!/bin/bash
# Generate btc-futures.html from /home/work/btc_futures_15m/indicators.json
# Runs every 10 min via cron, commits/pushes to GitHub Pages.

set -e
REPO=/home/work/links-page
BOT_DIR=/home/work/btc_futures_15m

if [ ! -f "$BOT_DIR/indicators.json" ]; then
  echo "No indicators snapshot — skipping"; exit 0
fi

cd $REPO
python3 - <<'PY'
import json, html
from pathlib import Path
from datetime import datetime

BOT = Path('/home/work/btc_futures_15m')
OUT = Path('/home/work/links-page/btc-futures.html')

snap = json.loads((BOT / 'indicators.json').read_text())
try: pnl = json.loads((BOT / 'pnl.json').read_text())
except Exception: pnl = []
try: state = json.loads((BOT / 'state.json').read_text())
except Exception: state = {}

p           = snap['params']
direction   = snap['direction']
adx         = snap['adx']
rsi         = snap['rsi']
body_atr    = snap['body_atr']
vol_ratio   = snap['vol_ratio']
price       = snap['price']
donch_lo    = snap['donchian_low']
donch_hi    = snap['donchian_high']
has_pos     = snap['has_pos']
balance     = snap['balance']
equity      = snap['equity']

# Block reasons for SHORT entry
adx_in_range = p['SHORT_ADX_MIN'] <= adx < p['SHORT_ADX_MAX']
blocked = []
if direction != 'SHORT':           blocked.append(f"HTF dir={direction} (need SHORT)")
if price >= donch_lo:              blocked.append("no breakdown (price above Donchian low)")
if adx < p['SHORT_ADX_MIN']:       blocked.append(f"ADX={adx:.0f}<{p['SHORT_ADX_MIN']}")
elif adx >= p['SHORT_ADX_MAX']:    blocked.append(f"ADX={adx:.0f}>={p['SHORT_ADX_MAX']}")
if not snap['adx_rising']:         blocked.append("ADX falling")
if body_atr < p['SHORT_BODY_ATR_MIN']: blocked.append(f"body={body_atr:.2f}<{p['SHORT_BODY_ATR_MIN']}xATR")
if vol_ratio < p['SHORT_VOL_MULT']:    blocked.append(f"vol={vol_ratio:.2f}<{p['SHORT_VOL_MULT']}xMA")

# Trade stats
trades = [t for t in pnl if t.get('action') == 'CLOSE']
total_pnl = sum(t.get('pnl', 0) for t in trades)
wins = [t for t in trades if t.get('pnl', 0) > 0]
losses = [t for t in trades if t.get('pnl', 0) < 0]
n_t = len(trades)
wr = (len(wins)/n_t*100) if n_t else 0

last_5_open = [t for t in pnl if t.get('action') == 'OPEN'][-5:]

# Direction color
dir_color = '#10b981' if direction == 'LONG' else '#ef4444' if direction == 'SHORT' else '#64748b'

# Position display
pos_html = ''
if has_pos:
    side = snap['pos_side']; qty = snap['pos_qty']; ent = snap['pos_entry']
    upnl = snap['pos_unrealized']
    side_color = '#ef4444' if side == 'SHORT' else '#10b981'
    pnl_color = '#10b981' if upnl >= 0 else '#ef4444'
    pos_html = f"""
    <div class="card" style="border-color:{side_color}33;background:linear-gradient(180deg,{side_color}08,#0f1629);">
      <div class="card-title">🔥 LIVE POSITION</div>
      <div class="grid2">
        <div class="stat">
          <div class="label">Side</div>
          <div class="value" style="color:{side_color}">{side}</div>
        </div>
        <div class="stat">
          <div class="label">Size</div>
          <div class="value">{qty:.3f} BTC</div>
          <div class="extra">${qty*ent:,.0f} notional</div>
        </div>
        <div class="stat">
          <div class="label">Entry</div>
          <div class="value">${ent:,.0f}</div>
        </div>
        <div class="stat">
          <div class="label">Unrealized P&L</div>
          <div class="value" style="color:{pnl_color}">{'+' if upnl>=0 else ''}${upnl:,.2f}</div>
        </div>
      </div>
    </div>
    """
else:
    pos_html = f"""
    <div class="card">
      <div class="card-title">Position Status</div>
      <div style="display:flex;align-items:center;gap:14px;padding:8px 4px;">
        <div style="font-size:32px;">⏳</div>
        <div style="flex:1;">
          <div style="font-size:14px;font-weight:700;margin-bottom:3px;">Scanning for SHORT entry</div>
          <div style="font-size:12px;color:var(--muted);">No open position. Bot is short-only (v2 backtest config).</div>
        </div>
      </div>
      <div class="alert"><strong>Blocked by:</strong> {html.escape(', '.join(blocked)) if blocked else 'all filters passing — should fire next bar!'}</div>
    </div>
    """

# Stats card
stats_html = f"""
<div class="card">
  <div class="card-title">All-Time Stats <span class="status-tag" style="background:rgba(245,158,11,.1);color:var(--amber);border-color:rgba(245,158,11,.3);">{snap['env'].upper()}</span></div>
  <div class="grid2">
    <div class="stat"><div class="label">Equity</div><div class="value">${equity:,.2f}</div></div>
    <div class="stat"><div class="label">Balance</div><div class="value">${balance:,.2f}</div></div>
    <div class="stat"><div class="label">Closed Trades</div><div class="value">{n_t}</div></div>
    <div class="stat"><div class="label">Win Rate</div><div class="value" style="color:{'#10b981' if wr>=50 else '#ef4444'}">{wr:.1f}%</div></div>
    <div class="stat"><div class="label">Net P&L</div><div class="value" style="color:{'#10b981' if total_pnl>=0 else '#ef4444'}">{'+' if total_pnl>=0 else ''}${total_pnl:,.2f}</div></div>
    <div class="stat"><div class="label">Leverage</div><div class="value">{snap['leverage']}x</div></div>
  </div>
</div>
"""

# Strategy params card
params_html = f"""
<div class="card" style="border-color:rgba(99,102,241,.3);">
  <div class="card-title">🎯 Strategy V2 <span class="status-tag" style="background:rgba(16,185,129,.1);color:#10b981;border-color:rgba(16,185,129,.3);">backtest-validated</span></div>
  <div style="font-size:12.5px;color:var(--muted);line-height:1.6;margin-bottom:14px;">
    Short-only Donchian breakdown on {snap['tf_entry']} entry, {snap['tf_htf']} HTF trend. Strict ADX gate.<br/>
    <strong style="color:var(--text)">5y backtest:</strong> 25 trades · WR 96% · PF 3.03 · MaxDD 3.23% · 6/6 years profitable
  </div>
  <div class="grid2">
    <div class="stat"><div class="label">ADX Range</div><div class="value" style="font-size:14px;">{p['SHORT_ADX_MIN']}-{p['SHORT_ADX_MAX']}</div></div>
    <div class="stat"><div class="label">Body ≥</div><div class="value" style="font-size:14px;">{p['SHORT_BODY_ATR_MIN']}× ATR</div></div>
    <div class="stat"><div class="label">Volume ≥</div><div class="value" style="font-size:14px;">{p['SHORT_VOL_MULT']}× MA20</div></div>
    <div class="stat"><div class="label">R:R</div><div class="value" style="font-size:14px;">1:{p['ATR_TP_MULT']/p['ATR_SL_MULT']:.1f} (SL {p['ATR_SL_MULT']}× / TP {p['ATR_TP_MULT']}×)</div></div>
  </div>
</div>
"""

# Indicators card
adx_color = '#10b981' if adx_in_range else '#f59e0b' if adx >= 35 else '#ef4444'
indicators_html = f"""
<div class="card">
  <div class="card-title">Live Indicators <span style="font-size:10px;color:var(--muted);font-weight:500;text-transform:none;letter-spacing:0;">· {snap['ts'][:16].replace('T',' ')}</span></div>
  <div class="grid2">
    <div class="stat"><div class="label">Price</div><div class="value">${price:,.0f}</div></div>
    <div class="stat"><div class="label">HTF (4h) Direction</div><div class="value" style="color:{dir_color}">{direction}</div></div>
    <div class="stat"><div class="label">ADX (14) {('↑' if snap['adx_rising'] else '↓')}</div><div class="value" style="color:{adx_color}">{adx:.1f}</div><div class="extra">{'in range' if adx_in_range else 'out of range'}</div></div>
    <div class="stat"><div class="label">RSI (14)</div><div class="value">{rsi:.1f}</div></div>
    <div class="stat"><div class="label">Donchian Low (20)</div><div class="value" style="color:#ef4444">${donch_lo:,.0f}</div><div class="extra">break this to short</div></div>
    <div class="stat"><div class="label">Body / ATR</div><div class="value" style="color:{'#10b981' if body_atr >= p['SHORT_BODY_ATR_MIN'] else '#ef4444'}">{body_atr:.2f}</div></div>
    <div class="stat"><div class="label">Volume Ratio</div><div class="value" style="color:{'#10b981' if vol_ratio >= p['SHORT_VOL_MULT'] else '#ef4444'}">{vol_ratio:.2f}×</div></div>
    <div class="stat"><div class="label">ATR</div><div class="value">${snap['atr']:,.0f}</div></div>
  </div>
</div>
"""

doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>BTC Futures Bot (v2) — Saurishg</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet" />
  <style>
    *,*::before,*::after {{ box-sizing:border-box; margin:0; padding:0; }}
    :root {{
      --bg:#07090f; --card:#0f1629; --card2:#131d35; --border:#1c2a47;
      --green:#10b981; --amber:#f59e0b; --red:#ef4444; --text:#f0f4ff; --muted:#64748b;
    }}
    body {{ font-family:'Inter',sans-serif; background:var(--bg); color:var(--text); min-height:100vh; padding:32px 16px 48px; display:flex; align-items:flex-start; justify-content:center; }}
    body::before {{ content:''; position:fixed; inset:0; pointer-events:none; z-index:0;
      background: radial-gradient(ellipse 60% 40% at 20% 10%, rgba(239,68,68,.10) 0%, transparent 60%), radial-gradient(ellipse 50% 35% at 80% 80%, rgba(99,102,241,.1) 0%, transparent 55%); }}
    .wrap {{ position:relative; z-index:1; width:100%; max-width:580px; }}
    .back {{ display:inline-flex; align-items:center; gap:6px; padding:7px 12px; background:var(--card); border:1px solid var(--border); border-radius:8px; color:var(--muted); text-decoration:none; font-size:12px; font-weight:600; margin-bottom:24px; transition:color .15s; }}
    .back:hover {{ color:var(--text); }}
    .header {{ text-align:center; margin-bottom:24px; }}
    .header .emoji {{ font-size:36px; margin-bottom:8px; }}
    .header h1 {{ font-size:24px; font-weight:800; letter-spacing:-.4px; margin-bottom:6px; background:linear-gradient(135deg,#ef4444,#8b5cf6); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text; }}
    .header .sub {{ font-size:12.5px; color:var(--muted); }}
    .live-dot {{ display:inline-flex; align-items:center; gap:6px; margin-top:10px; font-size:11px; color:var(--green); background:rgba(16,185,129,.1); border:1px solid rgba(16,185,129,.2); padding:4px 12px; border-radius:99px; }}
    .live-dot::before {{ content:''; width:7px; height:7px; border-radius:50%; background:var(--green); animation:pulse 1.6s ease-in-out infinite; }}
    @keyframes pulse {{ 0%,100% {{opacity:1}} 50% {{opacity:.4}} }}
    .card {{ background:var(--card); border:1px solid var(--border); border-radius:14px; padding:20px; margin-bottom:14px; }}
    .card-title {{ font-size:11px; font-weight:700; letter-spacing:1.2px; text-transform:uppercase; color:var(--muted); margin-bottom:14px; display:flex; align-items:center; gap:10px; flex-wrap:wrap; }}
    .status-tag {{ font-size:10px; font-weight:700; padding:2px 8px; border-radius:99px; border:1px solid; letter-spacing:.4px; text-transform:none; }}
    .grid2 {{ display:grid; grid-template-columns:1fr 1fr; gap:10px; }}
    .stat {{ background:var(--card2); border:1px solid var(--border); border-radius:10px; padding:12px 14px; }}
    .stat .label {{ font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.6px; margin-bottom:6px; }}
    .stat .value {{ font-size:17px; font-weight:800; letter-spacing:-.3px; }}
    .stat .extra {{ font-size:11px; color:var(--muted); margin-top:3px; }}
    .alert {{ margin-top:14px; padding:10px 14px; border-radius:8px; background:rgba(245,158,11,.08); border:1px solid rgba(245,158,11,.2); font-size:12px; color:var(--amber); line-height:1.5; }}
    .footer {{ text-align:center; font-size:11px; color:#334155; margin-top:20px; line-height:1.6; }}
    .footer a {{ color:#475569; text-decoration:none; }}
  </style>
</head>
<body>
  <div class="wrap">
    <a href="./" class="back">← back</a>
    <div class="header">
      <div class="emoji">🚀</div>
      <h1>BTC Futures Bot</h1>
      <div class="sub">Binance Futures · {snap['symbol']} · {snap['tf_entry']} entry, {snap['tf_htf']} HTF · short-only · v2</div>
      <div class="live-dot">{snap['env'].upper()} · {snap['ts'][:16].replace('T',' ')}</div>
    </div>

    <!-- Live BTC price (client-side, CoinGecko) -->
    <div class="card">
      <div class="card-title">Live BTC Price</div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:4px;">BTC/USDT · CoinGecko</div>
          <div id="live-price" style="font-size:26px;font-weight:800;letter-spacing:-.5px;">Loading…</div>
        </div>
        <div id="live-change" style="font-size:12px;font-weight:600;padding:3px 9px;border-radius:99px;">—</div>
      </div>
    </div>

    {pos_html}
    {indicators_html}
    {params_html}
    {stats_html}

    <div class="footer">
      Generated {datetime.now().strftime('%d %b %Y, %H:%M IST')} · Binance Futures {snap['env']}<br/>
      Auto-refreshes every 10 min · <a href="https://github.com/Saurishg" target="_blank" rel="noopener">github.com/Saurishg</a>
    </div>
  </div>
  <script>
    async function fetchPrice() {{
      try {{
        const r = await fetch('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true');
        const d = await r.json();
        const p = d.bitcoin.usd, c = d.bitcoin.usd_24h_change;
        document.getElementById('live-price').textContent = '$' + p.toLocaleString('en-US', {{minimumFractionDigits: 2, maximumFractionDigits: 2}});
        const ch = document.getElementById('live-change');
        ch.textContent = (c >= 0 ? '+' : '') + c.toFixed(2) + '%';
        ch.style.background = c >= 0 ? 'rgba(16,185,129,.12)' : 'rgba(239,68,68,.12)';
        ch.style.color = c >= 0 ? '#10b981' : '#ef4444';
      }} catch(e) {{ document.getElementById('live-price').textContent = '—'; }}
    }}
    fetchPrice(); setInterval(fetchPrice, 30000);
  </script>
</body>
</html>
"""
OUT.write_text(doc)
print(f"✓ Generated btc-futures.html ({len(doc)} chars) · has_pos={has_pos}")
PY

if ! git diff --quiet btc-futures.html 2>/dev/null || ! git ls-files --error-unmatch btc-futures.html >/dev/null 2>&1; then
  git add btc-futures.html
  git commit -m "auto-update BTC futures bot status ($(date '+%Y-%m-%d %H:%M'))" || exit 0
  GIT_ASKPASS=echo git push origin main 2>&1 | tail -2
  echo "✓ Pushed BTC futures update"
else
  echo "✓ BTC futures unchanged"
fi
