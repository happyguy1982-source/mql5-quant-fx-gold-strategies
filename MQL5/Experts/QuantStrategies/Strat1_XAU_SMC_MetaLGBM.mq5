//+------------------------------------------------------------------+
//|                                     Strat1_XAU_SMC_MetaLGBM.mq5  |
//|   Strategy #1: XAU-H1 Structure-Aware Sweep-BOS-FVG Meta-Labeled |
//|   Architecture: 9-Module Non-Repainting Engine + Native ONNX ML  |
//+------------------------------------------------------------------+
#property copyright "Quantitative FX/Gold Research Framework"
#property version   "1.00"
#property description "Strategy #1: XAU/USD H1 SMC (Sweep -> BOS -> FVG) + Calibrated LightGBM ONNX Meta-Labeling"

#include <Trade\Trade.mqh>
#include <QuantCore\QuantCore.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Identity & Broker Clock ==="
input long     InpMagicNumber        = 100101;         // Magic Number
input string   InpPeerSymbol         = "EURUSD";       // Peer Symbol for 20D Correlation Scaling
input bool     InpUseTesterUTCOffset = true;           // Adjust Tester TimeCurrent() to UTC
input int      InpBrokerUTCOffset    = 2;              // Broker GMT Offset (Hours, e.g. +2/+3)
input int      InpSlippagePoints     = 30;             // Max Allowed Deviation (Points)

input group "=== Session & Liquidity Filters ==="
input int      InpSessionStartUTC    = 7;              // Session Start Hour (UTC, inclusive)
input int      InpSessionEndUTC      = 16;             // Session End Hour (UTC, exclusive)
input double   InpMaxSpreadPrice     = 0.60;           // Max Live Spread ($/oz, default $0.60)
input int      InpNewsBlackoutMin    = 30;             // Tier-1 US News Blackout (+/- Minutes)
input int      InpMaxTradesPerDay    = 2;              // Max Trades Per Day

input group "=== SMC Structure Parameters (H1) ==="
input int      InpATRPeriod          = 14;             // H1 ATR Period
input int      InpATRPctLookback     = 100;            // ATR Rolling Percentile Lookback (Bars)
input double   InpMinATRPercentile   = 20.0;           // Min H1 ATR Percentile (>20th)
input double   InpSweepMinATR        = 0.25;           // Min Sweep Wick Beyond Swing (x ATR)
input int      InpBOSWindowBars      = 6;              // Max H1 Bars From Sweep to BOS+FVG
input double   InpFVGMinATR          = 0.35;           // Min FVG Size (x ATR)
input int      InpLimitExpiryBars    = 6;              // Limit Entry Validity (H1 Bars)

input group "=== LightGBM Meta-Labeling (ONNX) ==="
input bool     InpUseOnnxMetaModel   = true;           // Enable Native ONNX Meta-Classifier
input string   InpOnnxModelPath      = "xau_smc_meta_lgbm.onnx"; // Model in MQL5\Files\
input double   InpMetaProbThreshold  = 0.55;           // Min Calibrated Win Probability (p_hat >= 0.55)
input bool     InpAllowRulesFallback = true;           // If ONNX Missing, Run Rules-Only Baseline
input double   InpFallbackProb       = 0.65;           // Fixed p_hat When Rules-Only Fallback Active

input group "=== Risk, Stop-Loss & Exit Management ==="
input double   InpBaseRiskPct        = 0.50;           // Base Risk % Per Trade (0.25% Incubation / 0.50% Prod)
input double   InpMaxDailyLossPct    = 1.50;           // Hard Daily Loss Circuit Breaker (%)
input double   InpMaxWeeklyDDPct     = 3.00;           // Hard Weekly DD Circuit Breaker (%)
input double   InpSLBufferATR        = 0.35;           // SL Buffer Beyond FVG/Sweep Extreme (x ATR)
input double   InpSLMinATR           = 0.75;           // Min SL Distance Clamp (x ATR)
input double   InpSLMaxATR           = 2.00;           // Max SL Distance Clamp (x ATR)
input double   InpPartialTriggerR    = 1.50;           // Partial Close Trigger (+1.5R)
input double   InpPartialCloseFrac   = 0.50;           // Partial Close Fraction (50%)
input double   InpBEOffsetR          = 0.10;           // Breakeven Offset After Partial (+0.1R for ECN)
input double   InpChandelierATR      = 1.50;           // Chandelier Trail Multiplier (x ATR)
input double   InpHardTargetR        = 3.00;           // Hard Take-Profit Target (+3.0R)
input int      InpTimeStopHours      = 18;             // Mandatory Holding Time Stop (Hours)
input int      InpFridayFlatHourUTC  = 20;             // Friday Pre-Weekend Flat Exit Hour (UTC)

//+------------------------------------------------------------------+
//| State Structures                                                 |
//+------------------------------------------------------------------+
struct SSweepState
  {
   bool     active;
   int      direction;        // +1 bullish, -1 bearish
   datetime barTime;          // Closed bar timestamp when sweep occurred
   double   extremePrice;     // Sweep Low (bullish) or Sweep High (bearish)
   int      barsElapsed;
  };

struct SPendingSetup
  {
   bool     active;
   ulong    orderTicket;
   int      direction;        // +1 buy limit, -1 sell limit
   double   entryPrice;       // FVG upper (long) or lower (short)
   double   invalidatePrice;  // FVG lower (long) or upper (short)
   datetime placedTime;
   int      barsAlive;
  };

struct SPositionTracker
  {
   ulong    ticket;
   int      direction;
   double   entryPrice;
   double   initialRiskDist;  // 1R in price units
   bool     partialTaken;
   double   extremeSinceEntry;
  };

//+------------------------------------------------------------------+
//| Global Objects & Handles                                         |
//+------------------------------------------------------------------+
CTrade           g_trade;
CNewBar          g_barH1;
CRiskManager     g_risk;

int              g_hATR_H1    = INVALID_HANDLE;
int              g_hEMA50_D1  = INVALID_HANDLE;
long             g_onnxHandle = INVALID_HANDLE;
bool             g_onnxReady  = false;

// Confirmed non-repainting fractal swings (3-left, 3-right)
double           g_lastSwingHigh = 0.0;
double           g_lastSwingLow  = 0.0;
datetime         g_lastSwingHighTime = 0;
datetime         g_lastSwingLowTime  = 0;

SSweepState      g_sweep;
SPendingSetup    g_pending;
SPositionTracker g_pos;

//+------------------------------------------------------------------+
//| Initialize ONNX LightGBM Meta-Classifier                         |
//+------------------------------------------------------------------+
bool InitOnnxModel()
  {
   g_onnxReady = false;
   if(!InpUseOnnxMetaModel)
      return false;

   g_onnxHandle = OnnxCreate(InpOnnxModelPath, ONNX_DEFAULT);
   if(g_onnxHandle == INVALID_HANDLE)
     {
      PrintFormat("[ML] ONNX model '%s' not found or failed to load (err=%d). Fallback=%s",
                  InpOnnxModelPath, GetLastError(), InpAllowRulesFallback ? "ON" : "OFF");
      return false;
     }

   // Expected input: float32[1, 4] -> [fvg_freshness, atr_percentile, utc_hour, d1_trend_align]
   const ulong inputShape[] = {1, 4};
   if(!OnnxSetInputShape(g_onnxHandle, 0, inputShape))
     {
      PrintFormat("[ML] Failed to set ONNX input shape [1,4] (err=%d)", GetLastError());
      OnnxRelease(g_onnxHandle);
      g_onnxHandle = INVALID_HANDLE;
      return false;
     }

   long outCount = OnnxGetOutputCount(g_onnxHandle);
   if(outCount == 1)
     {
      const ulong outShape1[] = {1, 1};
      OnnxSetOutputShape(g_onnxHandle, 0, outShape1);
     }
   else if(outCount >= 2)
     {
      // Standard onnxmltools / skl2onnx LightGBM classifier with zipmap=False:
      // output 0: label int64[1], output 1: probabilities float32[1, 2]
      const ulong outLabel[] = {1};
      const ulong outProbs[] = {1, 2};
      OnnxSetOutputShape(g_onnxHandle, 0, outLabel);
      OnnxSetOutputShape(g_onnxHandle, 1, outProbs);
     }

   g_onnxReady = true;
   PrintFormat("[ML] Loaded ONNX meta-model '%s' (outputs=%I64d).", InpOnnxModelPath, outCount);
   return true;
  }

//+------------------------------------------------------------------+
//| Run ONNX Inference -> Calibrated Win Probability p_hat in [0, 1] |
//+------------------------------------------------------------------+
double PredictMetaProbability(const double fvgFreshness,
                              const double atrPercentile,
                              const int utcHour,
                              const double d1TrendAlign)
  {
   if(!InpUseOnnxMetaModel)
      return InpFallbackProb;

   if(!g_onnxReady || g_onnxHandle == INVALID_HANDLE)
     {
      if(InpAllowRulesFallback)
         return InpFallbackProb;
      return 0.0; // Reject trade if strict ONNX mode and model missing
     }

   float inputData[4];
   inputData[0] = (float)fvgFreshness;
   inputData[1] = (float)(atrPercentile / 100.0);
   inputData[2] = (float)utcHour;
   inputData[3] = (float)d1TrendAlign;

   long outCount = OnnxGetOutputCount(g_onnxHandle);
   if(outCount == 1)
     {
      float outProb[1];
      if(!OnnxRun(g_onnxHandle, ONNX_DEFAULT, inputData, outProb))
        {
         PrintFormat("[ML] OnnxRun(1-out) failed (err=%d)", GetLastError());
         return InpAllowRulesFallback ? InpFallbackProb : 0.0;
        }
      return ClampDouble((double)outProb[0], 0.0, 1.0);
     }
   else
     {
      long  outLabel[1];
      float outProbs[2]; // [P(class 0), P(class 1)]
      if(!OnnxRun(g_onnxHandle, ONNX_DEFAULT, inputData, outLabel, outProbs))
        {
         PrintFormat("[ML] OnnxRun(2-out) failed (err=%d)", GetLastError());
         return InpAllowRulesFallback ? InpFallbackProb : 0.0;
        }
      return ClampDouble((double)outProbs[1], 0.0, 1.0);
     }
  }

//+------------------------------------------------------------------+
//| Scan Recent Closed H1 Bars for Latest Confirmed 3-Left/3-Right   |
//| Fractal Swings: L_{t-3} == min(L_{t-6..t})                       |
//+------------------------------------------------------------------+
void UpdateConfirmedSwings(const MqlRates &rates[], const int count)
  {
   // rates[0] is shift=1 (last closed bar t).
   // A fractal at index idx requires 3 right bars (idx-1, idx-2, idx-3) and 3 left bars (idx+1, idx+2, idx+3).
   // So newest confirmable fractal is at idx = 3 (bar t-3).
   if(count < 10)
      return;

   // Bootstrap on first run by scanning backward; otherwise check idx = 3
   int maxScan = (g_lastSwingHigh <= 0.0 || g_lastSwingLow <= 0.0) ? MathMin(count - 4, 80) : 3;

   for(int idx = maxScan; idx >= 3; idx--)
     {
      bool isHigh = true;
      bool isLow  = true;
      double hMid = rates[idx].high;
      double lMid = rates[idx].low;

      for(int j = idx - 3; j <= idx + 3; j++)
        {
         if(j == idx) continue;
         if(rates[j].high > hMid) isHigh = false;
         if(rates[j].low  < lMid) isLow  = false;
        }

      if(isHigh && rates[idx].time > g_lastSwingHighTime)
        {
         g_lastSwingHigh     = hMid;
         g_lastSwingHighTime = rates[idx].time;
        }
      if(isLow && rates[idx].time > g_lastSwingLowTime)
        {
         g_lastSwingLow     = lMid;
         g_lastSwingLowTime = rates[idx].time;
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert Initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(_Period != PERIOD_H1)
      Print("[WARN] Strategy #1 is designed for XAU/USD H1. Current TF=", EnumToString(_Period));

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(DetectFillingMode(_Symbol));

   g_barH1.Init(_Symbol, PERIOD_H1);
   g_risk.Init(_Symbol, InpPeerSymbol, InpMagicNumber,
               InpBaseRiskPct, InpMaxDailyLossPct, InpMaxWeeklyDDPct,
               InpUseTesterUTCOffset, InpBrokerUTCOffset);

   g_hATR_H1   = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   g_hEMA50_D1 = iMA(_Symbol, PERIOD_D1, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hATR_H1 == INVALID_HANDLE || g_hEMA50_D1 == INVALID_HANDLE)
     {
      Print("[ERR] Failed to create indicator handles.");
      return INIT_FAILED;
     }

   ZeroMemory(g_sweep);
   ZeroMemory(g_pending);
   ZeroMemory(g_pos);

   InitOnnxModel();
   PrintFormat("[INIT] Strat1_XAU_SMC_MetaLGBM ready on %s (Magic=%I64d).", _Symbol, InpMagicNumber);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert Deinitialization (Release Handles to Prevent Leaks)       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hATR_H1   != INVALID_HANDLE) IndicatorRelease(g_hATR_H1);
   if(g_hEMA50_D1 != INVALID_HANDLE) IndicatorRelease(g_hEMA50_D1);
   if(g_onnxHandle != INVALID_HANDLE)
     {
      OnnxRelease(g_onnxHandle);
      g_onnxHandle = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Sync Open Position Tracker (Handles Limit Fill & Partial State)  |
//+------------------------------------------------------------------+
bool SyncOpenPosition()
  {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      if(g_pos.ticket != ticket)
        {
         g_pos.ticket            = ticket;
         g_pos.direction         = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         g_pos.entryPrice        = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl               = PositionGetDouble(POSITION_SL);
         g_pos.initialRiskDist   = MathAbs(g_pos.entryPrice - sl);
         g_pos.partialTaken      = false;
         g_pos.extremeSinceEntry = g_pos.entryPrice;

         // Log fill reconciliation slippage if triggered from our pending limit
         if(g_pending.active)
           {
            double slip = g_pos.entryPrice - g_pending.entryPrice;
            PrintFormat("[TELEMETRY] Limit filled #%I64u | Expected=%.2f Actual=%.2f Slip=%.3f",
                        ticket, g_pending.entryPrice, g_pos.entryPrice, slip);
            g_pending.active = false;
           }
        }
      return true;
     }

   g_pos.ticket = 0;
   return false;
  }

//+------------------------------------------------------------------+
//| Manage Active Pending Limit Order (6-Bar Expiry & Invalidation)  |
//+------------------------------------------------------------------+
void ManagePendingOrderOnBarClose(const MqlRates &lastClosedBar)
  {
   if(!g_pending.active)
      return;

   // Check if order still exists (may have been filled or expired)
   if(!OrderSelect(g_pending.orderTicket))
     {
      g_pending.active = false;
      return;
     }

   g_pending.barsAlive++;

   bool invalidated = false;
   if(g_pending.direction == 1 && lastClosedBar.close < g_pending.invalidatePrice)
      invalidated = true;
   if(g_pending.direction == -1 && lastClosedBar.close > g_pending.invalidatePrice)
      invalidated = true;

   if(invalidated)
     {
      CancelAllPendingByMagic(g_trade, _Symbol, InpMagicNumber, "FVG_INVALIDATED_CLOSE");
      g_pending.active = false;
      return;
     }

   if(g_pending.barsAlive >= InpLimitExpiryBars)
     {
      CancelAllPendingByMagic(g_trade, _Symbol, InpMagicNumber, "LIMIT_6BAR_EXPIRED");
      g_pending.active = false;
     }
  }

//+------------------------------------------------------------------+
//| Manage Open Position: Partial 1.5R, BE+0.1R, Chandelier, Exits   |
//+------------------------------------------------------------------+
void ManageOpenPositionOnBarClose(const MqlRates &lastClosedBar, const double atr14)
  {
   if(!SyncOpenPosition())
      return;

   if(!PositionSelectByTicket(g_pos.ticket))
      return;

   double curBid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double curAsk   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double curPrice = (g_pos.direction == 1) ? curBid : curAsk;
   double curSL    = PositionGetDouble(POSITION_SL);
   double curTP    = PositionGetDouble(POSITION_TP);
   double curVol   = PositionGetDouble(POSITION_VOLUME);
   datetime openTm = (datetime)PositionGetInteger(POSITION_TIME);

   // 1. Mandatory 18-hour Elapsed Unix Time Stop
   if((TimeCurrent() - openTm) >= InpTimeStopHours * 3600)
     {
      g_trade.PositionClose(g_pos.ticket);
      PrintFormat("[EXIT] Closed #%I64u: 18-hour time stop reached.", g_pos.ticket);
      g_pos.ticket = 0;
      return;
     }

   // 2. Friday 20:00 UTC Pre-Weekend Flat Exit
   MqlDateTime utc;
   GetUTCTimeStruct(utc, InpUseTesterUTCOffset, InpBrokerUTCOffset);
   if(utc.day_of_week == 5 && utc.hour >= InpFridayFlatHourUTC)
     {
      g_trade.PositionClose(g_pos.ticket);
      PrintFormat("[EXIT] Closed #%I64u: Friday %02d:00 UTC pre-weekend flat.", g_pos.ticket, InpFridayFlatHourUTC);
      g_pos.ticket = 0;
      return;
     }

   // 3. Opposing Confirmed BOS/CHoCH Close Exit
   if(g_pos.direction == 1 && g_lastSwingLow > 0.0 && lastClosedBar.close < g_lastSwingLow)
     {
      g_trade.PositionClose(g_pos.ticket);
      PrintFormat("[EXIT] Closed LONG #%I64u: Opposing bearish BOS close (%.2f < %.2f).",
                  g_pos.ticket, lastClosedBar.close, g_lastSwingLow);
      g_pos.ticket = 0;
      return;
     }
   if(g_pos.direction == -1 && g_lastSwingHigh > 0.0 && lastClosedBar.close > g_lastSwingHigh)
     {
      g_trade.PositionClose(g_pos.ticket);
      PrintFormat("[EXIT] Closed SHORT #%I64u: Opposing bullish BOS close (%.2f > %.2f).",
                  g_pos.ticket, lastClosedBar.close, g_lastSwingHigh);
      g_pos.ticket = 0;
      return;
     }

   // Track post-entry high/low for Chandelier stop
   if(g_pos.direction == 1 && lastClosedBar.high > g_pos.extremeSinceEntry)
      g_pos.extremeSinceEntry = lastClosedBar.high;
   if(g_pos.direction == -1 && lastClosedBar.low < g_pos.extremeSinceEntry)
      g_pos.extremeSinceEntry = lastClosedBar.low;

   if(g_pos.initialRiskDist <= 0.0)
      return;

   double openR = (g_pos.direction == 1)
                  ? ((curPrice - g_pos.entryPrice) / g_pos.initialRiskDist)
                  : ((g_pos.entryPrice - curPrice) / g_pos.initialRiskDist);

   // 4. Close 50% at +1.5R and shift remaining SL to BE + 0.1R
   if(!g_pos.partialTaken && openR >= InpPartialTriggerR)
     {
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double closeVol = MathFloor((curVol * InpPartialCloseFrac) / lotStep) * lotStep;
      closeVol = NormalizeDouble(closeVol, 2);

      if(closeVol >= minLot && (curVol - closeVol) >= minLot)
        {
         if(g_trade.PositionClosePartial(g_pos.ticket, closeVol))
            PrintFormat("[EXIT] Partial %.2f lots closed at +%.2fR on #%I64u.", closeVol, openR, g_pos.ticket);
        }

      double beSL = (g_pos.direction == 1)
                    ? (g_pos.entryPrice + InpBEOffsetR * g_pos.initialRiskDist)
                    : (g_pos.entryPrice - InpBEOffsetR * g_pos.initialRiskDist);
      beSL = NormalizePriceToTick(_Symbol, beSL);

      if((g_pos.direction == 1 && beSL > curSL) || (g_pos.direction == -1 && (curSL == 0.0 || beSL < curSL)))
        {
         g_trade.PositionModify(g_pos.ticket, beSL, curTP);
         curSL = beSL;
        }
      g_pos.partialTaken = true;
     }

   // 5. After partial close, trail remaining 50% via 1.5x ATR Chandelier stop
   if(g_pos.partialTaken && atr14 > 0.0)
     {
      double trailSL = (g_pos.direction == 1)
                       ? (g_pos.extremeSinceEntry - InpChandelierATR * atr14)
                       : (g_pos.extremeSinceEntry + InpChandelierATR * atr14);
      trailSL = NormalizePriceToTick(_Symbol, trailSL);

      if(g_pos.direction == 1 && trailSL > curSL && trailSL < curBid)
         g_trade.PositionModify(g_pos.ticket, trailSL, curTP);
      else if(g_pos.direction == -1 && (curSL == 0.0 || trailSL < curSL) && trailSL > curAsk)
         g_trade.PositionModify(g_pos.ticket, trailSL, curTP);
     }
  }

//+------------------------------------------------------------------+
//| Main Tick Handler (Strict Closed-Bar H1 Execution Loop)          |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Sync fill telemetry on every tick if pending limit got filled intrabar
   if(g_pending.active && CountOpenPositionsByMagic(_Symbol, InpMagicNumber) > 0)
      SyncOpenPosition();

   if(!g_barH1.IsNewBar())
      return;

   // Module 1: Verify multi-timeframe history synchronization
   if(!IsSeriesSynchronized(_Symbol, PERIOD_H1, 150) ||
      !IsSeriesSynchronized(_Symbol, PERIOD_D1, 60))
      return;

   // Fetch strictly CLOSED bars (shift = 1)
   MqlRates ratesH1[];
   ArraySetAsSeries(ratesH1, true);
   if(CopyRates(_Symbol, PERIOD_H1, 1, 120, ratesH1) < 120)
      return;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_hATR_H1, 0, 1, InpATRPctLookback, atrBuf) < InpATRPctLookback)
      return;

   double ema50D1[];
   ArraySetAsSeries(ema50D1, true);
   if(CopyBuffer(g_hEMA50_D1, 0, 1, 2, ema50D1) < 2)
      return;

   double closeD1[];
   ArraySetAsSeries(closeD1, true);
   if(CopyClose(_Symbol, PERIOD_D1, 1, 2, closeD1) < 2)
      return;

   double atr14 = atrBuf[0]; // Last closed H1 bar ATR(14)
   if(atr14 <= 0.0)
      return;

   // Update non-repainting 3-left/3-right fractal swings BEFORE exit/entry logic
   double prevSwingHigh = g_lastSwingHigh;
   double prevSwingLow  = g_lastSwingLow;
   UpdateConfirmedSwings(ratesH1, 120);

   // Module 7: Update Equity, Drawdown Governor, Daily/Weekly Circuit Breakers
   g_risk.UpdateEquityTrackers();

   // Module 5: Manage open positions & pending limit orders BEFORE any new entry
   ManageOpenPositionOnBarClose(ratesH1[0], atr14);
   ManagePendingOrderOnBarClose(ratesH1[0]);

   // Advance sweep age counter
   if(g_sweep.active)
     {
      g_sweep.barsElapsed++;
      if(g_sweep.barsElapsed > InpBOSWindowBars)
         g_sweep.active = false;
     }

   // Detect new Liquidity Sweep on last closed bar (ratesH1[0])
   // Bullish Sweep: L_k < S_low, C_k > S_low, (S_low - L_k) > 0.25 * ATR14
   if(prevSwingLow > 0.0 &&
      ratesH1[0].low < prevSwingLow &&
      ratesH1[0].close > prevSwingLow &&
      (prevSwingLow - ratesH1[0].low) > InpSweepMinATR * atr14)
     {
      g_sweep.active       = true;
      g_sweep.direction    = 1;
      g_sweep.barTime      = ratesH1[0].time;
      g_sweep.extremePrice = ratesH1[0].low;
      g_sweep.barsElapsed  = 0;
     }
   // Bearish Sweep: H_k > S_high, C_k < S_high, (H_k - S_high) > 0.25 * ATR14
   else if(prevSwingHigh > 0.0 &&
           ratesH1[0].high > prevSwingHigh &&
           ratesH1[0].close < prevSwingHigh &&
           (ratesH1[0].high - prevSwingHigh) > InpSweepMinATR * atr14)
     {
      g_sweep.active       = true;
      g_sweep.direction    = -1;
      g_sweep.barTime      = ratesH1[0].time;
      g_sweep.extremePrice = ratesH1[0].high;
      g_sweep.barsElapsed  = 0;
     }

   // Pre-Trade Risk Firewall
   int utcHour = GetUTCHour(InpUseTesterUTCOffset, InpBrokerUTCOffset);
   if(IsRolloverBlackoutUTC(utcHour))
      return;
   if(!IsInSessionUTC(utcHour, InpSessionStartUTC, InpSessionEndUTC))
      return;
   if(g_risk.IsCircuitBreakerTripped())
      return;
   if(IsTier1NewsBlackout("USD", InpNewsBlackoutMin, InpNewsBlackoutMin, true))
      return;

   double spreadPrice = GetCurrentSpreadPrice(_Symbol);
   if(spreadPrice > InpMaxSpreadPrice)
     {
      PrintFormat("[SKIP] Spread $%.2f > Max $%.2f", spreadPrice, InpMaxSpreadPrice);
      return;
     }

   // Position & Daily Trade Caps
   if(CountOpenPositionsByMagic(_Symbol, InpMagicNumber) >= 1)
      return;
   if(CountPendingOrdersByMagic(_Symbol, InpMagicNumber) >= 1)
      return;
   if(g_risk.CountTradesTodayUTC() >= InpMaxTradesPerDay)
      return;

   // Volatility Floor: H1 ATR(14) > 20th rolling percentile
   double atrPct = CalcPercentileRank(atrBuf, InpATRPctLookback, atr14);
   if(atrPct <= InpMinATRPercentile)
      return;

   // Module 4: Evaluate BOS/CHoCH + FVG within 6 H1 bars of Liquidity Sweep
   if(!g_sweep.active || g_sweep.barsElapsed < 1 || g_sweep.barsElapsed > InpBOSWindowBars)
      return;

   int    setupDir   = 0;
   double fvgTop     = 0.0;
   double fvgBottom  = 0.0;
   double entryPrice = 0.0;
   double invalPrice = 0.0;
   double rawSL      = 0.0;

   // Bullish Setup: 1-bar-lagged BOS close > prior swing high AND Bullish FVG (L_t > H_{t-2}) > 0.35 * ATR
   if(g_sweep.direction == 1 && prevSwingHigh > 0.0)
     {
      bool bosBull = (ratesH1[0].close > prevSwingHigh);
      double fvgSize = ratesH1[0].low - ratesH1[2].high;
      if(bosBull && fvgSize > InpFVGMinATR * atr14)
        {
         setupDir   = 1;
         fvgTop     = ratesH1[0].low;
         fvgBottom  = ratesH1[2].high;
         entryPrice = fvgTop;
         invalPrice = fvgBottom;
         rawSL      = MathMin(fvgBottom, g_sweep.extremePrice) - InpSLBufferATR * atr14;
        }
     }
   // Bearish Setup: 1-bar-lagged BOS close < prior swing low AND Bearish FVG (H_t < L_{t-2}) > 0.35 * ATR
   else if(g_sweep.direction == -1 && prevSwingLow > 0.0)
     {
      bool bosBear = (ratesH1[0].close < prevSwingLow);
      double fvgSize = ratesH1[2].low - ratesH1[0].high;
      if(bosBear && fvgSize > InpFVGMinATR * atr14)
        {
         setupDir   = -1;
         fvgTop     = ratesH1[2].low;
         fvgBottom  = ratesH1[0].high;
         entryPrice = fvgBottom;
         invalPrice = fvgTop;
         rawSL      = MathMax(fvgTop, g_sweep.extremePrice) + InpSLBufferATR * atr14;
        }
     }

   if(setupDir == 0)
      return;

   // Build Leakage-Free Meta-Labeling Feature Vector
   // 1) FVG freshness score f_FVG^t = normalized FVG size / ATR * decay(barsElapsed)
   double fvgWidth      = fvgTop - fvgBottom;
   double fvgFreshness  = (fvgWidth / atr14) * MathExp(-0.15 * (double)g_sweep.barsElapsed);
   // 2) D1 trend alignment (+1 if aligned with D1 EMA50, -1 if counter-trend)
   double d1TrendSign   = (closeD1[0] >= ema50D1[0]) ? 1.0 : -1.0;
   double d1TrendAlign  = d1TrendSign * (double)setupDir;

   double probWin = PredictMetaProbability(fvgFreshness, atrPct, utcHour, d1TrendAlign);
   if(probWin < InpMetaProbThreshold)
     {
      PrintFormat("[ML] Rejected SMC setup (dir=%d) | p_hat=%.3f < %.2f", setupDir, probWin, InpMetaProbThreshold);
      g_sweep.active = false;
      return;
     }

   // Clamp SL strictly between 0.75x and 2.0x H1 ATR(14)
   double slDist = MathAbs(entryPrice - rawSL);
   slDist = ClampDouble(slDist, InpSLMinATR * atr14, InpSLMaxATR * atr14);

   double slPrice = (setupDir == 1) ? (entryPrice - slDist) : (entryPrice + slDist);
   double tpPrice = (setupDir == 1) ? (entryPrice + InpHardTargetR * slDist)
                                    : (entryPrice - InpHardTargetR * slDist);

   entryPrice = NormalizePriceToTick(_Symbol, entryPrice);
   slPrice    = NormalizePriceToTick(_Symbol, slPrice);
   tpPrice    = NormalizePriceToTick(_Symbol, tpPrice);

   // Verify limit price sits on valid side of live market
   double curAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minStopDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(setupDir == 1 && entryPrice >= curAsk - minStopDist)
     {
      g_sweep.active = false;
      return;
     }
   if(setupDir == -1 && entryPrice <= curBid + minStopDist)
     {
      g_sweep.active = false;
      return;
     }

   // Module 6: Probability-Modulated ATR Position Sizing
   // r_t = BaseRisk * clip((p_hat - 0.50) / 0.25, 0.5, 1.0)
   double mlScalar = ClampDouble((probWin - 0.50) / 0.25, 0.50, 1.00);
   double lots     = g_risk.CalcPositionLots(entryPrice, slPrice, (setupDir == 1), mlScalar);
   if(lots <= 0.0)
      return;

   // Module 8: Submit Limit Order with Hard SL/TP
   bool sent = false;
   if(setupDir == 1)
      sent = g_trade.BuyLimit(lots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "Strat1_SMC_Long");
   else
      sent = g_trade.SellLimit(lots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "Strat1_SMC_Short");

   if(sent)
     {
      g_pending.active          = true;
      g_pending.orderTicket     = g_trade.ResultOrder();
      g_pending.direction       = setupDir;
      g_pending.entryPrice      = entryPrice;
      g_pending.invalidatePrice = invalPrice;
      g_pending.placedTime      = TimeCurrent();
      g_pending.barsAlive       = 0;
      g_sweep.active            = false;

      PrintFormat("[EXEC] Placed %s Limit #%I64u | Lots=%.2f Entry=%.2f SL=%.2f TP=%.2f | p_hat=%.3f mlScale=%.2f",
                  (setupDir == 1 ? "BUY" : "SELL"), g_pending.orderTicket,
                  lots, entryPrice, slPrice, tpPrice, probWin, mlScalar);
     }
  }
//+------------------------------------------------------------------+
