//+------------------------------------------------------------------+
//|                                  Strat3_MTF_SqueezeBreakout.mq5  |
//|  Strategy #3: MTF Volatility-Compression Breakout & Retest EA    |
//|  Applicable Instruments: EUR/USD & XAU/USD (Independent Presets) |
//|  Timeframes: H4 Bias / H1 Squeeze-Breakout-Retest / D1 S/R Gate  |
//+------------------------------------------------------------------+
#property copyright "Quantitative FX/Gold Research Framework"
#property version   "1.00"
#property description "Strategy #3: H4 EMA50 Bias + H1 BB/Keltner Squeeze Breakout + Retest Limit Entry"

#include <Trade\Trade.mqh>
#include <QuantCore\QuantCore.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Identity & Broker Clock ==="
input long     InpMagicNumber        = 100301;         // Magic Number (Use Unique Per Symbol)
input string   InpPeerSymbol         = "XAUUSD";       // Peer Symbol (XAUUSD if EURUSD, or EURUSD if XAUUSD)
input bool     InpUseTesterUTCOffset = true;           // Adjust Tester TimeCurrent() to UTC
input int      InpBrokerUTCOffset    = 2;              // Broker GMT Offset (Hours)
input int      InpSlippagePoints     = 20;             // Max Allowed Deviation (Points)

input group "=== Session & Liquidity Filters ==="
input int      InpBreakStartUTC      = 7;              // Breakout Window Start (UTC, inclusive)
input int      InpBreakEndUTC        = 15;             // Breakout Window End (UTC, exclusive; closes <= 15:00)
input double   InpMaxSpreadPrice     = 0.00015;        // Max Spread in Price (EUR: 0.00015 = 1.5p, XAU: 0.60)
input int      InpNewsBlackoutMin    = 15;             // Tier-1 News Blackout (+/- Minutes)
input string   InpNewsCurrencies     = "USD,EUR";      // Currencies to Filter for Tier-1 News
input int      InpMaxTradesPerDay    = 1;              // Max Trades Per Instrument Per Day

input group "=== Squeeze & Breakout Parameters (H4 / H1) ==="
input int      InpH4EMAPeriod        = 50;             // H4 Trend Bias EMA Period
input int      InpBBPeriod           = 20;             // H1 Bollinger / Keltner Period
input double   InpBBDeviation        = 2.0;            // H1 Bollinger StdDev
input double   InpKeltnerATRMult     = 1.5;            // H1 Keltner Channel ATR(20) Multiplier
input int      InpSqueezeMinBars     = 4;              // Min Consecutive BB-Inside-Keltner Bars
input int      InpBBWPctLookback     = 100;            // BB Bandwidth Percentile Lookback (Bars)
input double   InpBBWMaxPercentile   = 25.0;           // Max BBW Percentile (Bottom 25th)
input int      InpConsolLookback     = 12;             // H1 Consolidation High/Low Lookback Bars
input int      InpATRPeriod          = 14;             // H1 ATR Period
input double   InpMinBodyRatio       = 0.60;           // Min Breakout Candle Body / Range Ratio
input double   InpMinBreakRangeATR   = 1.00;           // Min Breakout Candle Range (x ATR)
input double   InpMaxBreakRangeATR   = 2.20;           // Max Breakout Candle Range (x ATR, excludes news climax)
input double   InpD1SRMinDistATR     = 0.80;           // Min Distance From Major D1 Swing S/R (x H1 ATR)

input group "=== Retest Entry, Risk & Exit Management ==="
input double   InpRetestBufferATR    = 0.10;           // Retest Limit Buffer Outside Boundary (x ATR)
input int      InpRetestExpiryBars   = 3;              // Retest Limit Validity (H1 Bars)
input double   InpRetestInvalATR     = 0.40;           // Cancel Limit if H1 Closes Inside Range > (x ATR)
input double   InpBaseRiskPct        = 0.50;           // Base Risk % Per Trade
input double   InpMaxDailyLossPct    = 1.50;           // Hard Daily Loss Circuit Breaker (%)
input double   InpMaxWeeklyDDPct     = 3.00;           // Hard Weekly DD Circuit Breaker (%)
input double   InpSLBoundaryATR      = 1.25;           // Hard SL Distance From Breakout Boundary (x ATR)
input double   InpPartialTriggerR    = 1.50;           // Partial Close Trigger (+1.5R)
input double   InpPartialCloseFrac   = 0.50;           // Partial Close Fraction (50%)
input double   InpHardTargetR        = 2.50;           // Final Runner Take-Profit Target (+2.5R)
input int      InpStallExitHourUTC   = 19;             // Intraday Stall Exit Hour (UTC) if -0.3R..+0.3R
input double   InpStallBandR         = 0.30;           // Stall Exit Unrealized P&L Band (+/- R)
input bool     InpFlatAt20UTC        = true;           // Zero-Swap Intraday Mode: Close Flat at 20:00 UTC

//+------------------------------------------------------------------+
//| State Structures                                                 |
//+------------------------------------------------------------------+
struct SRetestPending
  {
   bool     active;
   ulong    orderTicket;
   int      direction;        // +1 long, -1 short
   double   boundaryPrice;
   double   entryPrice;
   double   invalPrice;
   int      barsAlive;
  };

struct SPosState
  {
   ulong    ticket;
   int      direction;
   double   entryPrice;
   double   initialRiskDist;
   bool     partialTaken;
  };

//+------------------------------------------------------------------+
//| Global Objects & Handles                                         |
//+------------------------------------------------------------------+
CTrade         g_trade;
CNewBar        g_barH1;
CNewBar        g_barH4;
CRiskManager   g_risk;

int            g_hATR14_H1  = INVALID_HANDLE;
int            g_hATR20_H1  = INVALID_HANDLE;
int            g_hBB20_H1   = INVALID_HANDLE;
int            g_hEMA20_H1  = INVALID_HANDLE;
int            g_hEMA50_H4  = INVALID_HANDLE;

SRetestPending g_pending;
SPosState      g_pos;

//+------------------------------------------------------------------+
//| Check Proximity to Major D1 Swing Support / Resistance           |
//+------------------------------------------------------------------+
bool IsTooCloseToD1SwingSR(const double levelPrice, const double h1ATR)
  {
   MqlRates d1[];
   ArraySetAsSeries(d1, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 1, 35, d1);
   if(copied < 10)
      return false;

   double minDist = InpD1SRMinDistATR * h1ATR;
   // Scan confirmed 2-left / 2-right D1 swing highs and lows
   for(int i = 2; i < copied - 2; i++)
     {
      bool isD1High = (d1[i].high >= d1[i-1].high && d1[i].high >= d1[i-2].high &&
                       d1[i].high >= d1[i+1].high && d1[i].high >= d1[i+2].high);
      bool isD1Low  = (d1[i].low  <= d1[i-1].low  && d1[i].low  <= d1[i-2].low  &&
                       d1[i].low  <= d1[i+1].low  && d1[i].low  <= d1[i+2].low);

      if(isD1High && MathAbs(levelPrice - d1[i].high) <= minDist)
         return true;
      if(isD1Low && MathAbs(levelPrice - d1[i].low) <= minDist)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check Preceding H1 Volatility Squeeze (Before Breakout Bar)      |
//+------------------------------------------------------------------+
bool HasPrecedingSqueeze(const double &bbUp[], const double &bbMid[], const double &bbLow[],
                         const double &ema20[], const double &atr20[])
  {
   // Index 0 = breakout bar (shift 1). Preceding bars start at index 1 (shift 2).
   // Condition A: BB(20, 2.0) inside Keltner(20, 1.5*ATR20) for >= 4 consecutive bars
   bool kcSqueeze = true;
   for(int i = 1; i <= InpSqueezeMinBars; i++)
     {
      double kcUp  = ema20[i] + InpKeltnerATRMult * atr20[i];
      double kcLow = ema20[i] - InpKeltnerATRMult * atr20[i];
      if(!(bbUp[i] < kcUp && bbLow[i] > kcLow))
        {
         kcSqueeze = false;
         break;
        }
     }
   if(kcSqueeze)
      return true;

   // Condition B: 20-period BB Bandwidth in bottom 25th percentile of past 100 bars
   double bbw[];
   ArrayResize(bbw, InpBBWPctLookback);
   for(int i = 0; i < InpBBWPctLookback; i++)
     {
      int idx = i + 1; // Bar immediately preceding breakout through 100 bars back
      bbw[i] = (bbMid[idx] > 0.0) ? ((bbUp[idx] - bbLow[idx]) / bbMid[idx]) : 0.0;
     }
   double pct = CalcPercentileRank(bbw, InpBBWPctLookback, bbw[0]);
   return (pct <= InpBBWMaxPercentile);
  }

//+------------------------------------------------------------------+
//| Expert Initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(_Period != PERIOD_H1)
      Print("[WARN] Strategy #3 is designed for H1 execution (with H4 bias). Current TF=", EnumToString(_Period));

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(DetectFillingMode(_Symbol));

   g_barH1.Init(_Symbol, PERIOD_H1);
   g_barH4.Init(_Symbol, PERIOD_H4);

   g_risk.Init(_Symbol, InpPeerSymbol, InpMagicNumber,
               InpBaseRiskPct, InpMaxDailyLossPct, InpMaxWeeklyDDPct,
               InpUseTesterUTCOffset, InpBrokerUTCOffset);

   g_hATR14_H1 = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   g_hATR20_H1 = iATR(_Symbol, PERIOD_H1, InpBBPeriod);
   g_hBB20_H1  = iBands(_Symbol, PERIOD_H1, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   g_hEMA20_H1 = iMA(_Symbol, PERIOD_H1, InpBBPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA50_H4 = iMA(_Symbol, PERIOD_H4, InpH4EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hATR14_H1 == INVALID_HANDLE || g_hATR20_H1 == INVALID_HANDLE ||
      g_hBB20_H1  == INVALID_HANDLE || g_hEMA20_H1 == INVALID_HANDLE ||
      g_hEMA50_H4 == INVALID_HANDLE)
     {
      Print("[ERR] Failed to initialize indicator handles.");
      return INIT_FAILED;
     }

   ZeroMemory(g_pending);
   ZeroMemory(g_pos);

   PrintFormat("[INIT] Strat3_MTF_SqueezeBreakout ready on %s (Magic=%I64d).", _Symbol, InpMagicNumber);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert Deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hATR14_H1 != INVALID_HANDLE) IndicatorRelease(g_hATR14_H1);
   if(g_hATR20_H1 != INVALID_HANDLE) IndicatorRelease(g_hATR20_H1);
   if(g_hBB20_H1  != INVALID_HANDLE) IndicatorRelease(g_hBB20_H1);
   if(g_hEMA20_H1 != INVALID_HANDLE) IndicatorRelease(g_hEMA20_H1);
   if(g_hEMA50_H4 != INVALID_HANDLE) IndicatorRelease(g_hEMA50_H4);
  }

//+------------------------------------------------------------------+
//| Sync Open Position Tracker                                       |
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
         g_pos.ticket          = ticket;
         g_pos.direction       = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         g_pos.entryPrice      = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl             = PositionGetDouble(POSITION_SL);
         g_pos.initialRiskDist = MathAbs(g_pos.entryPrice - sl);
         g_pos.partialTaken    = false;

         if(g_pending.active)
           {
            PrintFormat("[TELEMETRY] Retest limit filled #%I64u | Expected=%.5f Actual=%.5f Slip=%.5f",
                        ticket, g_pending.entryPrice, g_pos.entryPrice, g_pos.entryPrice - g_pending.entryPrice);
            g_pending.active = false;
           }
        }
      return true;
     }

   g_pos.ticket = 0;
   return false;
  }

//+------------------------------------------------------------------+
//| Manage Active Retest Pending Limit Order (3-Bar Expiry & Cancel) |
//+------------------------------------------------------------------+
void ManagePendingOrderOnBarClose(const MqlRates &lastClosedBar)
  {
   if(!g_pending.active)
      return;

   if(!OrderSelect(g_pending.orderTicket))
     {
      g_pending.active = false;
      return;
     }

   g_pending.barsAlive++;

   bool failedBackInside = false;
   if(g_pending.direction == 1 && lastClosedBar.close < g_pending.invalPrice)
      failedBackInside = true;
   if(g_pending.direction == -1 && lastClosedBar.close > g_pending.invalPrice)
      failedBackInside = true;

   if(failedBackInside)
     {
      CancelAllPendingByMagic(g_trade, _Symbol, InpMagicNumber, "FAILED_RETEST_INSIDE_RANGE");
      g_pending.active = false;
      return;
     }

   if(g_pending.barsAlive >= InpRetestExpiryBars)
     {
      CancelAllPendingByMagic(g_trade, _Symbol, InpMagicNumber, "RETEST_3BAR_EXPIRED");
      g_pending.active = false;
     }
  }

//+------------------------------------------------------------------+
//| Manage Open Position: +1.5R Partial/BE, 19:00 Stall, 20:00 Flat  |
//+------------------------------------------------------------------+
void ManageOpenPositionOnBarClose(const int utcHour)
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

   // 1. Optional Zero-Swap Intraday Flat Exit at 20:00 UTC
   if(InpFlatAt20UTC && utcHour >= 20)
     {
      g_trade.PositionClose(g_pos.ticket);
      PrintFormat("[EXIT] Closed #%I64u: 20:00 UTC zero-swap intraday flat.", g_pos.ticket);
      g_pos.ticket = 0;
      return;
     }

   if(g_pos.initialRiskDist <= 0.0)
      return;

   double openR = (g_pos.direction == 1)
                  ? ((curPrice - g_pos.entryPrice) / g_pos.initialRiskDist)
                  : ((g_pos.entryPrice - curPrice) / g_pos.initialRiskDist);

   // 2. Intraday Stall Exit at 19:00 UTC if unrealized P&L in [-0.3R, +0.3R]
   if(utcHour >= InpStallExitHourUTC && MathAbs(openR) <= InpStallBandR)
     {
      g_trade.PositionClose(g_pos.ticket);
      PrintFormat("[EXIT] Closed #%I64u: 19:00 UTC stall exit (openR=%.2fR).", g_pos.ticket, openR);
      g_pos.ticket = 0;
      return;
     }

   // 3. Close 50% at +1.5R and move SL to Breakeven
   if(!g_pos.partialTaken && openR >= InpPartialTriggerR)
     {
      double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double closeVol = MathFloor((curVol * InpPartialCloseFrac) / lotStep) * lotStep;
      closeVol = NormalizeDouble(closeVol, 2);

      if(closeVol >= minLot && (curVol - closeVol) >= minLot)
        {
         if(g_trade.PositionClosePartial(g_pos.ticket, closeVol))
            PrintFormat("[EXIT] Partial %.2f lots closed at +%.2fR on #%I64u.", closeVol, openR, g_pos.ticket);
        }

      double beSL = NormalizePriceToTick(_Symbol, g_pos.entryPrice);
      if((g_pos.direction == 1 && beSL > curSL) || (g_pos.direction == -1 && (curSL == 0.0 || beSL < curSL)))
         g_trade.PositionModify(g_pos.ticket, beSL, curTP);

      g_pos.partialTaken = true;
     }
  }

//+------------------------------------------------------------------+
//| Main Tick Handler (Strict Closed-Bar H1/H4 Execution Loop)       |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_pending.active && CountOpenPositionsByMagic(_Symbol, InpMagicNumber) > 0)
      SyncOpenPosition();

   // Keep H4 tracker updated
   g_barH4.IsNewBar();

   if(!g_barH1.IsNewBar())
      return;

   // Synchronize H1, H4, and D1 series
   if(!IsSeriesSynchronized(_Symbol, PERIOD_H1, 130) ||
      !IsSeriesSynchronized(_Symbol, PERIOD_H4, 65)  ||
      !IsSeriesSynchronized(_Symbol, PERIOD_D1, 40))
      return;

   int neededH1 = InpBBWPctLookback + 5;
   MqlRates ratesH1[];
   ArraySetAsSeries(ratesH1, true);
   if(CopyRates(_Symbol, PERIOD_H1, 1, neededH1, ratesH1) < neededH1)
      return;

   double atr14[], atr20[], bbUp[], bbMid[], bbLow[], ema20[];
   ArraySetAsSeries(atr14, true);
   ArraySetAsSeries(atr20, true);
   ArraySetAsSeries(bbUp,  true);
   ArraySetAsSeries(bbMid, true);
   ArraySetAsSeries(bbLow, true);
   ArraySetAsSeries(ema20, true);

   if(CopyBuffer(g_hATR14_H1, 0, 1, 5, atr14) < 5) return;
   if(CopyBuffer(g_hATR20_H1, 0, 1, neededH1, atr20) < neededH1) return;
   if(CopyBuffer(g_hBB20_H1,  1, 1, neededH1, bbUp)  < neededH1) return;
   if(CopyBuffer(g_hBB20_H1,  0, 1, neededH1, bbMid) < neededH1) return;
   if(CopyBuffer(g_hBB20_H1,  2, 1, neededH1, bbLow) < neededH1) return;
   if(CopyBuffer(g_hEMA20_H1, 0, 1, neededH1, ema20) < neededH1) return;

   double closeH4[], ema50H4[];
   ArraySetAsSeries(closeH4, true);
   ArraySetAsSeries(ema50H4, true);
   if(CopyClose(_Symbol, PERIOD_H4, 1, 3, closeH4) < 3) return;
   if(CopyBuffer(g_hEMA50_H4, 0, 1, 3, ema50H4) < 3) return;

   double h1ATR = atr14[0];
   if(h1ATR <= 0.0)
      return;

   int utcHour = GetUTCHour(InpUseTesterUTCOffset, InpBrokerUTCOffset);
   g_risk.UpdateEquityTrackers();

   // Manage open position & pending retest limit FIRST
   ManageOpenPositionOnBarClose(utcHour);
   ManagePendingOrderOnBarClose(ratesH1[0]);

   // Pre-Trade Risk Firewall
   if(IsRolloverBlackoutUTC(utcHour))
      return;
   // Breakout bar must close between 07:00 and 15:00 UTC
   if(!IsInSessionUTC(utcHour, InpBreakStartUTC, InpBreakEndUTC + 1))
      return;
   if(g_risk.IsCircuitBreakerTripped())
      return;
   if(IsTier1NewsBlackout(InpNewsCurrencies, InpNewsBlackoutMin, InpNewsBlackoutMin, true))
      return;

   if(GetCurrentSpreadPrice(_Symbol) > InpMaxSpreadPrice)
      return;

   if(CountOpenPositionsByMagic(_Symbol, InpMagicNumber) >= 1)
      return;
   if(CountPendingOrdersByMagic(_Symbol, InpMagicNumber) >= 1)
      return;
   if(g_risk.CountTradesTodayUTC() >= InpMaxTradesPerDay)
      return;

   // 1. Preceding Volatility Squeeze Confirmation
   if(!HasPrecedingSqueeze(bbUp, bbMid, bbLow, ema20, atr20))
      return;

   // 2. H4 Directional Bias (Closed H4 bar vs H4 EMA50 + EMA50 slope)
   bool h4Bull = (closeH4[0] > ema50H4[0] && ema50H4[0] > ema50H4[1]);
   bool h4Bear = (closeH4[0] < ema50H4[0] && ema50H4[0] < ema50H4[1]);
   if(!h4Bull && !h4Bear)
      return;

   // 3. Breakout Candle Quality (Closed H1 bar ratesH1[0])
   double barRange = ratesH1[0].high - ratesH1[0].low;
   if(barRange <= 0.0)
      return;
   double bodyRatio = MathAbs(ratesH1[0].close - ratesH1[0].open) / barRange;
   if(bodyRatio <= InpMinBodyRatio)
      return;
   // Strictly between 1.0x and 2.2x H1 ATR(14) (excludes news climax bars)
   if(barRange < InpMinBreakRangeATR * h1ATR || barRange > InpMaxBreakRangeATR * h1ATR)
      return;

   // 4. 12-Bar Consolidation Range (bars 1..12 immediately preceding breakout bar 0)
   double consolHigh = -1e18;
   double consolLow  =  1e18;
   for(int i = 1; i <= InpConsolLookback; i++)
     {
      if(ratesH1[i].high > consolHigh) consolHigh = ratesH1[i].high;
      if(ratesH1[i].low  < consolLow)  consolLow  = ratesH1[i].low;
     }

   int    dir      = 0;
   double boundary = 0.0;
   if(h4Bull && ratesH1[0].close > consolHigh && ratesH1[0].close > ratesH1[0].open)
     {
      dir      = 1;
      boundary = consolHigh;
     }
   else if(h4Bear && ratesH1[0].close < consolLow && ratesH1[0].close < ratesH1[0].open)
     {
      dir      = -1;
      boundary = consolLow;
     }

   if(dir == 0)
      return;

   // 5. Reject if Broken Level Sits Within 0.8x ATR of Major D1 Swing S/R
   if(IsTooCloseToD1SwingSR(boundary, h1ATR))
     {
      PrintFormat("[SKIP] Breakout boundary %.5f too close to D1 swing S/R.", boundary);
      return;
     }

   // 6. Compute Retest Limit Entry, Hard SL, and +2.5R TP
   double entryPrice = (dir == 1) ? (boundary + InpRetestBufferATR * h1ATR)
                                  : (boundary - InpRetestBufferATR * h1ATR);
   double slPrice    = (dir == 1) ? (boundary - InpSLBoundaryATR * h1ATR)
                                  : (boundary + InpSLBoundaryATR * h1ATR);
   double riskDist   = MathAbs(entryPrice - slPrice);
   double tpPrice    = (dir == 1) ? (entryPrice + InpHardTargetR * riskDist)
                                  : (entryPrice - InpHardTargetR * riskDist);
   double invalPrice = (dir == 1) ? (boundary - InpRetestInvalATR * h1ATR)
                                  : (boundary + InpRetestInvalATR * h1ATR);

   entryPrice = NormalizePriceToTick(_Symbol, entryPrice);
   slPrice    = NormalizePriceToTick(_Symbol, slPrice);
   tpPrice    = NormalizePriceToTick(_Symbol, tpPrice);

   // Verify limit price sits on valid side of live market
   double curAsk      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double curBid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minStopDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(dir == 1 && entryPrice >= curAsk - minStopDist)
      return;
   if(dir == -1 && entryPrice <= curBid + minStopDist)
      return;

   // 7. Position Sizing (0.50% Base + DD Governor + 20D Correlation Scaling)
   double lots = g_risk.CalcPositionLots(entryPrice, slPrice, (dir == 1), 1.0);
   if(lots <= 0.0)
      return;

   bool sent = false;
   if(dir == 1)
      sent = g_trade.BuyLimit(lots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "Strat3_Squeeze_Long");
   else
      sent = g_trade.SellLimit(lots, entryPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, "Strat3_Squeeze_Short");

   if(sent)
     {
      g_pending.active        = true;
      g_pending.orderTicket   = g_trade.ResultOrder();
      g_pending.direction     = dir;
      g_pending.boundaryPrice = boundary;
      g_pending.entryPrice    = entryPrice;
      g_pending.invalPrice    = invalPrice;
      g_pending.barsAlive     = 0;

      PrintFormat("[EXEC] Placed %s Retest Limit #%I64u | Lots=%.2f Entry=%.5f SL=%.5f TP=%.5f",
                  (dir == 1 ? "BUY" : "SELL"), g_pending.orderTicket,
                  lots, entryPrice, slPrice, tpPrice);
     }
  }
//+------------------------------------------------------------------+
