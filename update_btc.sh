#!/bin/bash
# Generate btc.html from the live BTC bot state files
# Reads /home/work/crypto-trading-bot/{live_state.json,pnl_log.json,bot.log}
# Writes /home/work/links-page/btc.html and pushes to GitHub Pages

set -e

REPO=/home/work/links-page
BOT_DIR=/home/work/crypto-trading-bot

if [ ! -f "$BOT_DIR/live_state.json" ]; then
  echo "No bot state — skipping"
  exit 0
fi

cd $REPO

# Capture the current dashboard tunnel URL so btc.html can hit /api/bot-status live
DASH_URL=$(cat /tmp/cf_url_dashboard 2>/dev/null || echo "")
export DASH_URL

python3 - <<'PY'
import json, html, re, subprocess, os
from pathlib import Path
from datetime import datetime, timezone

BOT = Path('/home/work/crypto-trading-bot')
OUT = Path('/home/work/links-page/btc.html')
DASH_URL = os.environ.get('DASH_URL', '')

state = json.loads((BOT / 'live_state.json').read_text())
try:
    pnl = json.loads((BOT / 'pnl_log.json').read_text())
except Exception:
    pnl = []
try:
    indicators = json.loads((BOT / 'indicators.json').read_text())
except Exception:
    indicators = {}

# Read recent log lines from PM2 stdout
log_path = Path('/home/work/.pm2/logs/btc-live-out.log')
last_log_lines = []
try:
    out = subprocess.check_output(['tail', '-25', str(log_path)], text=True)
    last_log_lines = out.strip().split('\n')
except Exception:
    pass

# Parse latest cycle info from log
latest_price = latest_rsi = latest_macd = latest_news = latest_action = None
latest_ts = None
for ln in reversed(last_log_lines):
    m = re.search(r'Price: \$([0-9,]+\.[0-9]+).*RSI: ([0-9.]+).*MACD: (\W+).*News: \W+\(([+\-0-9.]+)\)', ln)
    if m and not latest_price:
        latest_price = m.group(1)
        latest_rsi = float(m.group(2))
        latest_macd = '▲ Bullish' if '▲' in m.group(3) else '▼ Bearish'
        latest_news = float(m.group(4))
    if 'Waiting:' in ln and not latest_action:
        wm = re.search(r'Waiting: (.+?)\s*$', ln)
        if wm:
            latest_action = wm.group(1)
    if 'BTC Live Bot running' in ln and not latest_ts:
        tm = re.search(r'\[([0-9\-: ]+)\]', ln)
        if tm: latest_ts = tm.group(1)

# Position state
has_position = bool(state.get('entry_price'))
entry = state.get('entry_price', 0)
sl    = state.get('stop_loss', 0)
tp    = state.get('take_profit', 0)
qty   = state.get('qty', 0)
since = state.get('entered_at', '')
news  = state.get('news', {}) or {}
n_score = news.get('score', latest_news if latest_news is not None else 0)
n_reason = news.get('reason', '')
headlines = news.get('headlines', [])[:6]

# Bot is alive if we have a recent log line (within last 10 minutes)
bot_alive = bool(latest_ts)

# PnL stats
total_trades = len(pnl)
total_pnl = sum(t.get('pnl_after_fees', 0) or 0 for t in pnl)
wins = sum(1 for t in pnl if (t.get('pnl_after_fees') or 0) > 0)
losses = sum(1 for t in pnl if (t.get('pnl_after_fees') or 0) < 0)
win_rate = (wins / max(wins + losses, 1)) * 100

last_trade = pnl[-1] if pnl else None

# Sentiment
if (n_score or 0) > 0.3:    sent_label, sent_color = 'Bullish', '#10b981'
elif (n_score or 0) < -0.3:  sent_label, sent_color = 'Bearish', '#ef4444'
else:                         sent_label, sent_color = 'Mixed',   '#f59e0b'

# RSI label
if latest_rsi is None:
    rsi_label, rsi_color = '—', '#64748b'
elif latest_rsi < 30:    rsi_label, rsi_color = 'Oversold',  '#10b981'
elif latest_rsi > 70:    rsi_label, rsi_color = 'Overbought', '#ef4444'
else:                    rsi_label, rsi_color = 'Neutral',   '#64748b'

now_str = datetime.now().strftime('%d %b %Y, %H:%M IST')

# Position block (only if has_position)
position_html = ''
if has_position:
    try:
        dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
        since_str = dt.strftime('%d %b %Y, %H:%M')
    except Exception:
        since_str = since or '—'

    def pct(a, b):
        if not a or not b: return 0
        return ((b - a) / a) * 100
    tp_pct = pct(entry, tp)
    sl_pct = pct(entry, sl)

    position_html = f"""
    <div class="card">
      <div class="card-title">Open Position <span class="status-tag" style="background:rgba(99,102,241,.1);color:#a5b4fc;border-color:rgba(99,102,241,.3);">Active since {since_str}</span></div>
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
          <div class="value" style="color:#10b981">${tp:,.2f}</div>
          <div class="extra">+{tp_pct:.2f}%</div>
        </div>
        <div class="stat">
          <div class="label">Stop Loss</div>
          <div class="value" style="color:#ef4444">${sl:,.2f}</div>
          <div class="extra">{sl_pct:.2f}%</div>
        </div>
      </div>
    </div>
    """
else:
    position_html = f"""
    <div class="card">
      <div class="card-title">Position Status</div>
      <div style="display:flex;align-items:center;gap:14px;padding:8px 4px;">
        <div style="font-size:32px;">⏳</div>
        <div style="flex:1;">
          <div style="font-size:14px;font-weight:700;margin-bottom:3px;">Scanning for entry</div>
          <div style="font-size:12px;color:var(--muted);line-height:1.5;">No open position. Bot is waiting for a BUY signal.</div>
        </div>
      </div>
      {'<div class="alert"><strong>Currently blocked by:</strong> ' + html.escape(latest_action) + '</div>' if latest_action else ''}
    </div>
    """

# Stats card
stats_html = f"""
<div class="card">
  <div class="card-title">All-Time Stats</div>
  <div class="grid2">
    <div class="stat">
      <div class="label">Total Trades</div>
      <div class="value">{total_trades}</div>
    </div>
    <div class="stat">
      <div class="label">Win Rate</div>
      <div class="value" style="color:{'#10b981' if win_rate >= 50 else '#ef4444'}">{win_rate:.1f}%</div>
      <div class="extra">{wins}W / {losses}L</div>
    </div>
    <div class="stat">
      <div class="label">Net P&L (after fees)</div>
      <div class="value" style="color:{'#10b981' if total_pnl >= 0 else '#ef4444'}">{'+' if total_pnl >= 0 else ''}${total_pnl:,.2f}</div>
    </div>
    <div class="stat">
      <div class="label">Last Trade</div>
      <div class="value">{last_trade.get('action','—') if last_trade else '—'}</div>
      <div class="extra">{('$%.2f' % (last_trade.get('pnl_after_fees') or 0)) if last_trade else ''}</div>
    </div>
  </div>
</div>
"""

# ── Indicator helpers
ema21  = indicators.get('ema21')
ema55  = indicators.get('ema55')
ema200 = indicators.get('ema200')
atr    = indicators.get('atr')
macd_v = indicators.get('macd')
macd_s = indicators.get('macd_sig')
bot_price = indicators.get('price') or (float(latest_price.replace(',','')) if latest_price else 0)

# ── Pro indicators
adx_v  = indicators.get('adx', 0)
pdi    = indicators.get('pdi', 0)
ndi    = indicators.get('ndi', 0)
bb_pb  = indicators.get('bb_pct_b', 0.5)
bb_w   = indicators.get('bb_width', 0)
bb_up  = indicators.get('bb_upper', 0)
bb_lo  = indicators.get('bb_lower', 0)
vwap_v = indicators.get('vwap', 0)
srsi   = indicators.get('stoch_rsi', 50)
obv_t  = indicators.get('obv_trend', 'neutral')

# ADX interpretation
if adx_v >= 40:    adx_label, adx_color = 'Very strong trend', '#10b981'
elif adx_v >= 25:  adx_label, adx_color = 'Trending', '#84cc16'
elif adx_v >= 20:  adx_label, adx_color = 'Developing trend', '#f59e0b'
else:              adx_label, adx_color = 'Choppy · avoid trades', '#ef4444'
# DI direction
di_dir = 'Bullish' if pdi > ndi else 'Bearish' if ndi > pdi else 'Mixed'
di_color = '#10b981' if di_dir == 'Bullish' else '#ef4444' if di_dir == 'Bearish' else '#64748b'

# BB %B interpretation
if bb_pb <= 0.05:   bb_label, bb_color = 'At lower band · oversold', '#10b981'
elif bb_pb <= 0.2:  bb_label, bb_color = 'Near lower band', '#84cc16'
elif bb_pb >= 0.95: bb_label, bb_color = 'At upper band · overbought', '#ef4444'
elif bb_pb >= 0.8:  bb_label, bb_color = 'Near upper band', '#f59e0b'
else:               bb_label, bb_color = 'Middle range', '#64748b'
# BB squeeze
bb_squeeze = bb_w < 3
bb_extra = f"width {bb_w:.2f}% {'· 🤏 SQUEEZE' if bb_squeeze else ''}"

# VWAP interpretation
vwap_diff = ((bot_price - vwap_v) / vwap_v * 100) if vwap_v else 0
if vwap_diff > 1:    vwap_label, vwap_color = f'+{vwap_diff:.2f}% above', '#10b981'
elif vwap_diff < -1: vwap_label, vwap_color = f'{vwap_diff:.2f}% below', '#ef4444'
else:                vwap_label, vwap_color = f'{vwap_diff:+.2f}% near', '#64748b'

# Stoch RSI interpretation
if srsi <= 20:   srsi_label, srsi_color = 'Oversold', '#10b981'
elif srsi >= 80: srsi_label, srsi_color = 'Overbought', '#ef4444'
else:            srsi_label, srsi_color = 'Neutral', '#64748b'

# OBV interpretation
obv_color = {'bullish': '#10b981', 'bearish': '#ef4444', 'neutral': '#64748b'}.get(obv_t, '#64748b')
obv_label = obv_t.capitalize()

# Tradeability score (quant heuristic: ADX strength × direction agreement)
# Used to give a single "should the bot trade?" signal
trade_signal = '—'; trade_color = '#64748b'; trade_explain = ''
if adx_v < 20:
    trade_signal = 'Wait'; trade_color = '#ef4444'
    trade_explain = 'Market is choppy (ADX < 20). Trading would lose to noise.'
elif adx_v >= 25 and pdi > ndi and bot_price > vwap_v and srsi < 70:
    trade_signal = 'Bullish setup'; trade_color = '#10b981'
    trade_explain = 'Strong trend + bullish DI + above VWAP + not yet overbought.'
elif adx_v >= 25 and ndi > pdi and bot_price < vwap_v:
    trade_signal = 'Bearish trend'; trade_color = '#ef4444'
    trade_explain = 'Strong downtrend confirmed. Bot stays in cash (no shorts).'
else:
    trade_signal = 'Monitor'; trade_color = '#f59e0b'
    trade_explain = 'Signals are mixed — bot waits for cleaner setup.'

# EMA trend
ema_trend = 'Neutral'; ema_color = '#64748b'
if ema21 and ema55 and ema200:
    if ema21 > ema55 > ema200:    ema_trend, ema_color = 'Strong uptrend', '#10b981'
    elif ema21 < ema55 < ema200:  ema_trend, ema_color = 'Strong downtrend', '#ef4444'
    elif ema21 > ema55:           ema_trend, ema_color = 'Short-term up', '#84cc16'
    elif ema21 < ema55:           ema_trend, ema_color = 'Short-term down', '#f59e0b'

# Price vs EMA200 (long-term filter)
price_vs_ema200 = ''
if ema200 and bot_price:
    diff_pct = ((bot_price - ema200) / ema200) * 100
    price_vs_ema200 = f"{'+' if diff_pct >= 0 else ''}{diff_pct:.2f}% vs EMA200"

# ATR volatility class
atr_label, atr_color = '—', '#64748b'
if atr and bot_price:
    atr_pct = (atr / bot_price) * 100
    if atr_pct > 2:     atr_label, atr_color = f'{atr_pct:.2f}% · High',   '#ef4444'
    elif atr_pct > 1:   atr_label, atr_color = f'{atr_pct:.2f}% · Normal', '#f59e0b'
    else:               atr_label, atr_color = f'{atr_pct:.2f}% · Low',    '#10b981'

# MACD histogram strength
macd_hist = (macd_v - macd_s) if (macd_v is not None and macd_s is not None) else None
macd_hist_html = f'{macd_hist:+.2f}' if macd_hist is not None else '—'

# Live indicator block
indicators_html = f"""
<div class="card">
  <div class="card-title">Bot Indicators <span style="font-size:10px;color:var(--muted);font-weight:500;text-transform:none;letter-spacing:0;">· last cycle {latest_ts or '—'}</span></div>
  <div class="grid2">
    <div class="stat">
      <div class="label">Bot Price (4h)</div>
      <div class="value">${bot_price:,.2f}</div>
    </div>
    <div class="stat">
      <div class="label">RSI (14)</div>
      <div class="value" style="color:{rsi_color}">{latest_rsi if latest_rsi is not None else '—'}</div>
      <div class="extra">{rsi_label}</div>
    </div>
    <div class="stat">
      <div class="label">MACD</div>
      <div class="value" style="color:{'#10b981' if 'Bullish' in (latest_macd or '') else '#ef4444' if 'Bearish' in (latest_macd or '') else '#64748b'}">{latest_macd or '—'}</div>
      <div class="extra">Histogram: {macd_hist_html}</div>
    </div>
    <div class="stat">
      <div class="label">EMA Trend (21/55/200)</div>
      <div class="value" style="color:{ema_color};font-size:14px;">{ema_trend}</div>
      <div class="extra">{price_vs_ema200}</div>
    </div>
    <div class="stat">
      <div class="label">ATR Volatility</div>
      <div class="value" style="color:{atr_color}">${atr:,.2f}</div>
      <div class="extra">{atr_label}</div>
    </div>
    <div class="stat">
      <div class="label">News Sentiment</div>
      <div class="value" style="color:{sent_color}">{sent_label}</div>
      <div class="extra">{(n_score or 0):+.2f}</div>
    </div>
  </div>
</div>

<!-- Pro Quant Indicators (calculated by bot) -->
<div class="card" style="border-color:rgba(99,102,241,.3);">
  <div class="card-title">🎯 Quant Setup <span class="status-tag" style="background:{trade_color}22;color:{trade_color};border-color:{trade_color}44;">{trade_signal}</span></div>
  <div style="font-size:12.5px;color:var(--text);line-height:1.6;margin-bottom:14px;">{trade_explain}</div>
  <div class="grid2">
    <div class="stat">
      <div class="label">ADX (14) · Trend Strength</div>
      <div class="value" style="color:{adx_color}">{adx_v:.1f}</div>
      <div class="extra">{adx_label}</div>
    </div>
    <div class="stat">
      <div class="label">DI Direction</div>
      <div class="value" style="color:{di_color}">{di_dir}</div>
      <div class="extra">+DI {pdi:.1f} / -DI {ndi:.1f}</div>
    </div>
    <div class="stat">
      <div class="label">Bollinger %B</div>
      <div class="value" style="color:{bb_color}">{bb_pb:.2f}</div>
      <div class="extra">{bb_label}</div>
    </div>
    <div class="stat">
      <div class="label">BB Volatility</div>
      <div class="value" style="color:{'#10b981' if bb_squeeze else 'var(--text)'};font-size:14px;">{'Squeeze' if bb_squeeze else 'Normal'}</div>
      <div class="extra">{bb_extra}</div>
    </div>
    <div class="stat">
      <div class="label">VWAP (4d rolling)</div>
      <div class="value">${vwap_v:,.0f}</div>
      <div class="extra" style="color:{vwap_color}">{vwap_label}</div>
    </div>
    <div class="stat">
      <div class="label">Stoch RSI</div>
      <div class="value" style="color:{srsi_color}">{srsi:.1f}</div>
      <div class="extra">{srsi_label}</div>
    </div>
    <div class="stat">
      <div class="label">OBV Volume Trend</div>
      <div class="value" style="color:{obv_color};font-size:14px;">{obv_label}</div>
      <div class="extra">Smart-money confirmation</div>
    </div>
    <div class="stat">
      <div class="label">BB Range</div>
      <div class="value" style="font-size:12px;">${bb_lo:,.0f} → ${bb_up:,.0f}</div>
      <div class="extra">Mean reversion zone</div>
    </div>
  </div>
</div>

<!-- Market-wide indicators (client-side fetched) -->
<div class="card">
  <div class="card-title">Market Pulse <span style="font-size:10px;color:var(--muted);font-weight:500;text-transform:none;letter-spacing:0;">· live · external APIs</span></div>
  <div class="grid2">
    <div class="stat">
      <div class="label">Fear &amp; Greed</div>
      <div class="value" id="fng-value">—</div>
      <div class="extra" id="fng-label">Loading…</div>
    </div>
    <div class="stat">
      <div class="label">BTC Dominance</div>
      <div class="value" id="btc-dom">—</div>
      <div class="extra" id="btc-dom-trend">CoinGecko global</div>
    </div>
    <div class="stat">
      <div class="label">24h Volume</div>
      <div class="value" id="btc-vol">—</div>
      <div class="extra">BTC traded last 24h</div>
    </div>
    <div class="stat">
      <div class="label">24h High / Low</div>
      <div class="value" id="btc-hilo" style="font-size:13px;">—</div>
      <div class="extra" id="btc-range">Range %</div>
    </div>
    <div class="stat">
      <div class="label">Funding Rate (Perps)</div>
      <div class="value" id="funding">—</div>
      <div class="extra" id="funding-label">Binance · 8h interval</div>
    </div>
    <div class="stat">
      <div class="label">Long / Short Ratio</div>
      <div class="value" id="ls-ratio">—</div>
      <div class="extra" id="ls-label">Top traders · Binance</div>
    </div>
  </div>
</div>
"""

headlines_html = ''.join(
    f'<li style="padding:8px 0; border-bottom:1px solid var(--border); font-size:12.5px; color:var(--text); line-height:1.5;">{html.escape(h)}</li>'
    for h in headlines
)
news_html = f"""
<div class="card">
  <div class="card-title">News Sentiment Engine <span class="status-tag" style="background:{sent_color}22;color:{sent_color};border-color:{sent_color}44;">{sent_label}</span></div>
  {f'<div style="font-size:12.5px;color:var(--text);line-height:1.6;margin-bottom:14px;">{html.escape(n_reason)}</div>' if n_reason else ''}
  {f'<div style="font-size:10px;color:var(--muted);margin-bottom:4px;letter-spacing:.5px;">RECENT HEADLINES</div><ul>{headlines_html}</ul>' if headlines else '<div style="font-size:12px;color:var(--muted);">Waiting for next news fetch…</div>'}
</div>
""" if (n_reason or headlines) else ''

status_pill = f"""<div class="live-dot{'  alive' if bot_alive else ''}">{'Bot online' if bot_alive else 'Bot offline'} · {now_str}</div>"""

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
      --green:#10b981; --amber:#f59e0b; --red:#ef4444; --text:#f0f4ff; --muted:#64748b;
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
    .header {{ text-align:center; margin-bottom:24px; }}
    .header .emoji {{ font-size:36px; margin-bottom:8px; }}
    .header h1 {{
      font-size:24px; font-weight:800; letter-spacing:-.4px; margin-bottom:6px;
      background:linear-gradient(135deg,#f59e0b,#ef4444);
      -webkit-background-clip:text; -webkit-text-fill-color:transparent; background-clip:text;
    }}
    .header .sub {{ font-size:12.5px; color:var(--muted); }}
    .live-dot {{
      display:inline-flex; align-items:center; gap:6px; margin-top:10px;
      font-size:11px; color:var(--muted); background:rgba(100,116,139,.1);
      border:1px solid rgba(100,116,139,.2); padding:4px 12px; border-radius:99px;
    }}
    .live-dot.alive {{ color:var(--green); background:rgba(16,185,129,.1); border-color:rgba(16,185,129,.2); }}
    .live-dot::before {{
      content:''; width:7px; height:7px; border-radius:50%; background:#64748b;
    }}
    .live-dot.alive::before {{ background:var(--green); animation:pulse 1.6s ease-in-out infinite; }}
    @keyframes pulse {{ 0%,100% {{opacity:1}} 50% {{opacity:.4}} }}
    .card {{
      background:var(--card); border:1px solid var(--border); border-radius:14px;
      padding:20px; margin-bottom:14px;
    }}
    .card-title {{
      font-size:11px; font-weight:700; letter-spacing:1.2px; text-transform:uppercase;
      color:var(--muted); margin-bottom:14px; display:flex; align-items:center; gap:10px; flex-wrap:wrap;
    }}
    .status-tag {{
      font-size:10px; font-weight:700; padding:2px 8px; border-radius:99px;
      border:1px solid; letter-spacing:.4px; text-transform:none;
    }}
    .price-row {{ display:flex; justify-content:space-between; align-items:center; margin-bottom:10px; }}
    #live-price {{ font-size:26px; font-weight:800; letter-spacing:-.5px; }}
    #live-change {{ font-size:12px; font-weight:600; padding:3px 9px; border-radius:99px; }}
    .grid2 {{ display:grid; grid-template-columns:1fr 1fr; gap:10px; }}
    .stat {{ background:var(--card2); border:1px solid var(--border); border-radius:10px; padding:12px 14px; }}
    .stat .label {{ font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.6px; margin-bottom:6px; }}
    .stat .value {{ font-size:17px; font-weight:800; letter-spacing:-.3px; }}
    .stat .extra {{ font-size:11px; color:var(--muted); margin-top:3px; }}
    .alert {{
      margin-top:14px; padding:10px 14px; border-radius:8px;
      background:rgba(245,158,11,.08); border:1px solid rgba(245,158,11,.2);
      font-size:12px; color:#f59e0b; line-height:1.5;
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
      <div class="sub">Binance Demo · EMA + RSI + MACD + ATR + News sentiment · 5 min cycle</div>
      {status_pill}
      <div style="margin-top:14px;display:flex;justify-content:center;align-items:center;gap:10px;">
        <button id="refresh-btn" onclick="refreshBot()" style="
          padding:8px 16px; border-radius:8px; border:1px solid var(--border);
          background:linear-gradient(135deg,#6366f1,#8b5cf6); color:#fff;
          font-size:12.5px; font-weight:700; cursor:pointer;
          display:inline-flex; align-items:center; gap:6px;
          box-shadow:0 4px 16px rgba(99,102,241,.35);
          transition:transform .15s, opacity .15s;
        ">
          <span id="refresh-icon">⟳</span> <span id="refresh-text">Refresh from bot</span>
        </button>
        <span id="refresh-status" style="font-size:11px;color:var(--muted);"></span>
      </div>
    </div>

    <!-- Live price (CoinGecko, client-side) -->
    <div class="card">
      <div class="card-title">Live BTC Price</div>
      <div class="price-row">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:4px;">BTC/USDT · CoinGecko</div>
          <div id="live-price">Loading…</div>
        </div>
        <div id="live-change">—</div>
      </div>
      <div style="font-size:11px;color:var(--muted);margin-top:4px;">Auto-refreshes every 30s</div>
    </div>

    <!-- Live trade status banner — updated by the Refresh button -->
    <div id="live-trade-banner" class="card" style="display:none;">
      <div class="card-title">Live Trade Check</div>
      <div id="live-trade-content" style="font-size:14px;line-height:1.5;"></div>
    </div>

    {indicators_html}
    {position_html}
    {stats_html}
    {news_html}

    <div class="footer">
      Generated {now_str} · Demo mode (no real money)<br/>
      Bot logs to PM2 every 5 min · Status auto-refreshes every 10 min<br/>
      <a href="https://github.com/Saurishg" target="_blank" rel="noopener">github.com/Saurishg</a>
    </div>

  </div>

  <script>
    const fmtUsd = n => '$' + n.toLocaleString('en-US', {{minimumFractionDigits: 2, maximumFractionDigits: 2}});
    const fmtCompact = n => {{
      if (n >= 1e9) return '$' + (n/1e9).toFixed(2) + 'B';
      if (n >= 1e6) return '$' + (n/1e6).toFixed(2) + 'M';
      if (n >= 1e3) return '$' + (n/1e3).toFixed(2) + 'K';
      return '$' + n.toFixed(2);
    }};

    async function fetchPrice() {{
      try {{
        const r = await fetch('https://api.coingecko.com/api/v3/coins/bitcoin?localization=false&tickers=false&market_data=true&community_data=false&developer_data=false');
        const d = await r.json();
        const m = d.market_data;
        const p = m.current_price.usd;
        const c = m.price_change_percentage_24h;
        document.getElementById('live-price').textContent = fmtUsd(p);
        const ch = document.getElementById('live-change');
        ch.textContent = (c >= 0 ? '+' : '') + c.toFixed(2) + '%';
        ch.style.background = c >= 0 ? 'rgba(16,185,129,.12)' : 'rgba(239,68,68,.12)';
        ch.style.color = c >= 0 ? '#10b981' : '#ef4444';

        // 24h volume + high/low
        document.getElementById('btc-vol').textContent = fmtCompact(m.total_volume.usd);
        const hi = m.high_24h.usd, lo = m.low_24h.usd;
        document.getElementById('btc-hilo').innerHTML =
          '<span style="color:#10b981">' + fmtUsd(hi) + '</span><br/><span style="color:#ef4444">' + fmtUsd(lo) + '</span>';
        document.getElementById('btc-range').textContent =
          'Range: ' + (((hi - lo) / lo) * 100).toFixed(2) + '%';
      }} catch(e) {{
        document.getElementById('live-price').textContent = '—';
      }}
    }}

    async function fetchFearGreed() {{
      try {{
        const r = await fetch('https://api.alternative.me/fng/?limit=1');
        const d = await r.json();
        const v = parseInt(d.data[0].value);
        const cls = d.data[0].value_classification;
        let color = '#64748b';
        if (v < 25) color = '#ef4444';        // extreme fear
        else if (v < 45) color = '#f59e0b';   // fear
        else if (v < 55) color = '#facc15';   // neutral
        else if (v < 75) color = '#84cc16';   // greed
        else color = '#10b981';               // extreme greed
        const el = document.getElementById('fng-value');
        el.textContent = v;
        el.style.color = color;
        document.getElementById('fng-label').textContent = cls + ' · 0-100 scale';
      }} catch(e) {{
        document.getElementById('fng-value').textContent = '—';
      }}
    }}

    async function fetchBtcDominance() {{
      try {{
        const r = await fetch('https://api.coingecko.com/api/v3/global');
        const d = await r.json();
        const dom = d.data.market_cap_percentage.btc;
        const ch = d.data.market_cap_change_percentage_24h_usd;
        const el = document.getElementById('btc-dom');
        el.textContent = dom.toFixed(2) + '%';
        document.getElementById('btc-dom-trend').textContent = 'Total cap 24h: ' + (ch >= 0 ? '+' : '') + ch.toFixed(2) + '%';
      }} catch(e) {{
        document.getElementById('btc-dom').textContent = '—';
      }}
    }}

    async function fetchFunding() {{
      try {{
        const r = await fetch('https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT');
        const d = await r.json();
        const rate = parseFloat(d.lastFundingRate) * 100;
        const annual = rate * 3 * 365; // 8h funding * 3/day * 365
        const el = document.getElementById('funding');
        el.textContent = (rate >= 0 ? '+' : '') + rate.toFixed(4) + '%';
        el.style.color = rate >= 0 ? '#10b981' : '#ef4444';
        document.getElementById('funding-label').textContent =
          'Annualised: ' + (annual >= 0 ? '+' : '') + annual.toFixed(1) + '% · ' + (rate >= 0 ? 'Longs pay' : 'Shorts pay');
      }} catch(e) {{
        document.getElementById('funding').textContent = '—';
      }}
    }}

    async function fetchLongShort() {{
      try {{
        const r = await fetch('https://fapi.binance.com/futures/data/topLongShortAccountRatio?symbol=BTCUSDT&period=1h&limit=1');
        const d = await r.json();
        if (d && d.length) {{
          const ratio = parseFloat(d[0].longShortRatio);
          const longPct = parseFloat(d[0].longAccount) * 100;
          const shortPct = parseFloat(d[0].shortAccount) * 100;
          const el = document.getElementById('ls-ratio');
          el.textContent = ratio.toFixed(2);
          el.style.color = ratio > 1 ? '#10b981' : '#ef4444';
          document.getElementById('ls-label').textContent =
            longPct.toFixed(1) + '% L · ' + shortPct.toFixed(1) + '% S';
        }}
      }} catch(e) {{
        document.getElementById('ls-ratio').textContent = '—';
      }}
    }}

    function refreshAll() {{
      fetchPrice(); fetchFearGreed(); fetchBtcDominance();
      fetchFunding(); fetchLongShort();
    }}
    refreshAll();
    setInterval(refreshAll, 30000);

    // ── Live bot status (calls the creator-dashboard API via Cloudflare tunnel)
    const BOT_API = "{DASH_URL or ''}";

    async function refreshBot() {{
      const btn = document.getElementById('refresh-btn');
      const icon = document.getElementById('refresh-icon');
      const text = document.getElementById('refresh-text');
      const status = document.getElementById('refresh-status');
      const banner = document.getElementById('live-trade-banner');
      const content = document.getElementById('live-trade-content');

      if (!BOT_API) {{
        status.textContent = 'API URL not yet set — wait for next tunnel restart';
        return;
      }}

      btn.disabled = true; btn.style.opacity = .6;
      icon.style.animation = 'spin 0.8s linear infinite';
      text.textContent = 'Checking…'; status.textContent = '';

      try {{
        const r = await fetch(BOT_API + '/api/bot-status', {{ cache: 'no-store' }});
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const d = await r.json();

        banner.style.display = 'block';
        const ind = d.indicators || {{}};
        const state = d.state || {{}};
        const hasPos = d.hasPosition;
        const t = new Date(d.fetchedAt).toLocaleTimeString('en-US', {{hour12:false}});

        if (hasPos) {{
          const entry = state.entry_price;
          const tp = state.take_profit;
          const sl = state.stop_loss;
          const qty = state.qty;
          const cur = ind.price || 0;
          const pnlPct = entry ? ((cur - entry) / entry * 100) : 0;
          const pnlColor = pnlPct >= 0 ? '#10b981' : '#ef4444';
          content.innerHTML = `
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:14px;">
              <div style="font-size:32px;">📈</div>
              <div>
                <div style="font-size:16px;font-weight:800;color:#10b981;">IN TRADE</div>
                <div style="font-size:11.5px;color:var(--muted);">Entered @ $${{entry.toLocaleString()}} · ${{qty}} BTC</div>
              </div>
              <div style="margin-left:auto;text-align:right;">
                <div style="font-size:20px;font-weight:800;color:${{pnlColor}};">${{pnlPct >= 0 ? '+' : ''}}${{pnlPct.toFixed(2)}}%</div>
                <div style="font-size:10px;color:var(--muted);">unrealised</div>
              </div>
            </div>
            <div style="display:flex;gap:8px;font-size:11px;">
              <span style="padding:4px 10px;border-radius:8px;background:rgba(16,185,129,.1);color:#10b981;">TP $${{tp.toLocaleString()}}</span>
              <span style="padding:4px 10px;border-radius:8px;background:rgba(239,68,68,.1);color:#ef4444;">SL $${{sl.toLocaleString()}}</span>
            </div>
          `;
        }} else {{
          const blockers = [];
          if (ind.ema21 < ind.ema55) blockers.push('EMA bearish');
          if (ind.rsi < 50) blockers.push(`RSI=${{Math.round(ind.rsi)}}`);
          if (ind.macd < ind.macd_sig) blockers.push('MACD bearish');
          if (ind.news < -0.3) blockers.push(`news=${{ind.news.toFixed(2)}}`);
          content.innerHTML = `
            <div style="display:flex;align-items:center;gap:12px;">
              <div style="font-size:32px;">⏳</div>
              <div style="flex:1;">
                <div style="font-size:16px;font-weight:800;color:var(--amber);">NOT IN TRADE</div>
                <div style="font-size:11.5px;color:var(--muted);">Bot is scanning. Last cycle: ${{d.lastCycleTs || 'unknown'}}</div>
              </div>
            </div>
            ${{blockers.length ? `<div class="alert" style="margin-top:14px;"><strong>Waiting for:</strong> ${{blockers.join(', ')}}</div>` : ''}}
          `;
        }}

        status.textContent = '✓ Live · ' + t;
        text.textContent = 'Refresh from bot';
      }} catch(e) {{
        status.textContent = '✗ ' + (e.message || 'Failed to reach bot');
        text.textContent = 'Refresh from bot';
      }} finally {{
        btn.disabled = false; btn.style.opacity = 1;
        icon.style.animation = '';
      }}
    }}

    // Add spin keyframes if not present
    if (!document.getElementById('spin-kf')) {{
      const s = document.createElement('style');
      s.id = 'spin-kf';
      s.textContent = '@keyframes spin {{ from{{transform:rotate(0)}} to{{transform:rotate(360deg)}} }}';
      document.head.appendChild(s);
    }}

    // Auto-fetch live status once on page load
    if (BOT_API) refreshBot();
  </script>
</body>
</html>
"""

OUT.write_text(doc)
print(f"✓ Generated btc.html ({len(doc)} chars) · has_position={has_position} · trades={total_trades}")
PY

# Commit + push only if file changed
if ! git diff --quiet btc.html 2>/dev/null; then
  git add btc.html
  git commit -m "auto-update BTC bot status ($(date '+%Y-%m-%d %H:%M'))" || exit 0
  GIT_ASKPASS=echo git push origin main 2>&1 | tail -2
  echo "✓ Pushed BTC status update"
else
  echo "✓ BTC status unchanged"
fi
