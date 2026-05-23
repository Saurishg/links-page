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
try: pnl_log = json.loads((BOT / 'pnl.json').read_text())
except Exception: pnl_log = []

# ── portfolio-level fields ──────────────────────────────────────────────────
balance    = snap.get('balance', 0)
equity     = snap.get('equity', 0)
open_count = snap.get('open_count', 0)
env        = snap.get('env', 'testnet').upper()
tf_entry   = snap.get('tf_entry', '1h')
tf_htf     = snap.get('tf_htf', '4h')
leverage   = snap.get('leverage', 2)
ts         = snap.get('ts', '')[:16].replace('T', ' ')

# ── all-time trade stats (all symbols combined) ─────────────────────────────
trades    = [t for t in pnl_log if t.get('action') == 'CLOSE']
total_pnl = sum(t.get('pnl', 0) for t in trades)
wins      = [t for t in trades if t.get('pnl', 0) > 0]
n_t       = len(trades)
wr        = (len(wins) / n_t * 100) if n_t else 0
today_str = datetime.utcnow().strftime('%Y-%m-%d')
today_pnl = sum(t.get('pnl', 0) for t in trades if t.get('ts', '').startswith(today_str))

# ── per-symbol config (mirrors config.py SYMBOLS) ──────────────────────────
SYM_CFG = {
    'BTCUSDT': {
        'name': 'Bitcoin', 'coin': 'BTC', 'cg': 'bitcoin', 'color': '#f59e0b',
        'shorts_only': False,
        'short_adx_min': 44, 'short_adx_max': 68,
        'short_body_atr_min': 0.64, 'short_vol_mult': 1.16,
        'short_sl': 1.9, 'short_tp': 4.0,
        'long_adx_min': 40,  'long_adx_max': 55,
        'long_body_atr_min': 1.5, 'long_vol_mult': 1.2,
        'long_sl': 2.0, 'long_tp': 6.0,
        'bt_short': {'trades': 45, 'wr': 86.7, 'pf': 1.97, 'years': '5/5'},
        'bt_long':  {'trades': 20, 'wr': 80.0, 'pf': 2.13, 'years': '4/4'},
    },
    'ETHUSDT': {
        'name': 'Ethereum', 'coin': 'ETH', 'cg': 'ethereum', 'color': '#8b5cf6',
        'shorts_only': True,
        'short_adx_min': 45, 'short_adx_max': 55,
        'short_body_atr_min': 0.5, 'short_vol_mult': 1.0,
        'short_sl': 1.5, 'short_tp': 3.0,
        'bt_short': {'trades': 34, 'wr': 79.4, 'pf': 2.17, 'years': '4/5'},
    },
    'SOLUSDT': {
        'name': 'Solana', 'coin': 'SOL', 'cg': 'solana', 'color': '#06b6d4',
        'shorts_only': True,
        'short_adx_min': 50, 'short_adx_max': 55,
        'short_body_atr_min': 0.8, 'short_vol_mult': 1.0,
        'short_sl': 2.0, 'short_tp': 4.0,
        'bt_short': {'trades': 14, 'wr': 71.4, 'pf': 1.52, 'years': '3/4'},
    },
}

def fmt_pnl(v):
    c = '#10b981' if v >= 0 else '#ef4444'
    return f'<span style="color:{c}">{("+" if v >= 0 else "")}${v:,.2f}</span>'

def pct_color(v, thr=50):
    return '#10b981' if v >= thr else '#ef4444'

def dir_color(d):
    return '#10b981' if d == 'LONG' else '#ef4444' if d == 'SHORT' else '#64748b'

# ── build per-symbol cards ───────────────────────────────────────────────────
sym_cards = ''
sym_prices_js = ''  # js price placeholders

for sym, cfg in SYM_CFG.items():
    sd = snap.get('symbols', {}).get(sym, {})
    if not sd:
        continue

    price     = sd.get('price', 0)
    atr_val   = sd.get('atr', 0)
    adx       = sd.get('adx', 0)
    adx_up    = sd.get('adx_rising', False)
    rsi       = sd.get('rsi', 50)
    direction = sd.get('direction', 'NONE')
    donch_hi  = sd.get('donchian_high', 0)
    donch_lo  = sd.get('donchian_low', 0)
    body_atr  = sd.get('body_atr', 0)
    vol_ratio = sd.get('vol_ratio', 0)
    has_pos   = sd.get('has_pos', False)
    pos_side  = sd.get('pos_side', 'NONE')
    pos_qty   = sd.get('pos_qty', 0.0)
    pos_entry = sd.get('pos_entry', 0.0)
    upnl      = sd.get('pos_unrealized', 0)
    long_sig  = sd.get('long_signal', False)
    short_sig = sd.get('short_signal', False)

    col = cfg['color']
    coin = cfg['coin']
    cg_id = cfg['cg']
    price_id = f'price-{sym.lower()}'
    change_id = f'change-{sym.lower()}'

    # blocked reasons for each active edge
    blocked_short = []
    if direction != 'SHORT':
        blocked_short.append(f"HTF={direction} (need SHORT)")
    if price >= donch_lo:
        blocked_short.append("no breakdown")
    sadx_ok = cfg['short_adx_min'] <= adx < cfg['short_adx_max']
    if not sadx_ok:
        blocked_short.append(f"ADX={adx:.0f} (need {cfg['short_adx_min']}-{cfg['short_adx_max']})")
    if not adx_up:
        blocked_short.append("ADX falling")
    if body_atr < cfg['short_body_atr_min']:
        blocked_short.append(f"body={body_atr:.2f}<{cfg['short_body_atr_min']}×ATR")
    if vol_ratio < cfg['short_vol_mult']:
        blocked_short.append(f"vol={vol_ratio:.2f}<{cfg['short_vol_mult']}×")

    blocked_long = []
    if not cfg['shorts_only']:
        if direction != 'LONG':
            blocked_long.append(f"HTF={direction} (need LONG)")
        if price <= donch_hi:
            blocked_long.append("no breakout")
        ladx_ok = cfg['long_adx_min'] <= adx < cfg['long_adx_max']
        if not ladx_ok:
            blocked_long.append(f"ADX={adx:.0f} (need {cfg['long_adx_min']}-{cfg['long_adx_max']})")
        if not adx_up:
            blocked_long.append("ADX falling")
        if body_atr < cfg['long_body_atr_min']:
            blocked_long.append(f"body={body_atr:.2f}<{cfg['long_body_atr_min']}×ATR")
        if vol_ratio < cfg['long_vol_mult']:
            blocked_long.append(f"vol={vol_ratio:.2f}<{cfg['long_vol_mult']}×")

    # signal badge
    if short_sig:
        sig_badge = f'<span class="sig-badge" style="background:rgba(239,68,68,.15);color:#ef4444;border-color:rgba(239,68,68,.3);">⚡ SHORT SIGNAL</span>'
    elif long_sig:
        sig_badge = f'<span class="sig-badge" style="background:rgba(16,185,129,.15);color:#10b981;border-color:rgba(16,185,129,.3);">⚡ LONG SIGNAL</span>'
    else:
        sig_badge = f'<span class="sig-badge" style="background:rgba(100,116,139,.1);color:#64748b;border-color:rgba(100,116,139,.2);">Scanning…</span>'

    # position block
    if has_pos and pos_side != 'NONE':
        pc = '#ef4444' if pos_side == 'SHORT' else '#10b981'
        upnl_c = '#10b981' if upnl >= 0 else '#ef4444'
        notional = pos_qty * pos_entry
        pos_block = f"""
      <div class="pos-live" style="border-color:{pc}44;background:linear-gradient(180deg,{pc}08,transparent);">
        <div style="font-size:10px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:{pc};margin-bottom:10px;">🔥 Live Position</div>
        <div class="grid2" style="gap:8px;">
          <div class="mini-stat"><div class="label">Side</div><div class="value" style="color:{pc}">{pos_side}</div></div>
          <div class="mini-stat"><div class="label">Size</div><div class="value">{pos_qty:.3f} {coin}</div><div class="extra">${notional:,.0f} notional</div></div>
          <div class="mini-stat"><div class="label">Entry</div><div class="value">${pos_entry:,.2f}</div></div>
          <div class="mini-stat"><div class="label">Unrealized P&amp;L</div><div class="value" style="color:{upnl_c}">{('+' if upnl>=0 else '')}${upnl:,.2f}</div></div>
        </div>
      </div>"""
    else:
        short_block_txt = html.escape(', '.join(blocked_short)) if blocked_short else 'all SHORT filters passing!'
        if cfg['shorts_only']:
            long_block_html = ''
        else:
            long_block_txt = html.escape(', '.join(blocked_long)) if blocked_long else 'all LONG filters passing!'
            long_block_html = f'<div style="margin-top:6px;font-size:11px;color:#64748b;"><strong>LONG blocked:</strong> {long_block_txt}</div>'
        pos_block = f"""
      <div class="alert" style="margin-top:0;">
        <strong>SHORT blocked:</strong> {short_block_txt}{long_block_html}
      </div>"""

    # adx color
    adx_short_ok = cfg['short_adx_min'] <= adx < cfg['short_adx_max']
    adx_c = '#10b981' if adx_short_ok else '#f59e0b' if adx >= cfg['short_adx_min'] - 5 else '#ef4444'

    # backtest footnote
    bt_s = cfg.get('bt_short', {})
    bt_l = cfg.get('bt_long', {})
    if bt_l:
        bt_txt = f"5y SHORT: {bt_s['trades']}t · WR {bt_s['wr']}% · PF {bt_s['pf']} ({bt_s['years']} yrs) &nbsp;|&nbsp; 5y LONG: {bt_l['trades']}t · WR {bt_l['wr']}% · PF {bt_l['pf']} ({bt_l['years']} yrs)"
    else:
        bt_txt = f"5y SHORT: {bt_s['trades']}t · WR {bt_s['wr']}% · PF {bt_s['pf']} ({bt_s['years']} yrs)"

    # sides label
    sides_label = 'DUAL EDGE' if not cfg['shorts_only'] else 'SHORT ONLY'
    sides_color = '#8b5cf6' if not cfg['shorts_only'] else '#ef4444'

    sym_cards += f"""
    <!-- {sym} -->
    <div class="card" style="border-color:{col}33;">
      <div class="card-title" style="margin-bottom:10px;">
        <span style="color:{col};font-size:13px;">●</span> {cfg['name']} ({sym})
        <span class="status-tag" style="background:{sides_color}18;color:{sides_color};border-color:{sides_color}44;">{sides_label}</span>
        {sig_badge}
      </div>
      <!-- live price row -->
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;padding:10px 14px;background:var(--card2);border:1px solid var(--border);border-radius:10px;">
        <div>
          <div style="font-size:10px;color:var(--muted);margin-bottom:3px;">{coin}/USDT · CoinGecko live</div>
          <div id="{price_id}" style="font-size:22px;font-weight:800;letter-spacing:-.4px;">Loading…</div>
        </div>
        <div id="{change_id}" style="font-size:12px;font-weight:600;padding:3px 9px;border-radius:99px;background:rgba(100,116,139,.1);color:#64748b;">—</div>
      </div>
      {pos_block}
      <div class="grid2" style="margin-top:10px;gap:8px;">
        <div class="mini-stat"><div class="label">HTF (4h) Dir</div><div class="value" style="color:{dir_color(direction)}">{direction}</div></div>
        <div class="mini-stat"><div class="label">ADX (14) {('↑' if adx_up else '↓')}</div><div class="value" style="color:{adx_c}">{adx:.1f}</div></div>
        <div class="mini-stat"><div class="label">RSI (14)</div><div class="value">{rsi:.1f}</div></div>
        <div class="mini-stat"><div class="label">ATR</div><div class="value">${atr_val:,.2f}</div></div>
        <div class="mini-stat"><div class="label">Body / ATR</div><div class="value" style="color:{'#10b981' if body_atr >= cfg['short_body_atr_min'] else '#ef4444'}">{body_atr:.2f}</div></div>
        <div class="mini-stat"><div class="label">Vol Ratio</div><div class="value" style="color:{'#10b981' if vol_ratio >= cfg['short_vol_mult'] else '#ef4444'}">{vol_ratio:.2f}×</div></div>
        <div class="mini-stat"><div class="label">Donchian Hi</div><div class="value" style="color:#10b981">${donch_hi:,.2f}</div></div>
        <div class="mini-stat"><div class="label">Donchian Lo</div><div class="value" style="color:#ef4444">${donch_lo:,.2f}</div></div>
      </div>
      <div style="margin-top:10px;font-size:10.5px;color:#475569;line-height:1.5;">{bt_txt}</div>
    </div>
"""

# ── strategy params table ────────────────────────────────────────────────────
def row(sym, cfg):
    has_long = not cfg['shorts_only']
    long_cell = f"ADX {cfg['long_adx_min']}-{cfg['long_adx_max']} · body≥{cfg['long_body_atr_min']}×ATR · vol≥{cfg['long_vol_mult']}× · SL {cfg['long_sl']}× TP {cfg['long_tp']}×" if has_long else '—'
    return f"""<tr>
      <td style="color:{cfg['color']};font-weight:700;">{sym}</td>
      <td>ADX {cfg['short_adx_min']}-{cfg['short_adx_max']} · body≥{cfg['short_body_atr_min']}×ATR · vol≥{cfg['short_vol_mult']}× · SL {cfg['short_sl']}× TP {cfg['short_tp']}×</td>
      <td>{long_cell}</td>
    </tr>"""

params_table_rows = '\n'.join(row(s, c) for s, c in SYM_CFG.items())

# ── 5y backtest table ────────────────────────────────────────────────────────
bt_rows = ''
for sym, cfg in SYM_CFG.items():
    bt_s = cfg.get('bt_short', {})
    bt_l = cfg.get('bt_long', {})
    if bt_s:
        bt_rows += f"""<tr>
          <td style="color:{cfg['color']};font-weight:700;">{sym}</td>
          <td><span style="color:#ef4444">SHORT</span></td>
          <td>{bt_s['trades']}</td>
          <td style="color:{'#10b981' if bt_s['wr']>=70 else '#f59e0b'}">{bt_s['wr']}%</td>
          <td style="color:{'#10b981' if bt_s['pf']>=1.5 else '#f59e0b'}">{bt_s['pf']}</td>
          <td>{bt_s['years']}</td>
        </tr>"""
    if bt_l:
        bt_rows += f"""<tr>
          <td style="color:{cfg['color']};font-weight:700;">{sym}</td>
          <td><span style="color:#10b981">LONG</span></td>
          <td>{bt_l['trades']}</td>
          <td style="color:{'#10b981' if bt_l['wr']>=70 else '#f59e0b'}">{bt_l['wr']}%</td>
          <td style="color:{'#10b981' if bt_l['pf']>=1.5 else '#f59e0b'}">{bt_l['pf']}</td>
          <td>{bt_l['years']}</td>
        </tr>"""

# ── JavaScript for live prices ───────────────────────────────────────────────
cg_ids = ','.join(cfg['cg'] for cfg in SYM_CFG.values())
sym_price_map = json.dumps({cfg['cg']: sym.lower() for sym, cfg in SYM_CFG.items()})

doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Crypto Futures Bot (v6) — Saurishg</title>
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
      background: radial-gradient(ellipse 60% 40% at 20% 10%, rgba(245,158,11,.08) 0%, transparent 60%), radial-gradient(ellipse 50% 35% at 80% 80%, rgba(99,102,241,.1) 0%, transparent 55%); }}
    .wrap {{ position:relative; z-index:1; width:100%; max-width:640px; }}
    .back {{ display:inline-flex; align-items:center; gap:6px; padding:7px 12px; background:var(--card); border:1px solid var(--border); border-radius:8px; color:var(--muted); text-decoration:none; font-size:12px; font-weight:600; margin-bottom:24px; transition:color .15s; }}
    .back:hover {{ color:var(--text); }}
    .header {{ text-align:center; margin-bottom:24px; }}
    .header h1 {{ font-size:24px; font-weight:800; letter-spacing:-.4px; margin-bottom:6px; background:linear-gradient(135deg,#f59e0b,#8b5cf6,#06b6d4); -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text; }}
    .header .sub {{ font-size:12.5px; color:var(--muted); }}
    .live-dot {{ display:inline-flex; align-items:center; gap:6px; margin-top:10px; font-size:11px; color:var(--green); background:rgba(16,185,129,.1); border:1px solid rgba(16,185,129,.2); padding:4px 12px; border-radius:99px; }}
    .live-dot::before {{ content:''; width:7px; height:7px; border-radius:50%; background:var(--green); animation:pulse 1.6s ease-in-out infinite; }}
    @keyframes pulse {{ 0%,100% {{opacity:1}} 50% {{opacity:.4}} }}
    .card {{ background:var(--card); border:1px solid var(--border); border-radius:14px; padding:18px; margin-bottom:14px; }}
    .card-title {{ font-size:11px; font-weight:700; letter-spacing:1.2px; text-transform:uppercase; color:var(--muted); margin-bottom:14px; display:flex; align-items:center; gap:8px; flex-wrap:wrap; }}
    .status-tag {{ font-size:10px; font-weight:700; padding:2px 8px; border-radius:99px; border:1px solid; letter-spacing:.4px; text-transform:none; }}
    .sig-badge {{ font-size:10px; font-weight:700; padding:2px 10px; border-radius:99px; border:1px solid; letter-spacing:.3px; }}
    .grid2 {{ display:grid; grid-template-columns:1fr 1fr; gap:10px; }}
    .grid4 {{ display:grid; grid-template-columns:repeat(4,1fr); gap:8px; }}
    .stat,.mini-stat {{ background:var(--card2); border:1px solid var(--border); border-radius:10px; padding:12px 14px; }}
    .mini-stat {{ padding:9px 11px; }}
    .label {{ font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.6px; margin-bottom:5px; }}
    .value {{ font-size:17px; font-weight:800; letter-spacing:-.3px; }}
    .mini-stat .value {{ font-size:14px; }}
    .extra {{ font-size:11px; color:var(--muted); margin-top:3px; }}
    .alert {{ padding:10px 14px; border-radius:8px; background:rgba(245,158,11,.08); border:1px solid rgba(245,158,11,.2); font-size:11.5px; color:var(--amber); line-height:1.5; }}
    .pos-live {{ border:1px solid; border-radius:10px; padding:14px; margin-bottom:0; }}
    table.params {{ width:100%; border-collapse:collapse; font-size:11.5px; }}
    table.params th {{ font-size:10px; font-weight:700; letter-spacing:.8px; text-transform:uppercase; color:var(--muted); padding:6px 8px; border-bottom:1px solid var(--border); text-align:left; }}
    table.params td {{ padding:8px 8px; border-bottom:1px solid #0c1526; line-height:1.5; color:var(--text); }}
    table.params tr:last-child td {{ border-bottom:none; }}
    .section-hdr {{ font-size:10px; font-weight:700; letter-spacing:1.2px; text-transform:uppercase; color:var(--muted); margin-bottom:10px; }}
    .footer {{ text-align:center; font-size:11px; color:#334155; margin-top:20px; line-height:1.6; }}
    .footer a {{ color:#475569; text-decoration:none; }}
  </style>
</head>
<body>
  <div class="wrap">
    <a href="./" class="back">← back</a>
    <div class="header">
      <div style="font-size:36px;margin-bottom:8px;">🚀</div>
      <h1>Crypto Futures Bot v6</h1>
      <div class="sub">Binance Futures · BTC / ETH / SOL · {tf_entry} entry, {tf_htf} HTF · dual-edge + short-only · multi-symbol</div>
      <div class="live-dot">{env} · {ts}</div>
    </div>

    <!-- Portfolio overview -->
    <div class="card">
      <div class="card-title">Portfolio Overview
        <span class="status-tag" style="background:rgba(245,158,11,.1);color:var(--amber);border-color:rgba(245,158,11,.3);">{env}</span>
      </div>
      <div class="grid4">
        <div class="mini-stat"><div class="label">Balance</div><div class="value">${balance:,.0f}</div></div>
        <div class="mini-stat"><div class="label">Equity</div><div class="value">${equity:,.0f}</div></div>
        <div class="mini-stat"><div class="label">Open</div><div class="value">{open_count}/2</div></div>
        <div class="mini-stat"><div class="label">Leverage</div><div class="value">{leverage}×</div></div>
        <div class="mini-stat"><div class="label">Closed Trades</div><div class="value">{n_t}</div></div>
        <div class="mini-stat"><div class="label">Win Rate</div><div class="value" style="color:{pct_color(wr)}">{wr:.1f}%</div></div>
        <div class="mini-stat"><div class="label">Net P&amp;L</div><div class="value" style="color:{'#10b981' if total_pnl>=0 else '#ef4444'}">{('+' if total_pnl>=0 else '')}${total_pnl:,.2f}</div></div>
        <div class="mini-stat"><div class="label">Today P&amp;L</div><div class="value" style="color:{'#10b981' if today_pnl>=0 else '#ef4444'}">{('+' if today_pnl>=0 else '')}${today_pnl:,.2f}</div></div>
      </div>
    </div>

    {sym_cards}

    <!-- Strategy params -->
    <div class="card" style="border-color:rgba(99,102,241,.3);">
      <div class="card-title">🎯 Strategy v6 — Parameters
        <span class="status-tag" style="background:rgba(16,185,129,.1);color:#10b981;border-color:rgba(16,185,129,.3);">5y backtest-validated</span>
      </div>
      <div style="font-size:12px;color:var(--muted);margin-bottom:14px;line-height:1.6;">
        Donchian channel breakout on <strong style="color:var(--text)">{tf_entry}</strong> with <strong style="color:var(--text)">{tf_htf}</strong> EMA50/200 trend gate.
        Filters: ADX range + rising · body size in ATR units · volume vs 20-bar MA.
        Exits: fixed ATR stop-loss · take-profit · scale-out 50% at 1×ATR · Chandelier trailing from 1.5×ATR.
        Adaptive re-tune every 7 days on a 6-month rolling window (blended 80% anchor / 20% recent).
      </div>
      <table class="params">
        <thead><tr><th>Symbol</th><th>SHORT edge</th><th>LONG edge</th></tr></thead>
        <tbody>{params_table_rows}</tbody>
      </table>
    </div>

    <!-- 5y backtest summary -->
    <div class="card">
      <div class="card-title">📊 5-Year Backtest Results</div>
      <div style="font-size:11.5px;color:var(--muted);margin-bottom:12px;">1,728+ parameter configs swept per symbol · 1H entry + 4H HTF · 2020-2025</div>
      <table class="params">
        <thead><tr><th>Symbol</th><th>Edge</th><th>Trades</th><th>Win Rate</th><th>Profit Factor</th><th>Profitable Yrs</th></tr></thead>
        <tbody>{bt_rows}</tbody>
      </table>
    </div>

    <div class="footer">
      Generated {datetime.now().strftime('%d %b %Y, %H:%M IST')} · Binance Futures {env.lower()}<br/>
      Auto-refreshes every 10 min · <a href="https://github.com/Saurishg" target="_blank" rel="noopener">github.com/Saurishg</a>
    </div>
  </div>
  <script>
    const SYM_MAP = {sym_price_map};
    async function fetchPrices() {{
      try {{
        const r = await fetch('https://api.coingecko.com/api/v3/simple/price?ids={cg_ids}&vs_currencies=usd&include_24hr_change=true');
        const d = await r.json();
        for (const [cgId, symLower] of Object.entries(SYM_MAP)) {{
          if (!d[cgId]) continue;
          const p = d[cgId].usd, c = d[cgId].usd_24h_change;
          const priceEl = document.getElementById('price-' + symLower);
          const changeEl = document.getElementById('change-' + symLower);
          if (priceEl) priceEl.textContent = '$' + p.toLocaleString('en-US', {{minimumFractionDigits: 2, maximumFractionDigits: 2}});
          if (changeEl) {{
            changeEl.textContent = (c >= 0 ? '+' : '') + c.toFixed(2) + '%';
            changeEl.style.background = c >= 0 ? 'rgba(16,185,129,.12)' : 'rgba(239,68,68,.12)';
            changeEl.style.color = c >= 0 ? '#10b981' : '#ef4444';
          }}
        }}
      }} catch(e) {{ console.warn('CoinGecko fetch failed', e); }}
    }}
    fetchPrices(); setInterval(fetchPrices, 30000);
  </script>
</body>
</html>
"""
OUT.write_text(doc)
print(f"✓ Generated btc-futures.html ({len(doc)} chars) · open_count={open_count}")
PY

if ! git diff --quiet btc-futures.html 2>/dev/null || ! git ls-files --error-unmatch btc-futures.html >/dev/null 2>&1; then
  git add btc-futures.html
  git commit -m "auto-update crypto futures bot status ($(date '+%Y-%m-%d %H:%M'))" || exit 0
  GIT_ASKPASS=echo git push origin main 2>&1 | tail -2
  echo "✓ Pushed crypto futures update"
else
  echo "✓ Crypto futures unchanged"
fi
