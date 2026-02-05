//+------------------------------------------------------------------+
//|                                       TrendFollowing EA V1.0.mq5 |
//|                                   Portfolio Management Suite     |
//|         Professional Trend Following with Pullback Entry         |
//+------------------------------------------------------------------+
#property copyright "Portfolio Management Suite"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                      |
//+------------------------------------------------------------------+
enum ENUM_TRADE_DIRECTION
{
   TRADE_BOTH = 0,        // Both Directions
   TRADE_LONG_ONLY = 1,   // Long Only
   TRADE_SHORT_ONLY = 2   // Short Only
};

enum ENUM_HTF_TIMEFRAME
{
   HTF_H4 = 0,   // H4
   HTF_D1 = 1,   // D1
   HTF_W1 = 2    // W1
};

enum ENUM_MA_METHOD_SELECT
{
   MA_EMA = 0,   // Exponential (EMA)
   MA_SMA = 1,   // Simple (SMA)
   MA_SMMA = 2,  // Smoothed (SMMA)
   MA_LWMA = 3   // Linear Weighted (LWMA)
};

enum ENUM_ENTRY_MODE
{
   ENTRY_CROSSOVER = 0,   // On Crossover (Aggressive)
   ENTRY_PULLBACK = 1     // On Pullback to Fast MA (Conservative)
};

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy Settings ==="
input int               FastMAPeriod       = 21;              // Fast MA Period
input int               SlowMAPeriod       = 50;              // Slow MA Period
input ENUM_MA_METHOD_SELECT MAMethod       = MA_EMA;          // MA Method
input ENUM_ENTRY_MODE   EntryMode          = ENTRY_PULLBACK;  // Entry Mode
input ENUM_TRADE_DIRECTION TradeDirection  = TRADE_BOTH;      // Trade Direction

input group "=== Trend Filters ==="
input bool              UseADXFilter       = true;            // Use ADX Filter
input int               ADXPeriod          = 14;              // ADX Period
input double            ADXMinimum         = 25.0;            // Minimum ADX Value
input bool              UseHTFFilter       = true;            // Use Higher Timeframe Filter
input ENUM_HTF_TIMEFRAME HTFTimeframe      = HTF_H4;          // Higher Timeframe

input group "=== Pullback Settings ==="
input double            PullbackZoneATR    = 0.5;             // Pullback Zone (ATR from Fast MA)
input int               MaxBarsAfterCross  = 10;              // Max Bars After Crossover for Entry
input bool              RequireBounce      = true;            // Require Price Bounce from MA

input group "=== Risk Management ==="
input double            RiskPercent        = 1.0;             // Risk Per Trade (%)
input double            ATRMultiplierSL    = 2.0;             // Stop Loss (ATR Multiplier)
input int               ATRPeriod          = 14;              // ATR Period
input double            MaxSpreadPoints    = 30;              // Max Spread (Points, 0=disabled)

input group "=== Take Profit & Exit ==="
input double            ATRMultiplierTP    = 4.0;             // Take Profit (ATR Multiplier, 0=disabled)
input bool              UseTrailingStop    = true;            // Use Trailing Stop
input double            TrailingATRMult    = 1.5;             // Trailing Stop (ATR Multiplier)
input double            TrailingStartATR   = 2.0;             // Start Trailing After (ATR in profit)
input bool              CloseOnOppositeCross = true;          // Close on Opposite MA Cross

input group "=== Session Filter ==="
input bool              UseSessionFilter   = true;            // Use Session Filter
input int               SessionStartHour   = 8;               // Session Start Hour (Server Time)
input int               SessionEndHour     = 20;              // Session End Hour (Server Time)
input bool              TradeSunday        = false;           // Trade on Sunday
input bool              TradeMonday        = true;            // Trade on Monday
input bool              TradeTuesday       = true;            // Trade on Tuesday
input bool              TradeWednesday     = true;            // Trade on Wednesday
input bool              TradeThursday      = true;            // Trade on Thursday
input bool              TradeFriday        = true;            // Trade on Friday (until 20:00)
input bool              TradeSaturday      = false;           // Trade on Saturday

input group "=== Daily Loss Limit ==="
input bool              UseDailyLossLimit  = true;            // Use Daily Loss Limit
input double            MaxDailyLossPercent = 2.0;            // Max Daily Loss (% of Balance)

input group "=== Portfolio Manager Integration ==="
input bool              UsePortfolioManager = true;           // Use Portfolio Manager
input string            PortfolioSignalName = "PORTFOLIO_TRADING_BLOCKED"; // Signal Name

input group "=== Trade Settings ==="
input ulong             MagicNumber        = 300001;          // Magic Number
input string            TradeComment       = "TrendFollow";   // Trade Comment
input int               MaxOpenTrades      = 1;               // Max Open Trades (this EA)

input group "=== Dashboard ==="
input bool              ShowDashboard      = true;            // Show Dashboard
input int               DashboardX         = 10;              // Dashboard X Position
input int               DashboardY         = 30;              // Dashboard Y Position
input color             HeaderColor        = clrGold;         // Header Color
input color             TextColor          = clrWhite;        // Text Color
input color             BullColor          = clrLime;         // Bullish Color
input color             BearColor          = clrRed;          // Bearish Color
input color             NeutralColor       = clrGray;         // Neutral Color
input int               FontSize           = 9;               // Font Size

input group "=== Diagnostics ==="
input bool              LogDiagnostics     = false;           // Print Diagnostic Messages

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CAccountInfo   m_account;
CSymbolInfo    m_symbol;

// Indicator handles
int            g_handleFastMA;
int            g_handleSlowMA;
int            g_handleADX;
int            g_handleATR;
int            g_handleHTFFastMA;
int            g_handleHTFSlowMA;

// State tracking
int            g_barsSinceCrossover = -1;
int            g_lastCrossDirection = 0;  // 1 = bullish, -1 = bearish
datetime       g_lastBarTime = 0;
datetime       g_lastCrossoverBar = 0;
bool           g_tradeTakenThisCross = false;
double         g_dailyStartBalance = 0;
datetime       g_lastDayChecked = 0;

// Dashboard
string         g_dashPrefix = "TF_";

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize symbol info
   if(!m_symbol.Name(_Symbol))
   {
      Print("Failed to initialize symbol info");
      return INIT_FAILED;
   }

   // Setup trade object
   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(_Symbol);
   m_trade.SetDeviationInPoints(30);

   // Get MA method
   ENUM_MA_METHOD maMethod = GetMAMethod();

   // Create indicator handles
   g_handleFastMA = iMA(_Symbol, PERIOD_CURRENT, FastMAPeriod, 0, maMethod, PRICE_CLOSE);
   g_handleSlowMA = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, maMethod, PRICE_CLOSE);
   g_handleADX = iADX(_Symbol, PERIOD_CURRENT, ADXPeriod);
   g_handleATR = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(g_handleFastMA == INVALID_HANDLE || g_handleSlowMA == INVALID_HANDLE ||
      g_handleADX == INVALID_HANDLE || g_handleATR == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Create HTF indicator handles
   if(UseHTFFilter)
   {
      ENUM_TIMEFRAMES htfPeriod = GetHTFPeriod();
      g_handleHTFFastMA = iMA(_Symbol, htfPeriod, FastMAPeriod, 0, maMethod, PRICE_CLOSE);
      g_handleHTFSlowMA = iMA(_Symbol, htfPeriod, SlowMAPeriod, 0, maMethod, PRICE_CLOSE);

      if(g_handleHTFFastMA == INVALID_HANDLE || g_handleHTFSlowMA == INVALID_HANDLE)
      {
         Print("Failed to create HTF indicator handles");
         return INIT_FAILED;
      }
   }

   // Initialize daily balance
   g_dailyStartBalance = m_account.Balance();
   g_lastDayChecked = iTime(_Symbol, PERIOD_D1, 0);

   // Recover state on restart
   RecoverStateOnRestart();

   // Create dashboard
   if(ShowDashboard)
   {
      CreateDashboard();
   }

   // Set timer for dashboard updates
   EventSetTimer(1);

   Print("TrendFollowing EA V1.0 initialized on ", _Symbol);
   Print("Strategy: ", FastMAPeriod, "/", SlowMAPeriod, " ", GetMAMethodString(), " crossover");
   Print("Entry Mode: ", EntryMode == ENTRY_PULLBACK ? "Pullback" : "Crossover");
   Print("Filters: ADX=", UseADXFilter ? "ON" : "OFF", ", HTF=", UseHTFFilter ? "ON" : "OFF");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Release indicator handles
   if(g_handleFastMA != INVALID_HANDLE) IndicatorRelease(g_handleFastMA);
   if(g_handleSlowMA != INVALID_HANDLE) IndicatorRelease(g_handleSlowMA);
   if(g_handleADX != INVALID_HANDLE) IndicatorRelease(g_handleADX);
   if(g_handleATR != INVALID_HANDLE) IndicatorRelease(g_handleATR);
   if(g_handleHTFFastMA != INVALID_HANDLE) IndicatorRelease(g_handleHTFFastMA);
   if(g_handleHTFSlowMA != INVALID_HANDLE) IndicatorRelease(g_handleHTFSlowMA);

   // Clean up dashboard
   DeleteDashboard();

   Print("TrendFollowing EA V1.0 stopped");
}

//+------------------------------------------------------------------+
//| Timer function                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(ShowDashboard)
   {
      UpdateDashboard();
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update symbol info
   m_symbol.RefreshRates();

   // Check for new day - reset daily P/L tracking
   CheckNewDay();

   // Manage existing positions (trailing stop, opposite cross exit)
   ManagePositions();

   // Check if new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime)
      return;  // Same bar, no new signals
   g_lastBarTime = currentBarTime;

   // Update bars since crossover
   if(g_barsSinceCrossover >= 0)
   {
      g_barsSinceCrossover++;
   }

   // Check crossover on new bar
   CheckCrossover();

   // Trading logic
   if(!CanTrade())
      return;

   // Check for entry signal
   CheckEntrySignal();
}

//+------------------------------------------------------------------+
//| Get MA Method enum                                                |
//+------------------------------------------------------------------+
ENUM_MA_METHOD GetMAMethod()
{
   switch(MAMethod)
   {
      case MA_EMA:  return MODE_EMA;
      case MA_SMA:  return MODE_SMA;
      case MA_SMMA: return MODE_SMMA;
      case MA_LWMA: return MODE_LWMA;
      default:      return MODE_EMA;
   }
}

//+------------------------------------------------------------------+
//| Get MA Method string                                              |
//+------------------------------------------------------------------+
string GetMAMethodString()
{
   switch(MAMethod)
   {
      case MA_EMA:  return "EMA";
      case MA_SMA:  return "SMA";
      case MA_SMMA: return "SMMA";
      case MA_LWMA: return "LWMA";
      default:      return "EMA";
   }
}

//+------------------------------------------------------------------+
//| Get HTF Period                                                    |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetHTFPeriod()
{
   switch(HTFTimeframe)
   {
      case HTF_H4: return PERIOD_H4;
      case HTF_D1: return PERIOD_D1;
      case HTF_W1: return PERIOD_W1;
      default:     return PERIOD_H4;
   }
}

//+------------------------------------------------------------------+
//| Check if trading is allowed                                       |
//+------------------------------------------------------------------+
bool CanTrade()
{
   // Check Portfolio Manager block
   if(UsePortfolioManager && IsPortfolioBlocked())
   {
      if(LogDiagnostics)
         Print("Trading blocked by Portfolio Manager");
      return false;
   }

   // Check daily loss limit
   if(UseDailyLossLimit && IsDailyLossLimitHit())
   {
      if(LogDiagnostics)
         Print("Daily loss limit reached");
      return false;
   }

   // Check session filter
   if(UseSessionFilter && !IsWithinSession())
   {
      return false;
   }

   // Check day of week
   if(!IsTradingDay())
   {
      return false;
   }

   // Check spread
   if(MaxSpreadPoints > 0)
   {
      double spread = m_symbol.Spread();
      if(spread > MaxSpreadPoints)
      {
         if(LogDiagnostics)
            Print("Spread too high: ", spread);
         return false;
      }
   }

   // Check max open trades
   if(CountOpenPositions() >= MaxOpenTrades)
   {
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check if Portfolio Manager is blocking                            |
//+------------------------------------------------------------------+
bool IsPortfolioBlocked()
{
   if(!UsePortfolioManager)
      return false;

   if(GlobalVariableCheck(PortfolioSignalName))
   {
      double signal = GlobalVariableGet(PortfolioSignalName);
      return (signal == 1);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if within trading session                                   |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.hour >= SessionStartHour && dt.hour < SessionEndHour)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Check if today is a trading day                                   |
//+------------------------------------------------------------------+
bool IsTradingDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   switch(dt.day_of_week)
   {
      case 0: return TradeSunday;
      case 1: return TradeMonday;
      case 2: return TradeTuesday;
      case 3: return TradeWednesday;
      case 4: return TradeThursday;
      case 5: return TradeFriday;
      case 6: return TradeSaturday;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if daily loss limit hit                                     |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
{
   double currentBalance = m_account.Balance();
   double dailyPL = currentBalance - g_dailyStartBalance;
   double maxLoss = g_dailyStartBalance * (MaxDailyLossPercent / 100.0);

   return (dailyPL <= -maxLoss);
}

//+------------------------------------------------------------------+
//| Check for new day and reset                                       |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_lastDayChecked)
   {
      g_dailyStartBalance = m_account.Balance();
      g_lastDayChecked = today;
      if(LogDiagnostics)
         Print("New day - Reset daily balance to: ", g_dailyStartBalance);
   }
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                  |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get indicator values                                              |
//+------------------------------------------------------------------+
bool GetIndicatorValues(double &fastMA[], double &slowMA[], double &adx[], double &atr[])
{
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(g_handleFastMA, 0, 0, 3, fastMA) < 3) return false;
   if(CopyBuffer(g_handleSlowMA, 0, 0, 3, slowMA) < 3) return false;
   if(CopyBuffer(g_handleADX, 0, 0, 3, adx) < 3) return false;
   if(CopyBuffer(g_handleATR, 0, 0, 3, atr) < 3) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Get HTF trend direction                                           |
//+------------------------------------------------------------------+
int GetHTFTrendDirection()
{
   if(!UseHTFFilter)
      return 0;  // No filter

   double htfFastMA[], htfSlowMA[];
   ArraySetAsSeries(htfFastMA, true);
   ArraySetAsSeries(htfSlowMA, true);

   if(CopyBuffer(g_handleHTFFastMA, 0, 0, 2, htfFastMA) < 2) return 0;
   if(CopyBuffer(g_handleHTFSlowMA, 0, 0, 2, htfSlowMA) < 2) return 0;

   if(htfFastMA[0] > htfSlowMA[0])
      return 1;   // Bullish
   else if(htfFastMA[0] < htfSlowMA[0])
      return -1;  // Bearish

   return 0;
}

//+------------------------------------------------------------------+
//| Check for MA crossover                                            |
//+------------------------------------------------------------------+
void CheckCrossover()
{
   double fastMA[3], slowMA[3], adx[3], atr[3];

   if(!GetIndicatorValues(fastMA, slowMA, adx, atr))
      return;

   // Check for bullish crossover (fast crosses above slow)
   if(fastMA[1] > slowMA[1] && fastMA[2] <= slowMA[2])
   {
      if(g_lastCrossDirection != 1)  // New crossover
      {
         g_lastCrossDirection = 1;
         g_barsSinceCrossover = 0;
         g_lastCrossoverBar = iTime(_Symbol, PERIOD_CURRENT, 1);
         g_tradeTakenThisCross = false;

         if(LogDiagnostics)
            Print("Bullish crossover detected");
      }
   }
   // Check for bearish crossover (fast crosses below slow)
   else if(fastMA[1] < slowMA[1] && fastMA[2] >= slowMA[2])
   {
      if(g_lastCrossDirection != -1)  // New crossover
      {
         g_lastCrossDirection = -1;
         g_barsSinceCrossover = 0;
         g_lastCrossoverBar = iTime(_Symbol, PERIOD_CURRENT, 1);
         g_tradeTakenThisCross = false;

         if(LogDiagnostics)
            Print("Bearish crossover detected");
      }
   }
}

//+------------------------------------------------------------------+
//| Check for entry signal                                            |
//+------------------------------------------------------------------+
void CheckEntrySignal()
{
   // Already took trade for this crossover
   if(g_tradeTakenThisCross)
      return;

   // No recent crossover
   if(g_lastCrossDirection == 0 || g_barsSinceCrossover < 0)
      return;

   // Too many bars since crossover
   if(g_barsSinceCrossover > MaxBarsAfterCross)
   {
      if(LogDiagnostics)
         Print("Too many bars since crossover, resetting");
      g_lastCrossDirection = 0;
      g_barsSinceCrossover = -1;
      return;
   }

   double fastMA[3], slowMA[3], adx[3], atr[3];
   if(!GetIndicatorValues(fastMA, slowMA, adx, atr))
      return;

   // Check ADX filter
   if(UseADXFilter && adx[0] < ADXMinimum)
   {
      if(LogDiagnostics)
         Print("ADX too low: ", adx[0], " < ", ADXMinimum);
      return;
   }

   // Check HTF filter
   int htfTrend = GetHTFTrendDirection();

   // Bullish entry
   if(g_lastCrossDirection == 1)
   {
      // Check direction filter
      if(TradeDirection == TRADE_SHORT_ONLY)
         return;

      // Check HTF alignment
      if(UseHTFFilter && htfTrend == -1)
      {
         if(LogDiagnostics)
            Print("HTF trend is bearish, skipping long");
         return;
      }

      // Check entry condition
      if(CheckBullishEntry(fastMA, slowMA, atr))
      {
         ExecuteBuy(atr[0]);
      }
   }
   // Bearish entry
   else if(g_lastCrossDirection == -1)
   {
      // Check direction filter
      if(TradeDirection == TRADE_LONG_ONLY)
         return;

      // Check HTF alignment
      if(UseHTFFilter && htfTrend == 1)
      {
         if(LogDiagnostics)
            Print("HTF trend is bullish, skipping short");
         return;
      }

      // Check entry condition
      if(CheckBearishEntry(fastMA, slowMA, atr))
      {
         ExecuteSell(atr[0]);
      }
   }
}

//+------------------------------------------------------------------+
//| Check bullish entry conditions                                    |
//+------------------------------------------------------------------+
bool CheckBullishEntry(double &fastMA[], double &slowMA[], double &atr[])
{
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   double low = iLow(_Symbol, PERIOD_CURRENT, 1);

   // Crossover mode - enter immediately after crossover
   if(EntryMode == ENTRY_CROSSOVER)
   {
      if(g_barsSinceCrossover <= 1)
         return true;
   }
   // Pullback mode - wait for price to pull back to fast MA
   else if(EntryMode == ENTRY_PULLBACK)
   {
      double pullbackZone = fastMA[0] + (atr[0] * PullbackZoneATR);

      // Price should be near the fast MA
      if(close <= pullbackZone && close >= fastMA[0] - (atr[0] * 0.5))
      {
         // If requiring bounce, check that previous bar touched/crossed MA
         if(RequireBounce)
         {
            if(low <= fastMA[1] * 1.001)  // Allow small tolerance
            {
               if(LogDiagnostics)
                  Print("Bullish pullback entry: price bounced from fast MA");
               return true;
            }
         }
         else
         {
            if(LogDiagnostics)
               Print("Bullish pullback entry: price in zone");
            return true;
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check bearish entry conditions                                    |
//+------------------------------------------------------------------+
bool CheckBearishEntry(double &fastMA[], double &slowMA[], double &atr[])
{
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   double high = iHigh(_Symbol, PERIOD_CURRENT, 1);

   // Crossover mode - enter immediately after crossover
   if(EntryMode == ENTRY_CROSSOVER)
   {
      if(g_barsSinceCrossover <= 1)
         return true;
   }
   // Pullback mode - wait for price to pull back to fast MA
   else if(EntryMode == ENTRY_PULLBACK)
   {
      double pullbackZone = fastMA[0] - (atr[0] * PullbackZoneATR);

      // Price should be near the fast MA
      if(close >= pullbackZone && close <= fastMA[0] + (atr[0] * 0.5))
      {
         // If requiring bounce, check that previous bar touched/crossed MA
         if(RequireBounce)
         {
            if(high >= fastMA[1] * 0.999)  // Allow small tolerance
            {
               if(LogDiagnostics)
                  Print("Bearish pullback entry: price bounced from fast MA");
               return true;
            }
         }
         else
         {
            if(LogDiagnostics)
               Print("Bearish pullback entry: price in zone");
            return true;
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Execute buy order                                                 |
//+------------------------------------------------------------------+
void ExecuteBuy(double atr)
{
   double ask = m_symbol.Ask();
   double sl = ask - (atr * ATRMultiplierSL);
   double tp = 0;

   if(ATRMultiplierTP > 0)
   {
      tp = ask + (atr * ATRMultiplierTP);
   }

   // Normalize prices
   sl = NormalizeDouble(sl, m_symbol.Digits());
   if(tp > 0) tp = NormalizeDouble(tp, m_symbol.Digits());

   // Calculate position size
   double riskAmount = m_account.Balance() * (RiskPercent / 100.0);
   double slPoints = (ask - sl) / m_symbol.Point();
   double lotSize = CalculateLotSize(riskAmount, slPoints);

   if(lotSize <= 0)
   {
      Print("Invalid lot size calculated");
      return;
   }

   // Execute trade
   if(m_trade.Buy(lotSize, _Symbol, ask, sl, tp, TradeComment))
   {
      g_tradeTakenThisCross = true;
      Print("BUY executed: ", lotSize, " lots at ", ask, ", SL=", sl, ", TP=", tp);
   }
   else
   {
      Print("BUY failed: ", m_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute sell order                                                |
//+------------------------------------------------------------------+
void ExecuteSell(double atr)
{
   double bid = m_symbol.Bid();
   double sl = bid + (atr * ATRMultiplierSL);
   double tp = 0;

   if(ATRMultiplierTP > 0)
   {
      tp = bid - (atr * ATRMultiplierTP);
   }

   // Normalize prices
   sl = NormalizeDouble(sl, m_symbol.Digits());
   if(tp > 0) tp = NormalizeDouble(tp, m_symbol.Digits());

   // Calculate position size
   double riskAmount = m_account.Balance() * (RiskPercent / 100.0);
   double slPoints = (sl - bid) / m_symbol.Point();
   double lotSize = CalculateLotSize(riskAmount, slPoints);

   if(lotSize <= 0)
   {
      Print("Invalid lot size calculated");
      return;
   }

   // Execute trade
   if(m_trade.Sell(lotSize, _Symbol, bid, sl, tp, TradeComment))
   {
      g_tradeTakenThisCross = true;
      Print("SELL executed: ", lotSize, " lots at ", bid, ", SL=", sl, ", TP=", tp);
   }
   else
   {
      Print("SELL failed: ", m_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double riskAmount, double slPoints)
{
   double tickValue = m_symbol.TickValue();
   double tickSize = m_symbol.TickSize();
   double point = m_symbol.Point();

   if(tickValue == 0 || tickSize == 0 || point == 0)
      return 0;

   double pointValue = tickValue * (point / tickSize);
   double lotSize = riskAmount / (slPoints * pointValue);

   // Apply lot constraints
   double minLot = m_symbol.LotsMin();
   double maxLot = m_symbol.LotsMax();
   double lotStep = m_symbol.LotsStep();

   lotSize = MathMax(minLot, lotSize);
   lotSize = MathMin(maxLot, lotSize);
   lotSize = NormalizeDouble(MathFloor(lotSize / lotStep) * lotStep, 2);

   return lotSize;
}

//+------------------------------------------------------------------+
//| Manage existing positions                                         |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;

      if(m_position.Symbol() != _Symbol || m_position.Magic() != MagicNumber)
         continue;

      // Check for opposite crossover exit
      if(CloseOnOppositeCross)
      {
         if(ShouldCloseOnOppositeCross())
         {
            m_trade.PositionClose(m_position.Ticket());
            Print("Position closed on opposite MA crossover");
            continue;
         }
      }

      // Apply trailing stop
      if(UseTrailingStop)
      {
         ApplyTrailingStop();
      }
   }
}

//+------------------------------------------------------------------+
//| Check if should close on opposite crossover                       |
//+------------------------------------------------------------------+
bool ShouldCloseOnOppositeCross()
{
   double fastMA[3], slowMA[3], adx[3], atr[3];
   if(!GetIndicatorValues(fastMA, slowMA, adx, atr))
      return false;

   // Long position and bearish cross
   if(m_position.PositionType() == POSITION_TYPE_BUY)
   {
      if(fastMA[0] < slowMA[0] && fastMA[1] >= slowMA[1])
         return true;
   }
   // Short position and bullish cross
   else if(m_position.PositionType() == POSITION_TYPE_SELL)
   {
      if(fastMA[0] > slowMA[0] && fastMA[1] <= slowMA[1])
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Apply trailing stop                                               |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_handleATR, 0, 0, 3, atr) < 3)
      return;

   double entryPrice = m_position.PriceOpen();
   double currentPrice = m_position.PositionType() == POSITION_TYPE_BUY ? m_symbol.Bid() : m_symbol.Ask();
   double currentSL = m_position.StopLoss();
   double trailDistance = atr[0] * TrailingATRMult;
   double startDistance = atr[0] * TrailingStartATR;

   if(m_position.PositionType() == POSITION_TYPE_BUY)
   {
      double profit = currentPrice - entryPrice;

      // Only trail after minimum profit
      if(profit < startDistance)
         return;

      double newSL = currentPrice - trailDistance;
      newSL = NormalizeDouble(newSL, m_symbol.Digits());

      // Only move SL up, never down
      if(newSL > currentSL + m_symbol.Point())
      {
         m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
         if(LogDiagnostics)
            Print("Trailing stop updated: ", newSL);
      }
   }
   else if(m_position.PositionType() == POSITION_TYPE_SELL)
   {
      double profit = entryPrice - currentPrice;

      // Only trail after minimum profit
      if(profit < startDistance)
         return;

      double newSL = currentPrice + trailDistance;
      newSL = NormalizeDouble(newSL, m_symbol.Digits());

      // Only move SL down, never up
      if(newSL < currentSL - m_symbol.Point() || currentSL == 0)
      {
         m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
         if(LogDiagnostics)
            Print("Trailing stop updated: ", newSL);
      }
   }
}

//+------------------------------------------------------------------+
//| Recover state on EA restart                                       |
//+------------------------------------------------------------------+
void RecoverStateOnRestart()
{
   // Check if we have an open position
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
         {
            // We have an open position, mark trade taken
            g_tradeTakenThisCross = true;

            // Determine last cross direction from position type
            if(m_position.PositionType() == POSITION_TYPE_BUY)
               g_lastCrossDirection = 1;
            else
               g_lastCrossDirection = -1;

            Print("Recovered state: Found open ", (g_lastCrossDirection == 1 ? "BUY" : "SELL"), " position");
            break;
         }
      }
   }

   // Get current MA state
   double fastMA[3], slowMA[3], adx[3], atr[3];
   if(GetIndicatorValues(fastMA, slowMA, adx, atr))
   {
      if(fastMA[0] > slowMA[0])
         g_lastCrossDirection = 1;
      else
         g_lastCrossDirection = -1;
   }
}

//+------------------------------------------------------------------+
//| Create dashboard                                                  |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   DeleteDashboard();

   int y = DashboardY;
   int lineHeight = FontSize + 6;

   // Title
   CreateLabel(g_dashPrefix + "Title", DashboardX, y, "═══ TREND FOLLOWING EA ═══", HeaderColor, FontSize + 2);
   y += lineHeight + 4;

   // Strategy info
   string strategyStr = IntegerToString(FastMAPeriod) + "/" + IntegerToString(SlowMAPeriod) + " " + GetMAMethodString();
   CreateLabel(g_dashPrefix + "Strategy", DashboardX, y, "Strategy: " + strategyStr, TextColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "EntryMode", DashboardX, y, "Entry: " + (EntryMode == ENTRY_PULLBACK ? "Pullback" : "Crossover"), TextColor, FontSize);
   y += lineHeight + 4;

   // Current state
   CreateLabel(g_dashPrefix + "TrendLabel", DashboardX, y, "Trend:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "TrendValue", DashboardX + 80, y, "---", NeutralColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "HTFLabel", DashboardX, y, "HTF Trend:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "HTFValue", DashboardX + 80, y, "---", NeutralColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "ADXLabel", DashboardX, y, "ADX:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "ADXValue", DashboardX + 80, y, "---", NeutralColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "ATRLabel", DashboardX, y, "ATR:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "ATRValue", DashboardX + 80, y, "---", TextColor, FontSize);
   y += lineHeight + 4;

   // Signal state
   CreateLabel(g_dashPrefix + "CrossLabel", DashboardX, y, "Last Cross:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "CrossValue", DashboardX + 80, y, "None", NeutralColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "BarsLabel", DashboardX, y, "Bars Ago:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "BarsValue", DashboardX + 80, y, "---", TextColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "StatusLabel", DashboardX, y, "Status:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "StatusValue", DashboardX + 80, y, "Ready", NeutralColor, FontSize);
   y += lineHeight + 4;

   // Position info
   CreateLabel(g_dashPrefix + "PosLabel", DashboardX, y, "Position:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "PosValue", DashboardX + 80, y, "None", NeutralColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "PLLabel", DashboardX, y, "P/L:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "PLValue", DashboardX + 80, y, "$0.00", NeutralColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashPrefix + "DailyPLLabel", DashboardX, y, "Daily P/L:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "DailyPLValue", DashboardX + 80, y, "$0.00", NeutralColor, FontSize);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update dashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double fastMA[3], slowMA[3], adx[3], atr[3];
   if(!GetIndicatorValues(fastMA, slowMA, adx, atr))
      return;

   // Current trend
   string trendStr;
   color trendColor;
   if(fastMA[0] > slowMA[0])
   {
      trendStr = "BULLISH";
      trendColor = BullColor;
   }
   else
   {
      trendStr = "BEARISH";
      trendColor = BearColor;
   }
   UpdateLabel(g_dashPrefix + "TrendValue", trendStr, trendColor);

   // HTF trend
   if(UseHTFFilter)
   {
      int htfTrend = GetHTFTrendDirection();
      string htfStr = htfTrend == 1 ? "BULLISH" : (htfTrend == -1 ? "BEARISH" : "NEUTRAL");
      color htfColor = htfTrend == 1 ? BullColor : (htfTrend == -1 ? BearColor : NeutralColor);
      UpdateLabel(g_dashPrefix + "HTFValue", htfStr, htfColor);
   }
   else
   {
      UpdateLabel(g_dashPrefix + "HTFValue", "OFF", NeutralColor);
   }

   // ADX
   color adxColor = adx[0] >= ADXMinimum ? BullColor : BearColor;
   UpdateLabel(g_dashPrefix + "ADXValue", DoubleToString(adx[0], 1), adxColor);

   // ATR
   UpdateLabel(g_dashPrefix + "ATRValue", DoubleToString(atr[0], m_symbol.Digits()));

   // Last cross
   string crossStr = g_lastCrossDirection == 1 ? "BULLISH" : (g_lastCrossDirection == -1 ? "BEARISH" : "None");
   color crossColor = g_lastCrossDirection == 1 ? BullColor : (g_lastCrossDirection == -1 ? BearColor : NeutralColor);
   UpdateLabel(g_dashPrefix + "CrossValue", crossStr, crossColor);

   // Bars since cross
   string barsStr = g_barsSinceCrossover >= 0 ? IntegerToString(g_barsSinceCrossover) : "---";
   UpdateLabel(g_dashPrefix + "BarsValue", barsStr);

   // Status
   string statusStr;
   color statusColor;
   if(!CanTrade())
   {
      if(UsePortfolioManager && IsPortfolioBlocked())
         statusStr = "BLOCKED";
      else if(UseDailyLossLimit && IsDailyLossLimitHit())
         statusStr = "DAILY LIMIT";
      else if(!IsWithinSession())
         statusStr = "OUT OF SESSION";
      else
         statusStr = "MAX TRADES";
      statusColor = BearColor;
   }
   else if(g_tradeTakenThisCross)
   {
      statusStr = "Trade Taken";
      statusColor = NeutralColor;
   }
   else if(g_barsSinceCrossover >= 0 && g_barsSinceCrossover <= MaxBarsAfterCross)
   {
      statusStr = "Watching...";
      statusColor = HeaderColor;
   }
   else
   {
      statusStr = "Ready";
      statusColor = BullColor;
   }
   UpdateLabel(g_dashPrefix + "StatusValue", statusStr, statusColor);

   // Position info
   bool hasPosition = false;
   double positionPL = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
         {
            hasPosition = true;
            string posStr = (m_position.PositionType() == POSITION_TYPE_BUY ? "BUY " : "SELL ") +
                           DoubleToString(m_position.Volume(), 2) + " lots";
            UpdateLabel(g_dashPrefix + "PosValue", posStr, m_position.PositionType() == POSITION_TYPE_BUY ? BullColor : BearColor);

            positionPL = m_position.Profit() + m_position.Swap() + m_position.Commission();
            color plColor = positionPL >= 0 ? BullColor : BearColor;
            string plStr = (positionPL >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(positionPL), 2);
            UpdateLabel(g_dashPrefix + "PLValue", plStr, plColor);
            break;
         }
      }
   }

   if(!hasPosition)
   {
      UpdateLabel(g_dashPrefix + "PosValue", "None", NeutralColor);
      UpdateLabel(g_dashPrefix + "PLValue", "$0.00", NeutralColor);
   }

   // Daily P/L
   double dailyPL = m_account.Balance() - g_dailyStartBalance + positionPL;
   color dailyColor = dailyPL >= 0 ? BullColor : BearColor;
   string dailyStr = (dailyPL >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(dailyPL), 2);
   UpdateLabel(g_dashPrefix + "DailyPLValue", dailyStr, dailyColor);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete dashboard                                                  |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, g_dashPrefix) == 0)
      {
         ObjectDelete(0, name);
      }
   }
}

//+------------------------------------------------------------------+
//| Create label helper                                               |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
}

//+------------------------------------------------------------------+
//| Update label helper                                               |
//+------------------------------------------------------------------+
void UpdateLabel(string name, string text, color clr = clrNONE)
{
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   if(clr != clrNONE)
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }
}
//+------------------------------------------------------------------+
