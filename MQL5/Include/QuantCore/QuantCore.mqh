//+------------------------------------------------------------------+
//|                                                    QuantCore.mqh |
//|     Institutional Non-Repainting Core Library for MT5 (MQL5)     |
//|   Implements Deliverable C & E: Closed-Bar Sync, Risk Firewall,  |
//|  DD Governor, 20D Correlation Scaling, News Blackout, & Metrics  |
//+------------------------------------------------------------------+
#ifndef __QUANT_CORE_MQH__
#define __QUANT_CORE_MQH__

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Module 1: Per-Timeframe Non-Repainting New-Bar Tracker           |
//| Primed in OnInit() so attaching mid-bar never fires prematurely  |
//+------------------------------------------------------------------+
class CNewBar
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   datetime          m_lastBarTime;
   bool              m_primed;

public:
                     CNewBar() : m_symbol(""), m_tf(PERIOD_CURRENT), m_lastBarTime(0), m_primed(false) {}

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_primed = false;
      datetime t = iTime(m_symbol, m_tf, 0);
      if(t > 0)
        {
         m_lastBarTime = t;
         m_primed      = true;
         return true;
        }
      return false;
     }

   bool              IsNewBar()
     {
      datetime currentBarTime = iTime(m_symbol, m_tf, 0);
      if(currentBarTime <= 0)
         return false; // Guard against terminal history loading (iTime == 0)

      if(!m_primed)
        {
         m_lastBarTime = currentBarTime;
         m_primed      = true;
         return false; // Prime on first valid bar without triggering mid-candle
        }

      if(currentBarTime != m_lastBarTime)
        {
         m_lastBarTime = currentBarTime;
         return true;
        }
      return false;
     }

   datetime          LastBarTime() const { return m_lastBarTime; }
  };

//+------------------------------------------------------------------+
//| Synchronize Secondary Timeframe History (Prevents Error 4806)    |
//+------------------------------------------------------------------+
bool IsSeriesSynchronized(const string symbol, const ENUM_TIMEFRAMES tf, const int minBars = 100)
  {
   if(!SymbolSelect(symbol, true))
      return false;
   if(!SeriesInfoInteger(symbol, tf, SERIES_SYNCHRONIZED))
      return false;
   if(Bars(symbol, tf) < minBars)
      return false;
   if(iTime(symbol, tf, 0) <= 0)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| UTC Clock Helper (Handles Live TimeGMT & Strategy Tester Offset) |
//+------------------------------------------------------------------+
datetime GetUTCNow(const bool useTesterOffset = true, const int brokerUTCOffsetHours = 2)
  {
   if(MQLInfoInteger(MQL_TESTER) && useTesterOffset)
      return (TimeCurrent() - brokerUTCOffsetHours * 3600);
   return TimeGMT();
  }

int GetUTCHour(const bool useTesterOffset = true, const int brokerUTCOffsetHours = 2)
  {
   MqlDateTime dt;
   TimeToStruct(GetUTCNow(useTesterOffset, brokerUTCOffsetHours), dt);
   return dt.hour;
  }

void GetUTCTimeStruct(MqlDateTime &dt, const bool useTesterOffset = true, const int brokerUTCOffsetHours = 2)
  {
   TimeToStruct(GetUTCNow(useTesterOffset, brokerUTCOffsetHours), dt);
  }

bool IsRolloverBlackoutUTC(const int utcHour)
  {
   // Deliverable A/E: Hard execution blackout 20:00–23:59 UTC
   return (utcHour >= 20 && utcHour <= 23);
  }

bool IsInSessionUTC(const int utcHour, const int startHourUTC, const int endHourUTC)
  {
   if(startHourUTC <= endHourUTC)
      return (utcHour >= startHourUTC && utcHour < endHourUTC);
   return (utcHour >= startHourUTC || utcHour < endHourUTC);
  }

//+------------------------------------------------------------------+
//| Tier-1 Economic Calendar News Blackout (Native MT5 Calendar API) |
//| Filters FOMC, ECB, US CPI, NFP, Core PCE within [before, after]  |
//+------------------------------------------------------------------+
bool IsTier1NewsBlackout(const string currenciesCSV,
                         const int minutesBefore,
                         const int minutesAfter,
                         const bool filterKeywordsOnly = true)
  {
   // Native MT5 Calendar API is unavailable inside Strategy Tester
   if(MQLInfoInteger(MQL_TESTER))
      return false;

   datetime nowServer = TimeTradeServer();
   datetime fromTime  = nowServer - minutesAfter * 60;
   datetime toTime    = nowServer + minutesBefore * 60;

   MqlCalendarValue values[];
   if(CalendarValueHistory(values, fromTime, toTime) <= 0)
      return false;

   int total = ArraySize(values);
   for(int i = 0; i < total; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(ev.country_id, country))
         continue;

      if(StringFind(currenciesCSV, country.currency) < 0)
         continue;

      if(!filterKeywordsOnly)
         return true;

      string nameUp = ev.name;
      StringToUpper(nameUp);
      if(StringFind(nameUp, "FOMC") >= 0 ||
         StringFind(nameUp, "FEDERAL FUNDS") >= 0 ||
         StringFind(nameUp, "INTEREST RATE") >= 0 ||
         StringFind(nameUp, "ECB") >= 0 ||
         StringFind(nameUp, "CPI") >= 0 ||
         StringFind(nameUp, "CONSUMER PRICE") >= 0 ||
         StringFind(nameUp, "NONFARM") >= 0 ||
         StringFind(nameUp, "NON-FARM") >= 0 ||
         StringFind(nameUp, "PAYROLL") >= 0 ||
         StringFind(nameUp, "PCE") >= 0)
        {
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Module 2: Math & Statistical Helpers                             |
//+------------------------------------------------------------------+
double ClampDouble(const double val, const double minVal, const double maxVal)
  {
   if(val < minVal) return minVal;
   if(val > maxVal) return maxVal;
   return val;
  }

// Percentile rank of `value` within `arr[0..count-1]` in [0.0, 100.0]
double CalcPercentileRank(const double &arr[], const int count, const double value)
  {
   if(count <= 0)
      return 50.0;
   int lessOrEqual = 0;
   for(int i = 0; i < count; i++)
     {
      if(arr[i] <= value)
         lessOrEqual++;
     }
   return (100.0 * (double)lessOrEqual / (double)count);
  }

// 20-day Rolling Pearson Correlation of D1 log returns between symA & symB
double CalcRollingReturnCorrelationD1(const string symA, const string symB, const int window = 20)
  {
   if(symA == "" || symB == "" || symA == symB)
      return 0.0;
   if(!SymbolSelect(symA, true) || !SymbolSelect(symB, true))
      return 0.0;

   double closeA[], closeB[];
   ArraySetAsSeries(closeA, true);
   ArraySetAsSeries(closeB, true);

   int needed = window + 1;
   if(CopyClose(symA, PERIOD_D1, 1, needed, closeA) < needed)
      return 0.0;
   if(CopyClose(symB, PERIOD_D1, 1, needed, closeB) < needed)
      return 0.0;

   double retA[], retB[];
   ArrayResize(retA, window);
   ArrayResize(retB, window);

   double meanA = 0.0, meanB = 0.0;
   for(int i = 0; i < window; i++)
     {
      if(closeA[i + 1] <= 0.0 || closeB[i + 1] <= 0.0)
         return 0.0;
      retA[i] = MathLog(closeA[i] / closeA[i + 1]);
      retB[i] = MathLog(closeB[i] / closeB[i + 1]);
      meanA  += retA[i];
      meanB  += retB[i];
     }
   meanA /= window;
   meanB /= window;

   double cov = 0.0, varA = 0.0, varB = 0.0;
   for(int i = 0; i < window; i++)
     {
      double da = retA[i] - meanA;
      double db = retB[i] - meanB;
      cov  += da * db;
      varA += da * da;
      varB += db * db;
     }

   double denom = MathSqrt(varA * varB);
   if(denom <= 1e-12)
      return 0.0;
   return ClampDouble(cov / denom, -1.0, 1.0);
  }

// Rolling Rescaled-Range (R/S) Hurst Exponent on closed-bar log returns
// Expects closes[] in chronological order (oldest -> newest) or series order
double CalcHurstRS(const double &closesSeries[], const int barCount)
  {
   int nRet = barCount - 1;
   if(nRet < 40)
      return 0.50;

   // Convert series (index 0 = newest) to chronological log returns
   double r[];
   ArrayResize(r, nRet);
   for(int i = 0; i < nRet; i++)
     {
      double prev = closesSeries[nRet - i];
      double curr = closesSeries[nRet - 1 - i];
      if(prev <= 0.0 || curr <= 0.0)
         return 0.50;
      r[i] = MathLog(curr / prev);
     }

   // Sub-window lengths for R/S regression
   int lags[] = {8, 12, 16, 24, 32, 48, 64, 96};
   double logN[], logRS[];
   int pts = 0;
   ArrayResize(logN, ArraySize(lags));
   ArrayResize(logRS, ArraySize(lags));

   for(int k = 0; k < ArraySize(lags); k++)
     {
      int m = lags[k];
      int numChunks = nRet / m;
      if(numChunks < 2)
         continue;

      double rsSum = 0.0;
      int validChunks = 0;

      for(int c = 0; c < numChunks; c++)
        {
         int start = c * m;
         double mean = 0.0;
         for(int j = 0; j < m; j++)
            mean += r[start + j];
         mean /= m;

         double cumDev = 0.0, maxDev = -1e18, minDev = 1e18;
         double varSum = 0.0;
         for(int j = 0; j < m; j++)
           {
            double d = r[start + j] - mean;
            cumDev += d;
            if(cumDev > maxDev) maxDev = cumDev;
            if(cumDev < minDev) minDev = cumDev;
            varSum += d * d;
           }

         double stdDev = MathSqrt(varSum / m);
         if(stdDev > 1e-12)
           {
            rsSum += (maxDev - minDev) / stdDev;
            validChunks++;
           }
        }

      if(validChunks > 0)
        {
         double avgRS = rsSum / validChunks;
         if(avgRS > 1e-12)
           {
            logN[pts]  = MathLog((double)m);
            logRS[pts] = MathLog(avgRS);
            pts++;
           }
        }
     }

   if(pts < 3)
      return 0.50;

   // OLS slope of log(R/S) vs log(n)
   double sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0;
   for(int i = 0; i < pts; i++)
     {
      sumX  += logN[i];
      sumY  += logRS[i];
      sumXY += logN[i] * logRS[i];
      sumXX += logN[i] * logN[i];
     }
   double denom = pts * sumXX - sumX * sumX;
   if(MathAbs(denom) <= 1e-12)
      return 0.50;

   double H = (pts * sumXY - sumX * sumY) / denom;
   return ClampDouble(H, 0.05, 0.95);
  }

//+------------------------------------------------------------------+
//| Module 3: Quantitative Risk Management & Correlation Firewall    |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   string            m_symbol;
   string            m_peerSymbol;
   long              m_magic;
   double            m_baseRiskPct;
   double            m_maxDailyLossPct;
   double            m_maxWeeklyDDPct;
   double            m_ddGovTriggerPct;
   double            m_ddGovRestorePct;
   int               m_consecLossTrigger;
   double            m_corrThreshold;
   int               m_corrWindowD1;
   bool              m_useTesterOffset;
   int               m_brokerUTCOffset;

   double            m_hwmEquity;
   double            m_dayStartEquity;
   double            m_weekStartEquity;
   int               m_lastDayOfYear;
   int               m_lastWeekKey;
   bool              m_governorActive;
   bool              m_dailyTripped;
   bool              m_weeklyTripped;

   int               GetWeekKey(const MqlDateTime &dt)
     {
      // ISO-like weekly bucket (year * 100 + week_index)
      int weekIdx = (dt.day_of_year - ((dt.day_of_week == 0 ? 7 : dt.day_of_week) - 1) + 10) / 7;
      return dt.year * 100 + weekIdx;
     }

public:
                     CRiskManager()
     {
      m_symbol            = "";
      m_peerSymbol        = "";
      m_magic             = 0;
      m_baseRiskPct       = 0.50;
      m_maxDailyLossPct   = 1.50;
      m_maxWeeklyDDPct    = 3.00;
      m_ddGovTriggerPct   = 6.00;
      m_ddGovRestorePct   = 2.00;
      m_consecLossTrigger = 6;
      m_corrThreshold     = 0.50;
      m_corrWindowD1      = 20;
      m_useTesterOffset   = true;
      m_brokerUTCOffset   = 2;
      m_hwmEquity         = 0.0;
      m_dayStartEquity    = 0.0;
      m_weekStartEquity   = 0.0;
      m_lastDayOfYear     = -1;
      m_lastWeekKey       = -1;
      m_governorActive    = false;
      m_dailyTripped      = false;
      m_weeklyTripped     = false;
     }

   void              Init(const string symbol,
                          const string peerSymbol,
                          const long magic,
                          const double baseRiskPct = 0.50,
                          const double maxDailyLossPct = 1.50,
                          const double maxWeeklyDDPct = 3.00,
                          const bool useTesterOffset = true,
                          const int brokerUTCOffset = 2)
     {
      m_symbol          = symbol;
      m_peerSymbol      = peerSymbol;
      m_magic           = magic;
      m_baseRiskPct     = baseRiskPct;
      m_maxDailyLossPct = maxDailyLossPct;
      m_maxWeeklyDDPct  = maxWeeklyDDPct;
      m_useTesterOffset = useTesterOffset;
      m_brokerUTCOffset = brokerUTCOffset;

      double eq         = AccountInfoDouble(ACCOUNT_EQUITY);
      m_hwmEquity       = eq;
      m_dayStartEquity  = eq;
      m_weekStartEquity = eq;

      MqlDateTime dt;
      GetUTCTimeStruct(dt, m_useTesterOffset, m_brokerUTCOffset);
      m_lastDayOfYear   = dt.day_of_year;
      m_lastWeekKey     = GetWeekKey(dt);
      m_governorActive  = false;
      m_dailyTripped    = false;
      m_weeklyTripped   = false;
     }

   void              UpdateEquityTrackers()
     {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > m_hwmEquity)
         m_hwmEquity = eq;

      MqlDateTime dt;
      GetUTCTimeStruct(dt, m_useTesterOffset, m_brokerUTCOffset);
      int wk = GetWeekKey(dt);

      if(dt.day_of_year != m_lastDayOfYear)
        {
         m_lastDayOfYear  = dt.day_of_year;
         m_dayStartEquity = eq;
         m_dailyTripped   = false;
        }
      if(wk != m_lastWeekKey)
        {
         m_lastWeekKey     = wk;
         m_weekStartEquity = eq;
         m_weeklyTripped   = false;
        }

      double ddFromHWM = (m_hwmEquity > 0.0) ? (100.0 * (m_hwmEquity - eq) / m_hwmEquity) : 0.0;
      int consecLosses = CountConsecutiveLosses();

      if(!m_governorActive)
        {
         if(ddFromHWM >= m_ddGovTriggerPct || consecLosses >= m_consecLossTrigger)
           {
            m_governorActive = true;
            PrintFormat("[RISK] Drawdown Governor ACTIVATED (DD=%.2f%%, ConsecLosses=%d). Halving risk.", ddFromHWM, consecLosses);
           }
        }
      else
        {
         // Restore full risk only when equity recovers within 2% of HWM
         if(ddFromHWM <= m_ddGovRestorePct)
           {
            m_governorActive = false;
            PrintFormat("[RISK] Drawdown Governor RESTORED (DD=%.2f%% <= %.2f%%).", ddFromHWM, m_ddGovRestorePct);
           }
        }

      double dailyLossPct  = (m_dayStartEquity > 0.0) ? (100.0 * (m_dayStartEquity - eq) / m_dayStartEquity) : 0.0;
      double weeklyLossPct = (m_weekStartEquity > 0.0) ? (100.0 * (m_weekStartEquity - eq) / m_weekStartEquity) : 0.0;

      if(dailyLossPct >= m_maxDailyLossPct && !m_dailyTripped)
        {
         m_dailyTripped = true;
         PrintFormat("[RISK] CIRCUIT_BREAKER_TRIPPED: Daily Loss %.2f%% >= %.2f%%", dailyLossPct, m_maxDailyLossPct);
        }
      if(weeklyLossPct >= m_maxWeeklyDDPct && !m_weeklyTripped)
        {
         m_weeklyTripped = true;
         PrintFormat("[RISK] CIRCUIT_BREAKER_TRIPPED: Weekly DD %.2f%% >= %.2f%%", weeklyLossPct, m_maxWeeklyDDPct);
        }
     }

   bool              IsCircuitBreakerTripped() const { return (m_dailyTripped || m_weeklyTripped); }
   bool              IsGovernorActive()        const { return m_governorActive; }

   // Count consecutive losing closed deals for this strategy's magic number
   int               CountConsecutiveLosses()
     {
      if(!HistorySelect(0, TimeCurrent()))
         return 0;
      int total = HistoryDealsTotal();
      int streak = 0;
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_symbol) continue;
         long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT) continue;

         double netPnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                         + HistoryDealGetDouble(ticket, DEAL_SWAP)
                         + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         if(netPnl < 0.0)
            streak++;
         else
            break;
        }
      return streak;
     }

   // Count entries opened today (UTC day) for this magic number
   int               CountTradesTodayUTC()
     {
      MqlDateTime dt;
      GetUTCTimeStruct(dt, m_useTesterOffset, m_brokerUTCOffset);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime utcDayStart = StructToTime(dt);
      datetime serverDayStart = utcDayStart + (MQLInfoInteger(MQL_TESTER) && m_useTesterOffset ? m_brokerUTCOffset * 3600 : (int)(TimeCurrent() - TimeGMT()));

      if(!HistorySelect(serverDayStart - 3600, TimeCurrent() + 60))
         return 0;

      int count = 0;
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_symbol) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         if(dealTime >= serverDayStart)
            count++;
        }
      return count;
     }

   // Check if last closed deal today in the same direction was a loss (for Strat #4)
   bool              HadLossTodayInDirection(const bool isBuy)
     {
      MqlDateTime dt;
      GetUTCTimeStruct(dt, m_useTesterOffset, m_brokerUTCOffset);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime utcDayStart = StructToTime(dt);
      datetime serverDayStart = utcDayStart + (MQLInfoInteger(MQL_TESTER) && m_useTesterOffset ? m_brokerUTCOffset * 3600 : (int)(TimeCurrent() - TimeGMT()));

      if(!HistorySelect(serverDayStart - 3600, TimeCurrent() + 60))
         return false;

      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_symbol) continue;
         long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT) continue;
         if((datetime)HistoryDealGetInteger(ticket, DEAL_TIME) < serverDayStart) break;

         // Exit deal type is opposite of position direction: DEAL_TYPE_SELL closes a BUY
         long dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
         bool posWasBuy = (dealType == DEAL_TYPE_SELL);
         if(posWasBuy != isBuy)
            continue;

         double netPnl = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                         + HistoryDealGetDouble(ticket, DEAL_SWAP)
                         + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         return (netPnl < 0.0);
        }
      return false;
     }

   // Check if peer symbol has an open position in the same USD direction
   // Both EURUSD and XAUUSD have USD as quote currency -> BUY=short USD, SELL=long USD
   bool              HasSameDirectionPeerPosition(const bool isBuy) const
     {
      if(m_peerSymbol == "")
         return false;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_peerSymbol) continue;
         long posType = PositionGetInteger(POSITION_TYPE);
         if((isBuy && posType == POSITION_TYPE_BUY) || (!isBuy && posType == POSITION_TYPE_SELL))
            return true;
        }
      return false;
     }

   // Compute dynamic correlation scalar: sqrt(2 / (2 + 2*rho)) when rho > 0.50
   double            GetCorrelationScalar(const bool isBuy) const
     {
      if(!HasSameDirectionPeerPosition(isBuy))
         return 1.0;
      double rho = CalcRollingReturnCorrelationD1(m_symbol, m_peerSymbol, m_corrWindowD1);
      if(rho > m_corrThreshold)
         return MathSqrt(2.0 / (2.0 + 2.0 * rho));
      return 1.0;
     }

   // Exact ATR-normalized fixed-fractional lot size
   double            CalcPositionLots(const double entryPrice,
                                      const double slPrice,
                                      const bool isBuy,
                                      const double mlScalar = 1.0) const
     {
      double slDist = MathAbs(entryPrice - slPrice);
      if(slDist <= 0.0)
         return 0.0;

      double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskPct  = m_governorActive ? (m_baseRiskPct * 0.5) : m_baseRiskPct;
      double corrMult = GetCorrelationScalar(isBuy);
      double riskUSD  = equity * (riskPct / 100.0) * corrMult * mlScalar;

      double tickSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0.0)
         tickVal = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickVal <= 0.0)
         return 0.0;

      double lossPerLot = (slDist / tickSize) * tickVal;
      if(lossPerLot <= 0.0)
         return 0.0;

      double rawLots  = riskUSD / lossPerLot;
      double minLot   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double maxLot   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double lotStep  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);

      double lots = MathFloor(rawLots / lotStep) * lotStep;
      lots = ClampDouble(lots, minLot, maxLot);
      return NormalizeDouble(lots, 2);
     }
  };

//+------------------------------------------------------------------+
//| Module 4: Order & Position Helpers                               |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingMode(const string symbol)
  {
   long filling = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

int CountOpenPositionsByMagic(const string symbol, const long magic)
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_MAGIC) == magic)
         count++;
     }
   return count;
  }

int CountPendingOrdersByMagic(const string symbol, const long magic)
  {
   int count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == symbol &&
         OrderGetInteger(ORDER_MAGIC) == magic)
         count++;
     }
   return count;
  }

void CancelAllPendingByMagic(CTrade &trade, const string symbol, const long magic, const string reason)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == symbol &&
         OrderGetInteger(ORDER_MAGIC) == magic)
        {
         if(trade.OrderDelete(ticket))
            PrintFormat("[EXEC] Cancelled pending order #%I64u (%s)", ticket, reason);
        }
     }
  }

void CloseAllPositionsByMagic(CTrade &trade, const string symbol, const long magic, const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_MAGIC) == magic)
        {
         if(trade.PositionClose(ticket))
            PrintFormat("[EXEC] Closed position #%I64u (%s)", ticket, reason);
        }
     }
  }

double GetCurrentSpreadPrice(const string symbol)
  {
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   return (ask - bid);
  }

double NormalizePriceToTick(const string symbol, const double price)
  {
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits      = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, digits);
  }

#endif // __QUANT_CORE_MQH__
