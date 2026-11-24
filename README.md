# MQL5 Quantitative EUR/USD & XAU/USD Strategies

Production-oriented MetaTrader 5 (MQL5) Expert Advisors implementing the institutional 9-module non-repainting architecture and risk management framework for **Strategies #1, #3, and #4**.

## Repository Structure

```text
MQL5/
├── Include/
│   └── QuantCore/
│       └── QuantCore.mqh                   # Shared closed-bar sync, risk firewall, DD governor, 20D corr, Hurst R/S, news blackout
└── Experts/
    └── QuantStrategies/
        ├── Strat1_XAU_SMC_MetaLGBM.mq5     # Strategy #1: XAU/USD H1 SMC (Sweep -> BOS -> FVG) + ONNX LightGBM Meta-Labeling
        ├── Strat3_MTF_SqueezeBreakout.mq5  # Strategy #3: EUR/USD & XAU/USD H4/H1 Volatility-Squeeze Breakout & Retest
        └── Strat4_EURUSD_RegimeMeanRev.mq5 # Strategy #4: EUR/USD H1/M15 Regime-Gated Mean Reversion (BB/Z-Score + ADX/Hurst)
```

## Strategies Included

### 1. Strategy #1 — XAU/USD H1 SMC + LightGBM Meta-Labeling (`Strat1_XAU_SMC_MetaLGBM.mq5`)
- **Structure:** Non-repainting 3-left/3-right confirmed fractal swings, liquidity sweep (>0.25× ATR wick + close back inside), 1-bar-lagged BOS/CHoCH + >0.35× ATR FVG within 6 H1 bars.
- **ML Meta-Filter:** Native MT5 ONNX Runtime inference (`MQL5\Files\xau_smc_meta_lgbm.onnx`, float32 `[1, 4]` features: `[fvg_freshness, atr_percentile_0_1, utc_hour, d1_trend_align]`), gating trades at $\hat{p}_t \ge 0.55$ and scaling risk via $r_t = 0.50\% \times \text{clip}((\hat{p}_t - 0.50)/0.25,\, 0.5,\, 1.0)$. Includes optional rules-only fallback (`InpAllowRulesFallback = true`) for baseline testing.
- **Execution & Exits:** Limit entry at FVG boundary (6-bar expiry / close-through invalidation), clamped 0.75×–2.0× ATR SL, 50% partial at +1.5R + BE+0.1R + 1.5× ATR Chandelier trail to +3.0R, opposing BOS exit, 18-hour elapsed-time stop, Friday 20:00 UTC flat exit.

### 2. Strategy #3 — MTF Volatility-Squeeze Breakout & Retest (`Strat3_MTF_SqueezeBreakout.mq5`)
- **Instruments:** EUR/USD and XAU/USD (independently calibrated presets; use distinct `InpMagicNumber` and `InpMaxSpreadPrice` per symbol).
- **Regime & Entry:** H4 EMA(50) bias + slope, preceding H1 squeeze (20-period BB Bandwidth in bottom 25th percentile of 100 bars OR BB(20, 2.0) inside Keltner(20, 1.5× ATR) for ≥4 consecutive bars), 12-bar consolidation breakout with >60% body ratio and range in `[1.0x, 2.2x]` ATR, D1 swing S/R proximity filter (≥0.8× ATR), and retest limit entry (+0.10× ATR buffer, 3-bar expiry, >0.40× ATR fail-inside cancellation).
- **Exits:** 1.25× ATR boundary SL, 50% partial at +1.5R + BE to +2.5R, 19:00 UTC stall exit (±0.3R), optional 20:00 UTC zero-swap flat exit.

### 3. Strategy #4 — EUR/USD Regime-Gated Mean Reversion (`Strat4_EURUSD_RegimeMeanRev.mq5`)
- **Instrument:** EUR/USD exclusively (hard symbol guard prevents running unmodified on XAU/USD).
- **Calm-Range Gate:** H4 ADX(14) < 22, H1 ADX(14) < 20, rolling 200-bar H1 R/S Hurst Exponent $H < 0.48$, H1 ATR(14) ≤ 1.8× its 50-bar mean.
- **Entry & Exits:** BB(20, 2.2) + RSI(14) re-entry (plus optional M15 Stochastic(14,3,3) confirmation strictly during 12:00–16:00 UTC), 0.75× ATR SL with 15-pip H1 / 10-pip M15 floor, dynamic SMA(20) TP with pre-entry net R:R ≥ 1.0R gate, max 1 same-direction loss/day, asymmetric -2h/+1h Tier-1 news blackout, 8-bar elapsed-time stop, and 20:30 UTC flat exit.

## Shared Risk Firewall (`QuantCore.mqh`)
- **Circuit Breakers:** Hard 1.50% daily realized loss cap and 3.00% weekly drawdown cap.
- **Drawdown Governor:** Automatically halves per-trade risk at ≥6.0% equity drawdown or ≥6 consecutive losses; restores full risk only within 2.0% of High-Water Mark.
- **Dynamic Correlation Scaling:** Computes 20-day D1 return correlation $\rho$ between EUR/USD and XAU/USD; when $\rho > 0.50$ and an opposing/peer same-direction USD trade is open, scales risk by $\sqrt{2/(2+2\rho)}$.
- **Rollover & News Protection:** Hard 20:00–23:59 UTC rollover entry blackout and native MT5 `CalendarValueHistory` Tier-1 news filter.

## Installation
1. In MetaTrader 5, go to **File → Open Data Folder**.
2. Copy the `MQL5/` directory from this repository into your MT5 Data Folder.
3. Open MetaEditor (F4) and compile (`F7`) each `.mq5` file in `MQL5/Experts/QuantStrategies/`.
4. Backtest strictly in **"Every tick based on real ticks"** mode with realistic ECN commissions and swaps, starting at `InpBaseRiskPct = 0.25` for live incubation.
