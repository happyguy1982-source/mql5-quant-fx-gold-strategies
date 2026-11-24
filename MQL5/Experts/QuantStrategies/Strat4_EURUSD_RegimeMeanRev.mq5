//+------------------------------------------------------------------+
//|                                 Strat4_EURUSD_RegimeMeanRev.mq5  |
//|  Strategy #4: EUR/USD Regime-Gated Z-Score & Bollinger Reversion |
//|  Timeframe: H1 Primary (M15 Secondary Strictly 12:00-16:00 UTC)  |
//|  Regime Gate: H4 ADX < 22, H1 ADX < 20, 200-Bar H1 Hurst < 0.48  |
//+------------------------------------------------------------------+
#property copyright "Quantitative FX/Gold Research Framework"
#property version   "1.00"
#property description "Strategy #4: EUR/USD Regime-Gated Mean Reversion (BB 20/2.2 + RSI 14 + ADX/Hurst Gate)"

#include <Trade\Trade.mqh>
#include <QuantCore\QuantCore.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Identity & Instrument Guard ==="
input long     InpMagicNumber         = 100401;        // Magic Number
input bool     InpRestrictToEURUSD    = true;          // Block Non-EURUSD Symbols (Never Run on XAU!)
input string   InpPeerSymbol          = "XAUUSD";      // Peer Symbol for 20D Correlation Scaling
input bool     InpUseTesterUTCOffset  = true;          // Adjust Tester TimeCurrent() to UTC
input int      InpBrokerUTCOffset     = 2;             // Broker GMT Offset (Hours)
input int      InpSlippagePoints      = 15;            // Max Allowed Deviation (Points)

input group "=== Session, News & Liquidity Filters ==="
input int      InpSessionStartUTC_H1  = 6;             // H1 Session Start Hour (UTC, inclusive)
input int      InpSessionEndUTC_H1    = 16;            // H1 Session End Hour (UTC, exclusive)
input int      InpSessionStartUTC_M15 = 12;            // M15 Overlap Start Hour (UTC, inclusive)
input int      InpSessionEndUTC_M15   = 16;            // M15 Overlap End Hour (UTC, exclusive)
input int      InpNewsBeforeMin       = 120;           // Tier-1 News Blackout BEFORE Event (2 Hours)
input int      InpNewsAfterMin        = 60;            // Tier-1 News Blackout AFTER Event (1 Hour)
input double   InpMaxSpreadPips       = 1.0;           // Max Live Spread (Pips)
input double   InpEstCommissionPips   = 0.7;           // Est. Round-Turn ECN Commission (Pips, ~$7/lot)
input int      InpMaxTradesPerDay     = 2;             // Max Trades Per Day

input group "=== Calm-Range Regime Gate (H4 / H1) ==="
input int      InpADXPeriod           = 14;            // ADX Period (H4 & H1)
input double   InpMaxH4ADX            = 22.0;          // Max H4 ADX(14) (< 22)
input double   InpMaxH1ADX            = 20.0;          // Max H1 ADX(14) (< 20)
input int      InpHurstBarsH1         = 200;           // Rolling H1 Hurst Lookback (200 Bars)
input double   InpMaxHurst            = 0.48;          // Max Hurst Exponent (H < 0.48 Mean-Reverting)
input double   InpMaxATRShockMult     = 1.80;          // Block if H1 ATR(14) > 1.8x Its 50-Bar Mean

input group "=== Mean-Reversion Signal Parameters ==="
input int      InpBBPeriod            = 20;            // Bollinger / SMA Midline Period
input double   InpBBDeviation         = 2.2;           // Bollinger StdDev (Z-Score +/- 2.2)
input int      InpRSIPeriod           = 14;            // RSI Period
input double   InpRSIOversold         = 30.0;          // RSI Oversold Threshold
input double   InpRSIOverbought       = 70.0;          // RSI Overbought Threshold
input bool     InpUseM15StochConfirm  = true;          // Optional Stoch(14,3,3) Cross on M15

input group "=== Risk, Stop-Loss & Exit Management ==="
input double   InpBaseRiskPct         = 0.50;          // Base Risk % Per Trade
input double   InpMaxDailyLossPct     = 1.50;          // Hard Daily Loss Circuit Breaker (%)
input double   InpMaxWeeklyDDPct      = 3.00;          // Hard Weekly DD Circuit Breaker (%)
input double   InpSLATRMult           = 0.75;          // SL Buffer Beyond 2-Bar Extreme (x ATR14)
input double   InpMinSLPips_H1        = 15.0;          // Minimum SL Floor on H1 (Pips)
input double   InpMinSLPips_M15       = 10.0;          // Minimum SL Floor on M15 (Pips)
input double   InpMinNetRR            = 1.00;          // Reject Setup if Net Dist to SMA20 < 1.0R
input bool     InpDynamicSMATarget    = true;          // Update TP Dynamically to Closed-Bar SMA(20)
input int      InpTimeStopBars        = 8;             // Mandatory 8-Bar Time Stop (Elapsed Seconds)
input int      InpFlatExitHourUTC     = 20;            // Mandatory Daily Flat Exit Hour (UTC)
input int      InpFlatExitMinUTC      = 30;            // Mandatory Daily Flat Exit Minute (UTC, 20:30)

//+------------------------------------------------------------------+
//| Global Objects & Handles                                         |
//+------------------------------------------------------------------+
CTrade         g_trade;
CNewBar        g_barExec;
CNewBar        g_barH1;
CNewBar        g_barH4;
CRiskManager   g_risk;

int            g_hBB_Exec    = INVALID_HANDLE;
int            g_hRSI_Exec   = INVALID_HANDLE;
int            g_hATR_Exec   = INVALID_HANDLE;
int            g_hStoch_Exec = INVALID_HANDLE;
int            g_hATR_H1     = INVALID_HANDLE;
int            g_hADX_H1     = INVALID_HANDLE;
int            g_hADX_H4     = INVALID_HANDLE;

double         g_pipSize     = 0.0001;

//+------------------------------------------------------------------+
//| Compute Pip Size (Handles 4/5-digit FX brokers)                  |
//+------------------------------------------------------------------+
double GetPipSize(const string symbol)
  {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3)
      return SymbolInfoDouble(symbol, SYMBOL_POINT) * 10.0;
   return SymbolInfoDouble(symbol, SYMBOL_POINT);
  }

//+------------------------------------------------------------------+
//| Expert Initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   string symUp = _Symbol;
   StringToUpper(symUp);
   if(InpRestrictToEURUSD && StringFind(symUp, "EURUSD") < 0)
     {
      Print("[ERR] Strategy #4 is engineered exclusively for EUR/USD (do NOT run unmodified on XAU/USD).");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(_Period != PERIOD_H1 && _Period != PERIOD_M15)
      Print("[WARN] Strategy #4 is designed for H1 (primary) or M15 (12:00-16:00 UTC overlap). Current TF=", EnumToString(_Period));

   g_pipSize = GetPipSize(_Symbol);

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(DetectFillingMode(_Symbol));

   g_barExec.Init(_Symbol, _Period);
   g_barH1.Init(_Symbol, PERIOD_H1);
   g_barH4.Init(_Symbol, PERIOD_H4);

   g_risk.Init(_Symbol, InpPeerSymbol, InpMagicNumber,
               InpBaseRiskPct, InpMaxDailyLossPct, InpMaxWeeklyDDPct,
               InpUseTesterUTCOffset, InpBrokerUTCOffset);

   g_hBB_Exec    = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   g_hRSI_Exec   = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   g_hATR_Exec   = iATR(_Symbol, _Period, 14);
   g_hStoch_Exec = iStochastic(_Symbol, _Period, 14, 3, 3, MODE_SMA, STO_LOWHIGH);
   g_hATR_H1     = iATR(_Symbol, PERIOD_H1, 14);
   g_hADX_H1     = iADX(_Symbol, PERIOD_H1, InpADXPeriod);
   g_hADX_H4     = iADX(_Symbol, PERIOD_H4, InpADXPeriod);

   if(g_hBB_Exec  == INVALID_HANDLE || g_hRSI_Exec == INVALID_HANDLE ||
      g_hATR_Exec == INVALID_HANDLE || g_hStoch_Exec == INVALID_HANDLE ||
      g_hATR_H1   == INVALID_HANDLE || g_hADX_H1 == INVALID_HANDLE ||
      g_hADX_H4   == INVALID_HANDLE)
     {
      Print("[ERR] Failed to initialize indicator handles.");
      return INIT_FAILED;
     }

   PrintFormat("[INIT] Strat4_EURUSD_RegimeMeanRev ready on %s %s (Magic=%I64d).",
               _Symbol, EnumToString(_Period), InpMagicNumber);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert Deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hBB_Exec    != INVALID_HANDLE) IndicatorRelease(g_hBB_Exec);
   if(g_hRSI_Exec   != INVALID_HANDLE) IndicatorRelease(g_hRSI_Exec);
   if(g_hATR_Exec   != INVALID_HANDLE) IndicatorRelease(g_hATR_Exec);
   if(g_hStoch_Exec != INVALID_HANDLE) IndicatorRelease(g_hStoch_Exec);
   if(g_hATR_H1     != INVALID_HANDLE) IndicatorRelease(g_hATR_H1);
   if(g_hADX_H1     != INVALID_HANDLE) IndicatorRelease(g_hADX_H1);
   if(g_hADX_H4     != INVALID_HANDLE) IndicatorRelease(g_hADX_H4);
  }

//+------------------------------------------------------------------+
//| Manage Open Position: 8-Bar Time Stop, 20:30 UTC Flat, Dyn SMA20 |
//+------------------------------------------------------------------+
void ManageOpenPositionOnBarClose(const double sma20)
  {
   MqlDateTime utc;
   GetUTCTimeStruct(utc, InpUseTesterUTCOffset, InpBrokerUTCOffset);
   bool isFlatTime = (utc.hour > InpFlatExitHourUTC ||
                     (utc.hour == InpFlatExitHourUTC && utc.min >= InpFlatExitMinUTC));

   int timeStopSec = InpTimeStopBars * PeriodSeconds(_Period);
   double minStopDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double curAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      datetime openTm = (datetime)PositionGetInteger(POSITION_TIME);
      long posType    = PositionGetInteger(POSITION_TYPE);
      double curSL    = PositionGetDouble(POSITION_SL);
      double curTP    = PositionGetDouble(POSITION_TP);

      // 1. Mandatory 20:30 UTC Daily Flat Exit
      if(isFlatTime)
        {
         g_trade.PositionClose(ticket);
         PrintFormat("[EXIT] Closed #%I64u: %02d:%02d UTC mandatory flat exit.",
                     ticket, InpFlatExitHourUTC, InpFlatExitMinUTC);
         continue;
        }

      // 2. Mandatory 8-Bar Elapsed-Time Stop
      if((TimeCurrent() - openTm) >= timeStopSec)
        {
         g_trade.PositionClose(ticket);
         PrintFormat("[EXIT] Closed #%I64u: %d-bar time stop reached.", ticket, InpTimeStopBars);
         continue;
        }

      // 3. Dynamic SMA(20) Midline Take-Profit Update
      if(InpDynamicSMATarget && sma20 > 0.0)
        {
         double newTP = NormalizePriceToTick(_Symbol, sma20);
         if(posType == POSITION_TYPE_BUY)
           {
            // If price already reached/crossed SMA20, close immediately
            if(curBid >= newTP)
              {
               g_trade.PositionClose(ticket);
               PrintFormat("[EXIT] Closed LONG #%I64u: Price reached dynamic SMA(20) %.5f.", ticket, newTP);
               continue;
              }
            if(newTP > curBid + minStopDist && MathAbs(newTP - curTP) >= _Point)
               g_trade.PositionModify(ticket, curSL, newTP);
           }
         else if(posType == POSITION_TYPE_SELL)
           {
            if(curAsk <= newTP)
              {
               g_trade.PositionClose(ticket);
               PrintFormat("[EXIT] Closed SHORT #%I64u: Price reached dynamic SMA(20) %.5f.", ticket, newTP);
               continue;
              }
            if(newTP < curAsk - minStopDist && MathAbs(newTP - curTP) >= _Point)
               g_trade.PositionModify(ticket, curSL, newTP);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Main Tick Handler (Strict Closed-Bar Execution Loop)             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Keep HTF trackers updated
   g_barH1.IsNewBar();
   g_barH4.IsNewBar();

   if(!g_barExec.IsNewBar())
      return;

   // Synchronize execution TF, H1, and H4 series
   if(!IsSeriesSynchronized(_Symbol, _Period, 60) ||
      !IsSeriesSynchronized(_Symbol, PERIOD_H1, InpHurstBarsH1 + 10) ||
      !IsSeriesSynchronized(_Symbol, PERIOD_H4, 50))
      return;

   // Fetch closed execution bars (index 0 = bar t [shift 1], index 1 = bar t-1 [shift 2])
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 5, rates) < 5)
      return;

   double bbUp[], bbMid[], bbLow[], rsi[], atrExec[];
   ArraySetAsSeries(bbUp,    true);
   ArraySetAsSeries(bbMid,   true);
   ArraySetAsSeries(bbLow,   true);
   ArraySetAsSeries(rsi,     true);
   ArraySetAsSeries(atrExec, true);

   if(CopyBuffer(g_hBB_Exec,  1, 1, 3, bbUp)    < 3) return;
   if(CopyBuffer(g_hBB_Exec,  0, 1, 3, bbMid)   < 3) return;
   if(CopyBuffer(g_hBB_Exec,  2, 1, 3, bbLow)   < 3) return;
   if(CopyBuffer(g_hRSI_Exec, 0, 1, 3, rsi)     < 3) return;
   if(CopyBuffer(g_hATR_Exec, 0, 1, 3, atrExec) < 3) return;

   double atrH1[], adxH1[], adxH4[];
   ArraySetAsSeries(atrH1, true);
   ArraySetAsSeries(adxH1, true);
   ArraySetAsSeries(adxH4, true);

   if(CopyBuffer(g_hATR_H1, 0, 1, 50, atrH1) < 50) return;
   if(CopyBuffer(g_hADX_H1, 0, 1, 2,  adxH1) < 2)  return;
   if(CopyBuffer(g_hADX_H4, 0, 1, 2,  adxH4) < 2)  return;

   double closeH1[];
   ArraySetAsSeries(closeH1, true);
   if(CopyClose(_Symbol, PERIOD_H1, 1, InpHurstBarsH1, closeH1) < InpHurstBarsH1)
      return;

   g_risk.UpdateEquityTrackers();

   // Manage open positions FIRST (8-bar time stop, 20:30 UTC flat, dynamic SMA20 TP)
   ManageOpenPositionOnBarClose(bbMid[0]);

   // Pre-Trade Risk Firewall
   int utcHour = GetUTCHour(InpUseTesterUTCOffset, InpBrokerUTCOffset);
   if(IsRolloverBlackoutUTC(utcHour))
      return;

   int sessStart = (_Period == PERIOD_M15) ? InpSessionStartUTC_M15 : InpSessionStartUTC_H1;
   int sessEnd   = (_Period == PERIOD_M15) ? InpSessionEndUTC_M15   : InpSessionEndUTC_H1;
   if(!IsInSessionUTC(utcHour, sessStart, sessEnd))
      return;

   if(g_risk.IsCircuitBreakerTripped())
      return;

   // Asymmetric Tier-1 News Blackout: 2h prior through 1h post FOMC, ECB, CPI, NFP
   if(IsTier1NewsBlackout("USD,EUR", InpNewsBeforeMin, InpNewsAfterMin, true))
      return;

   double spreadPrice = GetCurrentSpreadPrice(_Symbol);
   if(spreadPrice > InpMaxSpreadPips * g_pipSize)
      return;

   if(CountOpenPositionsByMagic(_Symbol, InpMagicNumber) >= 1)
      return;
   if(g_risk.CountTradesTodayUTC() >= InpMaxTradesPerDay)
      return;

   // 1. Calm-Range Regime Gate: H4 ADX < 22, H1 ADX < 20, H1 Hurst(200) < 0.48
   if(adxH4[0] >= InpMaxH4ADX || adxH1[0] >= InpMaxH1ADX)
      return;

   // Volatility Shock Guard: H1 ATR(14) <= 1.8x its 50-bar mean
   double atr50Mean = 0.0;
   for(int i = 0; i < 50; i++)
      atr50Mean += atrH1[i];
   atr50Mean /= 50.0;
   if(atr50Mean > 0.0 && atrH1[0] > InpMaxATRShockMult * atr50Mean)
      return;

   double hurstH1 = CalcHurstRS(closeH1, InpHurstBarsH1);
   if(hurstH1 >= InpMaxHurst)
      return;

   // 2. Optional M15 Stochastic(14,3,3) Confirmation
   bool stochBullOK = true;
   bool stochBearOK = true;
   if(_Period == PERIOD_M15 && InpUseM15StochConfirm)
     {
      double stK[], stD[];
      ArraySetAsSeries(stK, true);
      ArraySetAsSeries(stD, true);
      if(CopyBuffer(g_hStoch_Exec, 0, 1, 3, stK) < 3) return;
      if(CopyBuffer(g_hStoch_Exec, 1, 1, 3, stD) < 3) return;
      stochBullOK = (stK[1] <= stD[1] && stK[0] > stD[0] && stK[0] < 25.0);
      stochBearOK = (stK[1] >= stD[1] && stK[0] < stD[0] && stK[0] > 75.0);
     }

   // 3. Mean-Reversion Entry Signal (Closed Bar t-1 [idx 1] & Bar t [idx 0])
   // Long: bar t-1 closes below lower BB(20, 2.2) with RSI < 30;
   //       bar t closes back INSIDE lower BB with RSI crossing back above 30
   bool bullSignal = (rates[1].close < bbLow[1] && rsi[1] < InpRSIOversold &&
                      rates[0].close > bbLow[0] && rsi[0] > InpRSIOversold &&
                      stochBullOK);

   // Short: bar t-1 closes above upper BB(20, 2.2) with RSI > 70;
   //        bar t closes back INSIDE upper BB with RSI crossing back below 70
   bool bearSignal = (rates[1].close > bbUp[1] && rsi[1] > InpRSIOverbought &&
                      rates[0].close < bbUp[0] && rsi[0] < InpRSIOverbought &&
                      stochBearOK);

   if(!bullSignal && !bearSignal)
      return;

   bool isBuy = bullSignal;

   // Never Fade a Breaking Range Twice: Max 1 consecutive loss in the same direction today
   if(g_risk.HadLossTodayInDirection(isBuy))
     {
      PrintFormat("[SKIP] Blocked %s re-entry: already took a loss in this direction today.",
                  isBuy ? "LONG" : "SHORT");
      return;
     }

   // 4. Hard ATR Stop-Loss with Minimum Pip Floor (15p H1 / 10p M15)
   double entryPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minFloor   = ((_Period == PERIOD_M15) ? InpMinSLPips_M15 : InpMinSLPips_H1) * g_pipSize;

   double rawSL = 0.0;
   if(isBuy)
     {
      double twoBarLow = MathMin(rates[1].low, rates[0].low);
      rawSL = twoBarLow - InpSLATRMult * atrExec[0];
      if((entryPrice - rawSL) < minFloor)
         rawSL = entryPrice - minFloor;
     }
   else
     {
      double twoBarHigh = MathMax(rates[1].high, rates[0].high);
      rawSL = twoBarHigh + InpSLATRMult * atrExec[0];
      if((rawSL - entryPrice) < minFloor)
         rawSL = entryPrice + minFloor;
     }

   double slPrice  = NormalizePriceToTick(_Symbol, rawSL);
   double tpPrice  = NormalizePriceToTick(_Symbol, bbMid[0]);
   double riskDist = MathAbs(entryPrice - slPrice);
   double rawRew   = isBuy ? (tpPrice - entryPrice) : (entryPrice - tpPrice);

   // 5. Pre-Entry Net R:R Gate: Reject if net distance to SMA(20) < 1.0R
   double estCost  = spreadPrice + InpEstCommissionPips * g_pipSize;
   double netRew   = rawRew - estCost;
   if(riskDist <= 0.0 || netRew < InpMinNetRR * riskDist)
     {
      PrintFormat("[SKIP] Insufficient net R:R to SMA20 (netRew=%.5f < %.2f * risk=%.5f).",
                  netRew, InpMinNetRR, riskDist);
      return;
     }

   // 6. Position Sizing (0.50% Base + DD Governor + 20D Correlation Scaling)
   double lots = g_risk.CalcPositionLots(entryPrice, slPrice, isBuy, 1.0);
   if(lots <= 0.0)
      return;

   bool sent = false;
   if(isBuy)
      sent = g_trade.Buy(lots, _Symbol, entryPrice, slPrice, tpPrice, "Strat4_MR_Long");
   else
      sent = g_trade.Sell(lots, _Symbol, entryPrice, slPrice, tpPrice, "Strat4_MR_Short");

   if(sent)
     {
      double fillPrice = g_trade.ResultPrice();
      PrintFormat("[EXEC] %s #%I64u | Lots=%.2f Fill=%.5f (Exp=%.5f) SL=%.5f TP=%.5f | ADX_H4=%.1f ADX_H1=%.1f Hurst=%.3f",
                  (isBuy ? "BUY" : "SELL"), g_trade.ResultOrder(), lots, fillPrice, entryPrice,
                  slPrice, tpPrice, adxH4[0], adxH1[0], hurstH1);
     }
  }
//+------------------------------------------------------------------+
