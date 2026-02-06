//+------------------------------------------------------------------+
//|                                       TrendFollowing EA V1.0.mq5 |
//|                                   Portfolio Management Suite     |
//|         Professional Trend Following with Pullback Entry         |
//|                          OPTIMIZED VERSION                       |
//+------------------------------------------------------------------+
#property copyright "Portfolio Management Suite"
#property link      ""
#property version   "1.01"
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
input bool              TradeFriday        = true;            // Trade on Friday
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

// Cached indicator values (updated once per bar)
double         g_fastMA[], g_slowMA[], g_adx[], g_atr[];
int            g_htfTrend = 0;
bool           g_indicatorsValid = false;

// State tracking
int            g_barsSinceCrossover = -1;
int            g_lastCrossDirection = 0;
datetime       g_lastBarTime = 0;
datetime       g_lastHTFBarTime = 0;
bool           g_tradeTakenThisCross = false;
double         g_dailyStartBalance = 0;
datetime       g_lastDayChecked = 0;

// Cached position info
int            g_openPositionCount = 0;
ulong          g_openPositionTicket = 0;
ENUM_POSITION_TYPE g_openPositionType;
double         g_openPositionProfit = 0;
double         g_openPositionVolume = 0;
double         g_openPositionEntry = 0;
double         g_openPositionSL = 0;
double         g_openPositionTP = 0;

// Cached time info
bool           g_tradingAllowed = true;
int            g_currentHour = -1;
int            g_currentDayOfWeek = -1;

// Dashboard
string         g_dashPrefix = "TF_";
datetime       g_lastDashboardUpdate = 0;

// Pre-calculated values
double         g_point;
double         g_tickValue;
double         g_tickSize;
double         g_minLot;
double         g_maxLot;
double         g_lotStep;
int            g_digits;
bool           g_tradingDays[7];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!m_symbol.Name(_Symbol))
   {
      Print("Failed to initialize symbol info");
      return INIT_FAILED;
   }

   // Cache symbol properties
   g_point = m_symbol.Point();
   g_tickValue = m_symbol.TickValue();
   g_tickSize = m_symbol.TickSize();
   g_minLot = m_symbol.LotsMin();
   g_maxLot = m_symbol.LotsMax();
   g_lotStep = m_symbol.LotsStep();
   g_digits = m_symbol.Digits();

   // Pre-build trading days array
   g_tradingDays[0] = TradeSunday;
   g_tradingDays[1] = TradeMonday;
   g_tradingDays[2] = TradeTuesday;
   g_tradingDays[3] = TradeWednesday;
   g_tradingDays[4] = TradeThursday;
   g_tradingDays[5] = TradeFriday;
   g_tradingDays[6] = TradeSaturday;

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

   // Create HTF indicator handles only if needed
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

   // Initialize
   g_dailyStartBalance = m_account.Balance();
   g_lastDayChecked = iTime(_Symbol, PERIOD_D1, 0);

   // Set arrays as series once
   ArraySetAsSeries(g_fastMA, true);
   ArraySetAsSeries(g_slowMA, true);
   ArraySetAsSeries(g_adx, true);
   ArraySetAsSeries(g_atr, true);

   RecoverStateOnRestart();

   if(ShowDashboard)
      CreateDashboard();

   EventSetTimer(3);  // Dashboard update every 3 seconds

   Print("TrendFollowing EA V1.0 (Optimized) initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_handleFastMA != INVALID_HANDLE) IndicatorRelease(g_handleFastMA);
   if(g_handleSlowMA != INVALID_HANDLE) IndicatorRelease(g_handleSlowMA);
   if(g_handleADX != INVALID_HANDLE) IndicatorRelease(g_handleADX);
   if(g_handleATR != INVALID_HANDLE) IndicatorRelease(g_handleATR);
   if(UseHTFFilter)
   {
      if(g_handleHTFFastMA != INVALID_HANDLE) IndicatorRelease(g_handleHTFFastMA);
      if(g_handleHTFSlowMA != INVALID_HANDLE) IndicatorRelease(g_handleHTFSlowMA);
   }
   DeleteDashboard();
}

//+------------------------------------------------------------------+
//| Timer function                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(ShowDashboard)
      UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update position cache on every tick (for trailing)
   UpdatePositionCache();

   // Manage existing positions
   if(g_openPositionCount > 0)
      ManagePositions();

   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime)
      return;
   g_lastBarTime = currentBarTime;

   // New bar processing
   OnNewBar();
}

//+------------------------------------------------------------------+
//| New bar processing                                                |
//+------------------------------------------------------------------+
void OnNewBar()
{
   // Update indicators once per bar
   if(!UpdateIndicators())
      return;

   // Update time-based checks once per bar
   UpdateTimeChecks();

   // Update bars since crossover
   if(g_barsSinceCrossover >= 0)
      g_barsSinceCrossover++;

   // Check for crossover
   CheckCrossover();

   // Check for entry
   if(g_tradingAllowed && g_openPositionCount < MaxOpenTrades && !g_tradeTakenThisCross)
      CheckEntrySignal();
}

//+------------------------------------------------------------------+
//| Update cached indicator values                                    |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   if(CopyBuffer(g_handleFastMA, 0, 0, 3, g_fastMA) < 3) return false;
   if(CopyBuffer(g_handleSlowMA, 0, 0, 3, g_slowMA) < 3) return false;
   if(CopyBuffer(g_handleADX, 0, 0, 3, g_adx) < 3) return false;
   if(CopyBuffer(g_handleATR, 0, 0, 3, g_atr) < 3) return false;

   // Update HTF trend only when HTF bar changes
   if(UseHTFFilter)
   {
      ENUM_TIMEFRAMES htfPeriod = GetHTFPeriod();
      datetime htfBarTime = iTime(_Symbol, htfPeriod, 0);
      if(htfBarTime != g_lastHTFBarTime)
      {
         g_lastHTFBarTime = htfBarTime;
         UpdateHTFTrend();
      }
   }

   g_indicatorsValid = true;
   return true;
}

//+------------------------------------------------------------------+
//| Update HTF trend direction                                        |
//+------------------------------------------------------------------+
void UpdateHTFTrend()
{
   double htfFastMA[], htfSlowMA[];
   ArraySetAsSeries(htfFastMA, true);
   ArraySetAsSeries(htfSlowMA, true);

   if(CopyBuffer(g_handleHTFFastMA, 0, 0, 2, htfFastMA) < 2 ||
      CopyBuffer(g_handleHTFSlowMA, 0, 0, 2, htfSlowMA) < 2)
   {
      g_htfTrend = 0;
      return;
   }

   g_htfTrend = (htfFastMA[0] > htfSlowMA[0]) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Update time-based checks                                          |
//+------------------------------------------------------------------+
void UpdateTimeChecks()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   // Check new day
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_lastDayChecked)
   {
      g_dailyStartBalance = m_account.Balance();
      g_lastDayChecked = today;
   }

   // Cache current time info
   g_currentHour = dt.hour;
   g_currentDayOfWeek = dt.day_of_week;

   // Calculate if trading is allowed
   g_tradingAllowed = CanTradeNow();
}

//+------------------------------------------------------------------+
//| Check if trading allowed now                                      |
//+------------------------------------------------------------------+
bool CanTradeNow()
{
   // Portfolio Manager check
   if(UsePortfolioManager)
   {
      if(GlobalVariableCheck(PortfolioSignalName) && GlobalVariableGet(PortfolioSignalName) == 1)
         return false;
   }

   // Daily loss check
   if(UseDailyLossLimit)
   {
      double maxLoss = g_dailyStartBalance * MaxDailyLossPercent / 100.0;
      if(m_account.Balance() - g_dailyStartBalance <= -maxLoss)
         return false;
   }

   // Session check
   if(UseSessionFilter)
   {
      if(g_currentHour < SessionStartHour || g_currentHour >= SessionEndHour)
         return false;
   }

   // Day of week check
   if(!g_tradingDays[g_currentDayOfWeek])
      return false;

   // Spread check
   if(MaxSpreadPoints > 0 && m_symbol.Spread() > MaxSpreadPoints)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Update position cache                                             |
//+------------------------------------------------------------------+
void UpdatePositionCache()
{
   g_openPositionCount = 0;
   g_openPositionTicket = 0;
   g_openPositionProfit = 0;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
         {
            g_openPositionCount++;
            g_openPositionTicket = m_position.Ticket();
            g_openPositionType = m_position.PositionType();
            g_openPositionProfit = m_position.Profit() + m_position.Swap() + m_position.Commission();
            g_openPositionVolume = m_position.Volume();
            g_openPositionEntry = m_position.PriceOpen();
            g_openPositionSL = m_position.StopLoss();
            g_openPositionTP = m_position.TakeProfit();
            break;  // Only tracking first position for this EA
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get MA Method enum                                                |
//+------------------------------------------------------------------+
ENUM_MA_METHOD GetMAMethod()
{
   switch(MAMethod)
   {
      case MA_SMA:  return MODE_SMA;
      case MA_SMMA: return MODE_SMMA;
      case MA_LWMA: return MODE_LWMA;
      default:      return MODE_EMA;
   }
}

//+------------------------------------------------------------------+
//| Get HTF Period                                                    |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetHTFPeriod()
{
   switch(HTFTimeframe)
   {
      case HTF_D1: return PERIOD_D1;
      case HTF_W1: return PERIOD_W1;
      default:     return PERIOD_H4;
   }
}

//+------------------------------------------------------------------+
//| Check for MA crossover                                            |
//+------------------------------------------------------------------+
void CheckCrossover()
{
   // Bullish crossover
   if(g_fastMA[1] > g_slowMA[1] && g_fastMA[2] <= g_slowMA[2])
   {
      if(g_lastCrossDirection != 1)
      {
         g_lastCrossDirection = 1;
         g_barsSinceCrossover = 0;
         g_tradeTakenThisCross = false;
         if(LogDiagnostics) Print("Bullish crossover detected");
      }
   }
   // Bearish crossover
   else if(g_fastMA[1] < g_slowMA[1] && g_fastMA[2] >= g_slowMA[2])
   {
      if(g_lastCrossDirection != -1)
      {
         g_lastCrossDirection = -1;
         g_barsSinceCrossover = 0;
         g_tradeTakenThisCross = false;
         if(LogDiagnostics) Print("Bearish crossover detected");
      }
   }
}

//+------------------------------------------------------------------+
//| Check for entry signal                                            |
//+------------------------------------------------------------------+
void CheckEntrySignal()
{
   // Early exits
   if(g_lastCrossDirection == 0 || g_barsSinceCrossover < 0)
      return;

   if(g_barsSinceCrossover > MaxBarsAfterCross)
   {
      g_lastCrossDirection = 0;
      g_barsSinceCrossover = -1;
      return;
   }

   // ADX filter
   if(UseADXFilter && g_adx[0] < ADXMinimum)
      return;

   // Direction and HTF checks
   if(g_lastCrossDirection == 1)
   {
      if(TradeDirection == TRADE_SHORT_ONLY) return;
      if(UseHTFFilter && g_htfTrend == -1) return;
      if(CheckBullishEntry())
         ExecuteBuy();
   }
   else if(g_lastCrossDirection == -1)
   {
      if(TradeDirection == TRADE_LONG_ONLY) return;
      if(UseHTFFilter && g_htfTrend == 1) return;
      if(CheckBearishEntry())
         ExecuteSell();
   }
}

//+------------------------------------------------------------------+
//| Check bullish entry                                               |
//+------------------------------------------------------------------+
bool CheckBullishEntry()
{
   if(EntryMode == ENTRY_CROSSOVER)
      return (g_barsSinceCrossover <= 1);

   // Pullback mode
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   double pullbackZone = g_fastMA[0] + (g_atr[0] * PullbackZoneATR);
   double lowerBound = g_fastMA[0] - (g_atr[0] * 0.5);

   if(close <= pullbackZone && close >= lowerBound)
   {
      if(!RequireBounce)
         return true;

      double low = iLow(_Symbol, PERIOD_CURRENT, 1);
      return (low <= g_fastMA[1] * 1.001);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check bearish entry                                               |
//+------------------------------------------------------------------+
bool CheckBearishEntry()
{
   if(EntryMode == ENTRY_CROSSOVER)
      return (g_barsSinceCrossover <= 1);

   // Pullback mode
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   double pullbackZone = g_fastMA[0] - (g_atr[0] * PullbackZoneATR);
   double upperBound = g_fastMA[0] + (g_atr[0] * 0.5);

   if(close >= pullbackZone && close <= upperBound)
   {
      if(!RequireBounce)
         return true;

      double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
      return (high >= g_fastMA[1] * 0.999);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Execute buy order                                                 |
//+------------------------------------------------------------------+
void ExecuteBuy()
{
   m_symbol.RefreshRates();
   double ask = m_symbol.Ask();
   double sl = NormalizeDouble(ask - (g_atr[0] * ATRMultiplierSL), g_digits);
   double tp = ATRMultiplierTP > 0 ? NormalizeDouble(ask + (g_atr[0] * ATRMultiplierTP), g_digits) : 0;

   double lotSize = CalculateLotSize(ask - sl);
   if(lotSize <= 0) return;

   if(m_trade.Buy(lotSize, _Symbol, ask, sl, tp, TradeComment))
   {
      g_tradeTakenThisCross = true;
      Print("BUY: ", lotSize, " lots @ ", ask, " SL=", sl, " TP=", tp);
   }
}

//+------------------------------------------------------------------+
//| Execute sell order                                                |
//+------------------------------------------------------------------+
void ExecuteSell()
{
   m_symbol.RefreshRates();
   double bid = m_symbol.Bid();
   double sl = NormalizeDouble(bid + (g_atr[0] * ATRMultiplierSL), g_digits);
   double tp = ATRMultiplierTP > 0 ? NormalizeDouble(bid - (g_atr[0] * ATRMultiplierTP), g_digits) : 0;

   double lotSize = CalculateLotSize(sl - bid);
   if(lotSize <= 0) return;

   if(m_trade.Sell(lotSize, _Symbol, bid, sl, tp, TradeComment))
   {
      g_tradeTakenThisCross = true;
      Print("SELL: ", lotSize, " lots @ ", bid, " SL=", sl, " TP=", tp);
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size (optimized)                                    |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(g_tickValue == 0 || g_tickSize == 0 || g_point == 0 || slDistance <= 0)
      return 0;

   double riskAmount = m_account.Balance() * RiskPercent / 100.0;
   double slPoints = slDistance / g_point;
   double pointValue = g_tickValue * (g_point / g_tickSize);
   double lotSize = riskAmount / (slPoints * pointValue);

   lotSize = MathMax(g_minLot, MathMin(g_maxLot, lotSize));
   return NormalizeDouble(MathFloor(lotSize / g_lotStep) * g_lotStep, 2);
}

//+------------------------------------------------------------------+
//| Manage existing positions                                         |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(g_openPositionTicket == 0) return;

   m_symbol.RefreshRates();

   // Check opposite cross exit
   if(CloseOnOppositeCross)
   {
      bool shouldClose = false;
      if(g_openPositionType == POSITION_TYPE_BUY && g_fastMA[0] < g_slowMA[0] && g_fastMA[1] >= g_slowMA[1])
         shouldClose = true;
      else if(g_openPositionType == POSITION_TYPE_SELL && g_fastMA[0] > g_slowMA[0] && g_fastMA[1] <= g_slowMA[1])
         shouldClose = true;

      if(shouldClose)
      {
         m_trade.PositionClose(g_openPositionTicket);
         Print("Closed on opposite crossover");
         return;
      }
   }

   // Trailing stop
   if(UseTrailingStop)
      ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Apply trailing stop (optimized)                                   |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double trailDist = g_atr[0] * TrailingATRMult;
   double startDist = g_atr[0] * TrailingStartATR;

   if(g_openPositionType == POSITION_TYPE_BUY)
   {
      double currentPrice = m_symbol.Bid();
      double profit = currentPrice - g_openPositionEntry;
      if(profit < startDist) return;

      double newSL = NormalizeDouble(currentPrice - trailDist, g_digits);
      if(newSL > g_openPositionSL + g_point)
         m_trade.PositionModify(g_openPositionTicket, newSL, g_openPositionTP);
   }
   else
   {
      double currentPrice = m_symbol.Ask();
      double profit = g_openPositionEntry - currentPrice;
      if(profit < startDist) return;

      double newSL = NormalizeDouble(currentPrice + trailDist, g_digits);
      if(newSL < g_openPositionSL - g_point || g_openPositionSL == 0)
         m_trade.PositionModify(g_openPositionTicket, newSL, g_openPositionTP);
   }
}

//+------------------------------------------------------------------+
//| Recover state on restart                                          |
//+------------------------------------------------------------------+
void RecoverStateOnRestart()
{
   UpdatePositionCache();
   if(g_openPositionCount > 0)
   {
      g_tradeTakenThisCross = true;
      g_lastCrossDirection = (g_openPositionType == POSITION_TYPE_BUY) ? 1 : -1;
      Print("Recovered: Found open ", (g_lastCrossDirection == 1 ? "BUY" : "SELL"));
   }
}

//+------------------------------------------------------------------+
//| Create dashboard                                                  |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   DeleteDashboard();
   int y = DashboardY;
   int lh = FontSize + 6;

   CreateLabel(g_dashPrefix + "Title", DashboardX, y, "═══ TREND FOLLOWING ═══", HeaderColor, FontSize + 2);
   y += lh + 4;

   CreateLabel(g_dashPrefix + "TrendL", DashboardX, y, "Trend:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "TrendV", DashboardX + 70, y, "---", NeutralColor, FontSize);
   y += lh;

   if(UseHTFFilter)
   {
      CreateLabel(g_dashPrefix + "HTFL", DashboardX, y, "HTF:", TextColor, FontSize);
      CreateLabel(g_dashPrefix + "HTFV", DashboardX + 70, y, "---", NeutralColor, FontSize);
      y += lh;
   }

   CreateLabel(g_dashPrefix + "ADXL", DashboardX, y, "ADX:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "ADXV", DashboardX + 70, y, "---", NeutralColor, FontSize);
   y += lh;

   CreateLabel(g_dashPrefix + "StatusL", DashboardX, y, "Status:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "StatusV", DashboardX + 70, y, "Ready", NeutralColor, FontSize);
   y += lh;

   CreateLabel(g_dashPrefix + "PosL", DashboardX, y, "Pos:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "PosV", DashboardX + 70, y, "None", NeutralColor, FontSize);
   y += lh;

   CreateLabel(g_dashPrefix + "PLL", DashboardX, y, "P/L:", TextColor, FontSize);
   CreateLabel(g_dashPrefix + "PLV", DashboardX + 70, y, "$0.00", NeutralColor, FontSize);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update dashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!g_indicatorsValid) return;

   // Trend
   bool bullish = g_fastMA[0] > g_slowMA[0];
   UpdateLabel(g_dashPrefix + "TrendV", bullish ? "BULL" : "BEAR", bullish ? BullColor : BearColor);

   // HTF
   if(UseHTFFilter)
   {
      string htfStr = g_htfTrend == 1 ? "BULL" : (g_htfTrend == -1 ? "BEAR" : "---");
      color htfClr = g_htfTrend == 1 ? BullColor : (g_htfTrend == -1 ? BearColor : NeutralColor);
      UpdateLabel(g_dashPrefix + "HTFV", htfStr, htfClr);
   }

   // ADX
   UpdateLabel(g_dashPrefix + "ADXV", DoubleToString(g_adx[0], 1), g_adx[0] >= ADXMinimum ? BullColor : BearColor);

   // Status
   string status = g_tradingAllowed ? (g_tradeTakenThisCross ? "Taken" : "Ready") : "Blocked";
   color statusClr = g_tradingAllowed ? (g_tradeTakenThisCross ? NeutralColor : BullColor) : BearColor;
   UpdateLabel(g_dashPrefix + "StatusV", status, statusClr);

   // Position
   if(g_openPositionCount > 0)
   {
      string posStr = (g_openPositionType == POSITION_TYPE_BUY ? "BUY " : "SELL ") + DoubleToString(g_openPositionVolume, 2);
      UpdateLabel(g_dashPrefix + "PosV", posStr, g_openPositionType == POSITION_TYPE_BUY ? BullColor : BearColor);
      string plStr = (g_openPositionProfit >= 0 ? "+" : "") + DoubleToString(g_openPositionProfit, 2);
      UpdateLabel(g_dashPrefix + "PLV", plStr, g_openPositionProfit >= 0 ? BullColor : BearColor);
   }
   else
   {
      UpdateLabel(g_dashPrefix + "PosV", "None", NeutralColor);
      UpdateLabel(g_dashPrefix + "PLV", "$0.00", NeutralColor);
   }

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
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| Create label                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int size)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
}

//+------------------------------------------------------------------+
//| Update label                                                      |
//+------------------------------------------------------------------+
void UpdateLabel(string name, string text, color clr = clrNONE)
{
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   if(clr != clrNONE)
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}
//+------------------------------------------------------------------+
