//+------------------------------------------------------------------+
//|                                            RangeBreakout_EA.mq5  |
//|                                                            Manuel |
//|                                      Simple Range Breakout System |
//+------------------------------------------------------------------+
#property copyright "Manuel"
#property version   "1.60"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Range Settings ==="
input int      RangeStartHour   = 2;       // Range Start Hour
input int      RangeStartMinute = 0;       // Range Start Minute
input int      RangeEndHour     = 6;       // Range End Hour
input int      RangeEndMinute   = 0;       // Range End Minute

input group "=== Range Filters ==="
input double   MinRangePercent  = 0.1;     // Minimum Range Size (% of price)
input double   MaxRangePercent  = 2.0;     // Maximum Range Size (% of price)

input group "=== Trading Settings ==="
input int      TradingEndHour   = 20;      // Trading End Hour (close all positions)
input int      TradingEndMinute = 0;       // Trading End Minute
input double   RiskAmount       = 50.0;    // Risk Amount (Account Currency)
input double   TPMultiple       = 2.0;     // Take Profit (Range Multiple)
input int      SLBuffer         = 50;      // SL Buffer (Points)
input int      Slippage         = 30;      // Slippage (Points)

input group "=== Break-Even Settings ==="
input bool     UseBreakEven           = true;   // Enable Break-Even
input double   BETriggerPercent       = 50.0;   // BE Trigger (% of Entry-to-TP distance)
input double   BEBufferPercent        = 5.0;    // BE Buffer (% of Entry-to-TP to lock in)

input group "=== Trailing Stop Settings ==="
input bool     UseTrailingStop        = true;   // Enable Trailing Stop
input double   TrailingActivationPercent = 75.0;   // Trailing Activation (% of Entry-to-TP)
input double   TrailingDistancePercent   = 25.0;   // Trailing Distance (% of Entry-to-TP)

input group "=== Weekly Cleanup Settings ==="
input int      WeeklyCleanupDay    = 5;    // Cleanup Day (5 = Friday)
input int      WeeklyCleanupHour   = 22;   // Cleanup Hour
input int      WeeklyCleanupMinute = 0;    // Cleanup Minute

input group "=== Visual Settings ==="
input color    RangeColor       = clrDodgerBlue;  // Range Rectangle Color
input int      RangeOpacity     = 20;             // Range Opacity (0-100)

input group "=== Dashboard Settings ==="
input bool     ShowDashboard       = true;       // Show Performance Dashboard
input int      DashboardX          = 10;         // Dashboard X Position
input int      DashboardY          = 20;         // Dashboard Y Position
input int      DashboardWidth      = 340;        // Dashboard Width
input int      DashboardHeight     = 95;         // Dashboard Height
input color    DashColorBG         = C'25,25,25';    // Background Color
input color    DashColorBorder     = C'60,60,60';    // Border Color
input color    DashColorText       = clrWhite;       // Text Color
input color    DashColorLabel      = clrGray;        // Label Color
input color    DashColorProfit     = clrLime;        // Profit Color
input color    DashColorLoss       = clrRed;         // Loss Color

input group "=== General ==="
input int      MagicNumber      = 123456;  // Magic Number
input bool     LogDiagnostics   = true;    // Extended Diagnostics Logging

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
double   g_rangeHigh;
double   g_rangeLow;
datetime g_rangeStartTime;
datetime g_rangeEndTime;
bool     g_rangeBuilding;
bool     g_rangeComplete;
bool     g_longTaken;
bool     g_shortTaken;
bool     g_rangeInvalid;
string   g_rectName;
datetime g_currentDay;
datetime g_lastFridayCleanup;

// Break-even tracking
ulong    g_beAppliedTickets[];

// Dashboard prefix
string   g_prefix = "RangeEA_";

// Performance tracking
struct PerformanceStats
{
   int      totalTrades;
   int      wins;
   int      losses;
   double   totalProfit;
   double   totalLoss;
   double   todayPL;
   double   bestTrade;
   double   worstTrade;
   datetime lastUpdate;
};

PerformanceStats g_stats;

CTrade m_trade;
CSymbolInfo m_symbol;
CPositionInfo m_position;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize symbol
   if(!m_symbol.Name(_Symbol))
   {
      Print("Failed to initialize symbol");
      return INIT_FAILED;
   }
   
   // Setup trade object
   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetDeviationInPoints(Slippage);
   
   // Auto-detect filling mode
   ENUM_ORDER_TYPE_FILLING fillingMode = GetFillingMode();
   m_trade.SetTypeFilling(fillingMode);
   
   // Validate inputs
   if(RiskAmount <= 0)
   {
      Print("Risk Amount must be greater than 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(TPMultiple <= 0)
   {
      Print("TP Multiple must be greater than 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(MinRangePercent < 0 || MaxRangePercent <= 0)
   {
      Print("Range percent filters must be positive");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(MinRangePercent >= MaxRangePercent)
   {
      Print("Min Range must be less than Max Range");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   // Validate break-even settings
   if(UseBreakEven)
   {
      if(BETriggerPercent <= 0 || BETriggerPercent > 100)
      {
         Print("BE Trigger must be between 0 and 100%");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(BEBufferPercent < 0 || BEBufferPercent >= BETriggerPercent)
      {
         Print("BE Buffer must be >= 0 and less than BE Trigger");
         return INIT_PARAMETERS_INCORRECT;
      }
   }
   
   // Validate trailing stop settings
   if(UseTrailingStop)
   {
      if(TrailingActivationPercent <= 0 || TrailingActivationPercent > 100)
      {
         Print("Trailing Activation must be between 0 and 100%");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(TrailingDistancePercent <= 0 || TrailingDistancePercent >= 100)
      {
         Print("Trailing Distance must be between 0 and 100%");
         return INIT_PARAMETERS_INCORRECT;
      }
   }
   
   // Initialize variables
   ResetDailyVariables();
   g_currentDay = iTime(_Symbol, PERIOD_D1, 0);
   g_rectName = GetRectangleName(g_currentDay);
   g_lastFridayCleanup = 0;
   ArrayResize(g_beAppliedTickets, 0);
   
   // Initialize performance stats
   ZeroMemory(g_stats);
   CalculateHistoricalStats();
   
   // Create dashboard
   if(ShowDashboard)
      CreateDashboard();
   
   // Reconstruct range if we're past the range period but same day
   RebuildRangeIfNeeded();
   
   Print("===== RangeBreakout EA Initialized =====");
   Print("Symbol: ", _Symbol);
   Print("Range: ", StringFormat("%02d:%02d - %02d:%02d", RangeStartHour, RangeStartMinute, RangeEndHour, RangeEndMinute));
   Print("Trading End: ", StringFormat("%02d:%02d", TradingEndHour, TradingEndMinute));
   Print("Risk Amount: ", RiskAmount);
   Print("TP Multiple: ", TPMultiple, "x range");
   Print("Range Size Filter: ", MinRangePercent, "% - ", MaxRangePercent, "%");
   Print("Break-Even: ", UseBreakEven ? StringFormat("ON (Trigger: %.1f%%, Buffer: %.1f%% of Entry-to-TP)", 
         BETriggerPercent, BEBufferPercent) : "OFF");
   Print("Trailing Stop: ", UseTrailingStop ? StringFormat("ON (Activation: %.1f%%, Distance: %.1f%% of Entry-to-TP)", 
         TrailingActivationPercent, TrailingDistancePercent) : "OFF");
   Print("Filling Mode: ", EnumToString(fillingMode));
   Print("=========================================");
   
   // Set timer for dashboard updates
   EventSetTimer(1);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ArrayFree(g_beAppliedTickets);
   DeleteDashboard();
   Print("RangeBreakout EA removed. Rectangles preserved on chart.");
}

//+------------------------------------------------------------------+
//| Timer function for dashboard updates                              |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(ShowDashboard)
   {
      CalculateHistoricalStats();
      UpdateDashboard();
   }
}

//+------------------------------------------------------------------+
//| Get the correct filling mode for the symbol                      |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   uint fillingModes = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   if((fillingModes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
   {
      if(LogDiagnostics)
         Print("Filling mode: FOK supported");
      return ORDER_FILLING_FOK;
   }
   
   if((fillingModes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
   {
      if(LogDiagnostics)
         Print("Filling mode: IOC supported");
      return ORDER_FILLING_IOC;
   }
   
   if(LogDiagnostics)
      Print("Filling mode: Using RETURN (default)");
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!m_symbol.RefreshRates())
      return;
   
   datetime currentTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   
   int currentMinutes = timeStruct.hour * 60 + timeStruct.min;
   int rangeStartMinutes = RangeStartHour * 60 + RangeStartMinute;
   int rangeEndMinutes = RangeEndHour * 60 + RangeEndMinute;
   int tradingEndMinutes = TradingEndHour * 60 + TradingEndMinute;
   int weeklyCleanupMinutes = WeeklyCleanupHour * 60 + WeeklyCleanupMinute;
   
   // Manage existing positions (BE and Trailing) - do this first
   if(UseBreakEven || UseTrailingStop)
   {
      ManageOpenPositions();
   }
   
   // Weekly cleanup (default: Friday at 22:00) - delete all weekly rectangles
   if(timeStruct.day_of_week == WeeklyCleanupDay && currentMinutes >= weeklyCleanupMinutes)
   {
      datetime today = iTime(_Symbol, PERIOD_D1, 0);
      
      if(g_lastFridayCleanup != today)
      {
         DeleteWeeklyRectangles();
         g_lastFridayCleanup = today;
         CloseAllPositions();
         Print("Weekly cleanup completed");
      }
      return;
   }
   
   // Check for new day - reset trading variables but DON'T delete rectangle
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_currentDay)
   {
      g_currentDay = today;
      ResetDailyVariables();
      g_rectName = GetRectangleName(today);
      Print("New trading day started. Rectangle name: ", g_rectName);
   }
   
   // Check if we should close all positions (daily trading end)
   if(currentMinutes >= tradingEndMinutes)
   {
      CloseAllPositions();
      return;
   }
   
   // Range Building Phase
   if(currentMinutes >= rangeStartMinutes && currentMinutes < rangeEndMinutes)
   {
      if(!g_rangeBuilding && !g_rangeComplete)
      {
         // Start building range
         g_rangeBuilding = true;
         g_rangeStartTime = GetTimeForToday(RangeStartHour, RangeStartMinute);
         g_rangeEndTime = GetTimeForToday(RangeEndHour, RangeEndMinute);
         g_rangeHigh = iHigh(_Symbol, PERIOD_CURRENT, 0);
         g_rangeLow = iLow(_Symbol, PERIOD_CURRENT, 0);
         Print("Range building started");
      }
      
      if(g_rangeBuilding)
      {
         UpdateRange();
         DrawRectangle();
      }
   }
   // Range Complete - Trading Phase
   else if(currentMinutes >= rangeEndMinutes && currentMinutes < tradingEndMinutes)
   {
      if(g_rangeBuilding)
      {
         g_rangeBuilding = false;
         g_rangeComplete = true;
         
         // Validate range size
         ValidateRangeSize();
         
         Print("Range completed - High: ", g_rangeHigh, " Low: ", g_rangeLow, 
               " | Valid: ", !g_rangeInvalid);
      }
      
      if(g_rangeComplete && !g_rangeInvalid)
      {
         CheckForBreakout();
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate historical performance stats from deal history         |
//+------------------------------------------------------------------+
void CalculateHistoricalStats()
{
   // Reset stats
   g_stats.totalTrades = 0;
   g_stats.wins = 0;
   g_stats.losses = 0;
   g_stats.totalProfit = 0;
   g_stats.totalLoss = 0;
   g_stats.todayPL = 0;
   g_stats.bestTrade = 0;
   g_stats.worstTrade = 0;
   
   // Get start of today
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime startOfDay = StructToTime(dt);
   
   // Select all history
   if(!HistorySelect(0, TimeCurrent()))
      return;
   
   int totalDeals = HistoryDealsTotal();
   
   for(int i = 0; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      
      // Check if this deal belongs to our EA
      ulong dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      string dealSymbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      
      if(dealMagic != MagicNumber || dealSymbol != _Symbol)
         continue;
      
      // Only count exit deals
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;
      
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double totalPL = profit + swap + commission;
      
      datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      
      g_stats.totalTrades++;
      
      if(totalPL >= 0)
      {
         g_stats.wins++;
         g_stats.totalProfit += totalPL;
         if(totalPL > g_stats.bestTrade)
            g_stats.bestTrade = totalPL;
      }
      else
      {
         g_stats.losses++;
         g_stats.totalLoss += MathAbs(totalPL);
         if(totalPL < g_stats.worstTrade)
            g_stats.worstTrade = totalPL;
      }
      
      // Today's P/L
      if(dealTime >= startOfDay)
      {
         g_stats.todayPL += totalPL;
      }
   }
   
   // Add floating P/L from open positions
   double floatingPL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
         {
            floatingPL += m_position.Profit() + m_position.Swap();
         }
      }
   }
   g_stats.todayPL += floatingPL;
   
   g_stats.lastUpdate = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Create performance dashboard                                      |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   int panelWidth = DashboardWidth;
   int panelHeight = DashboardHeight;
   
   // Background
   CreateRectLabel(g_prefix + "BG", DashboardX, DashboardY, panelWidth, panelHeight, DashColorBG, DashColorBorder);
   
   // Title with symbol
   string title = "RangeBreakout - " + _Symbol;
   CreateLabel(g_prefix + "Title", DashboardX + 8, DashboardY + 5, title, DashColorText, 9, true);
   
   // Separator
   CreateLine(g_prefix + "Sep1", DashboardX + 8, DashboardY + 22, DashboardX + panelWidth - 8, DashboardY + 22, DashColorBorder);
   
   // Calculate column positions
   int col1 = DashboardX + 8;
   int col2 = DashboardX + (int)(panelWidth * 0.26);
   int col3 = DashboardX + (int)(panelWidth * 0.52);
   int col4 = DashboardX + (int)(panelWidth * 0.77);
   
   // === ROW 1: Trade Stats ===
   int y = DashboardY + 28;
   
   CreateLabel(g_prefix + "LblTrades", col1, y, "Trades:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValTrades", col1 + 42, y, "0", DashColorText, 8, false);
   
   CreateLabel(g_prefix + "LblWins", col2, y, "W:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValWins", col2 + 18, y, "0", DashColorProfit, 8, false);
   
   CreateLabel(g_prefix + "LblLosses", col2 + 40, y, "L:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValLosses", col2 + 53, y, "0", DashColorLoss, 8, false);
   
   CreateLabel(g_prefix + "LblWinRate", col3, y, "WinRate:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValWinRate", col3 + 50, y, "0%", DashColorText, 8, false);
   
   CreateLabel(g_prefix + "LblPositions", col4, y, "Open:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValPositions", col4 + 35, y, "0", DashColorText, 8, false);
   
   // === ROW 2: P/L Stats ===
   y += 16;
   
   CreateLabel(g_prefix + "LblNetPL", col1, y, "Net P/L:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValNetPL", col1 + 45, y, "0.00", DashColorText, 8, true);
   
   CreateLabel(g_prefix + "LblToday", col2 + 25, y, "Today:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValToday", col2 + 65, y, "0.00", DashColorText, 8, true);
   
   CreateLabel(g_prefix + "LblPF", col4, y, "PF:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValPF", col4 + 22, y, "0.00", DashColorText, 8, false);
   
   // === ROW 3: Best/Worst ===
   y += 16;
   
   CreateLabel(g_prefix + "LblBest", col1, y, "Best:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValBest", col1 + 32, y, "0.00", DashColorProfit, 8, false);
   
   CreateLabel(g_prefix + "LblWorst", col2, y, "Worst:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValWorst", col2 + 38, y, "0.00", DashColorLoss, 8, false);
   
   CreateLabel(g_prefix + "LblAvgWin", col3, y, "AvgW:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValAvgWin", col3 + 35, y, "0.00", DashColorProfit, 8, false);
   
   CreateLabel(g_prefix + "LblAvgLoss", col4, y, "AvgL:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValAvgLoss", col4 + 32, y, "0.00", DashColorLoss, 8, false);
   
   // === Bottom: Range Info ===
   y += 18;
   CreateLine(g_prefix + "Sep2", DashboardX + 8, y, DashboardX + panelWidth - 8, y, DashColorBorder);
   y += 4;
   
   string rangeInfo = "Range: " + StringFormat("%02d:%02d-%02d:%02d", RangeStartHour, RangeStartMinute, RangeEndHour, RangeEndMinute) + 
                      " | TP: " + DoubleToString(TPMultiple, 1) + "x" +
                      " | Risk: " + DoubleToString(RiskAmount, 0);
   CreateLabel(g_prefix + "RangeInfo", col1, y, rangeInfo, DashColorLabel, 7, false);
   
   // Range status indicator
   CreateLabel(g_prefix + "LblStatus", col4 - 10, y, "Status:", DashColorLabel, 7, false);
   CreateLabel(g_prefix + "ValStatus", col4 + 30, y, "---", DashColorLabel, 7, false);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update dashboard values                                           |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!ShowDashboard) return;
   
   // Calculate derived stats
   double netPL = g_stats.totalProfit - g_stats.totalLoss;
   double winRate = g_stats.totalTrades > 0 ? (double)g_stats.wins / g_stats.totalTrades * 100.0 : 0;
   double profitFactor = g_stats.totalLoss > 0 ? g_stats.totalProfit / g_stats.totalLoss : 0;
   double avgWin = g_stats.wins > 0 ? g_stats.totalProfit / g_stats.wins : 0;
   double avgLoss = g_stats.losses > 0 ? g_stats.totalLoss / g_stats.losses : 0;
   int openPos = CountOpenPositions();
   
   // Update values
   ObjectSetString(0, g_prefix + "ValTrades", OBJPROP_TEXT, IntegerToString(g_stats.totalTrades));
   ObjectSetString(0, g_prefix + "ValWins", OBJPROP_TEXT, IntegerToString(g_stats.wins));
   ObjectSetString(0, g_prefix + "ValLosses", OBJPROP_TEXT, IntegerToString(g_stats.losses));
   ObjectSetString(0, g_prefix + "ValWinRate", OBJPROP_TEXT, DoubleToString(winRate, 1) + "%");
   ObjectSetString(0, g_prefix + "ValPositions", OBJPROP_TEXT, IntegerToString(openPos));
   
   // Net P/L with color
   ObjectSetString(0, g_prefix + "ValNetPL", OBJPROP_TEXT, FormatPL(netPL));
   ObjectSetInteger(0, g_prefix + "ValNetPL", OBJPROP_COLOR, netPL >= 0 ? DashColorProfit : DashColorLoss);
   
   // Today's P/L with color
   ObjectSetString(0, g_prefix + "ValToday", OBJPROP_TEXT, FormatPL(g_stats.todayPL));
   ObjectSetInteger(0, g_prefix + "ValToday", OBJPROP_COLOR, g_stats.todayPL >= 0 ? DashColorProfit : DashColorLoss);
   
   // Profit Factor
   ObjectSetString(0, g_prefix + "ValPF", OBJPROP_TEXT, profitFactor > 0 ? DoubleToString(profitFactor, 2) : "-");
   ObjectSetInteger(0, g_prefix + "ValPF", OBJPROP_COLOR, profitFactor >= 1.0 ? DashColorProfit : DashColorLoss);
   
   // Best/Worst trades
   ObjectSetString(0, g_prefix + "ValBest", OBJPROP_TEXT, DoubleToString(g_stats.bestTrade, 1));
   ObjectSetString(0, g_prefix + "ValWorst", OBJPROP_TEXT, DoubleToString(g_stats.worstTrade, 1));
   
   // Averages
   ObjectSetString(0, g_prefix + "ValAvgWin", OBJPROP_TEXT, DoubleToString(avgWin, 1));
   ObjectSetString(0, g_prefix + "ValAvgLoss", OBJPROP_TEXT, DoubleToString(avgLoss, 1));
   
   // Range status
   string status = "---";
   color statusColor = DashColorLabel;
   
   if(g_rangeBuilding)
   {
      status = "BUILDING";
      statusColor = clrOrange;
   }
   else if(g_rangeComplete && !g_rangeInvalid)
   {
      if(g_longTaken && g_shortTaken)
      {
         status = "DONE";
         statusColor = DashColorLabel;
      }
      else
      {
         status = "TRADING";
         statusColor = DashColorProfit;
      }
   }
   else if(g_rangeInvalid)
   {
      status = "INVALID";
      statusColor = DashColorLoss;
   }
   
   ObjectSetString(0, g_prefix + "ValStatus", OBJPROP_TEXT, status);
   ObjectSetInteger(0, g_prefix + "ValStatus", OBJPROP_COLOR, statusColor);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Format P/L value with sign                                        |
//+------------------------------------------------------------------+
string FormatPL(double value)
{
   string sign = value >= 0 ? "+" : "";
   return sign + DoubleToString(value, 2);
}

//+------------------------------------------------------------------+
//| Delete dashboard objects                                          |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Create rectangle label helper                                     |
//+------------------------------------------------------------------+
void CreateRectLabel(string name, int x, int y, int width, int height, color bgColor, color borderColor)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Create label helper                                               |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, bool bold)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Create line helper                                                |
//+------------------------------------------------------------------+
void CreateLine(string name, int x1, int y1, int x2, int y2, color clr)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x1);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y1);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, x2 - x1);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Count open positions                                              |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Manage open positions - Break-Even and Trailing Stop             |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;
         
      if(m_position.Symbol() != _Symbol || m_position.Magic() != MagicNumber)
         continue;
      
      ulong ticket = m_position.Ticket();
      double entryPrice = m_position.PriceOpen();
      double currentSL = m_position.StopLoss();
      double currentTP = m_position.TakeProfit();
      ENUM_POSITION_TYPE posType = m_position.PositionType();
      
      // Calculate entry-to-TP distance
      double entryToTPDistance = 0;
      double currentPrice = 0;
      double progressDistance = 0;
      
      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = m_symbol.Bid();
         entryToTPDistance = currentTP - entryPrice;
         progressDistance = currentPrice - entryPrice;
      }
      else // POSITION_TYPE_SELL
      {
         currentPrice = m_symbol.Ask();
         entryToTPDistance = entryPrice - currentTP;
         progressDistance = entryPrice - currentPrice;
      }
      
      // Safety check
      if(entryToTPDistance <= 0)
         continue;
      
      // Calculate progress as percentage of entry-to-TP distance
      double progressPercent = (progressDistance / entryToTPDistance) * 100.0;
      
      // Break-Even Logic
      if(UseBreakEven && !IsBreakEvenApplied(ticket))
      {
         if(progressPercent >= BETriggerPercent)
         {
            double beDistance = entryToTPDistance * (BEBufferPercent / 100.0);
            double newSL = 0;
            
            if(posType == POSITION_TYPE_BUY)
            {
               newSL = entryPrice + beDistance;
               newSL = NormalizePrice(newSL);
               
               if(newSL > currentSL)
               {
                  if(ModifyPosition(ticket, newSL, currentTP))
                  {
                     MarkBreakEvenApplied(ticket);
                     Print("Break-Even applied to LONG ticket #", ticket,
                           " | Entry: ", entryPrice,
                           " | New SL: ", newSL,
                           " | Progress: ", DoubleToString(progressPercent, 1), "% of Entry-to-TP");
                  }
               }
            }
            else // POSITION_TYPE_SELL
            {
               newSL = entryPrice - beDistance;
               newSL = NormalizePrice(newSL);
               
               if(newSL < currentSL || currentSL == 0)
               {
                  if(ModifyPosition(ticket, newSL, currentTP))
                  {
                     MarkBreakEvenApplied(ticket);
                     Print("Break-Even applied to SHORT ticket #", ticket,
                           " | Entry: ", entryPrice,
                           " | New SL: ", newSL,
                           " | Progress: ", DoubleToString(progressPercent, 1), "% of Entry-to-TP");
                  }
               }
            }
         }
      }
      
      // Trailing Stop Logic
      if(UseTrailingStop)
      {
         if(progressPercent >= TrailingActivationPercent)
         {
            double trailDistance = entryToTPDistance * (TrailingDistancePercent / 100.0);
            double newSL = 0;
            
            if(posType == POSITION_TYPE_BUY)
            {
               newSL = currentPrice - trailDistance;
               newSL = NormalizePrice(newSL);
               
               // Only move SL up, never down
               if(newSL > currentSL)
               {
                  // Check minimum stop level
                  double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();
                  if(currentPrice - newSL >= minStopLevel)
                  {
                     if(ModifyPosition(ticket, newSL, currentTP))
                     {
                        if(LogDiagnostics)
                        {
                           Print("Trailing Stop updated for LONG ticket #", ticket,
                                 " | Price: ", currentPrice,
                                 " | New SL: ", newSL,
                                 " | Progress: ", DoubleToString(progressPercent, 1), "% of Entry-to-TP");
                        }
                     }
                  }
               }
            }
            else // POSITION_TYPE_SELL
            {
               newSL = currentPrice + trailDistance;
               newSL = NormalizePrice(newSL);
               
               // Only move SL down, never up
               if(newSL < currentSL || currentSL == 0)
               {
                  // Check minimum stop level
                  double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();
                  if(newSL - currentPrice >= minStopLevel)
                  {
                     if(ModifyPosition(ticket, newSL, currentTP))
                     {
                        if(LogDiagnostics)
                        {
                           Print("Trailing Stop updated for SHORT ticket #", ticket,
                                 " | Price: ", currentPrice,
                                 " | New SL: ", newSL,
                                 " | Progress: ", DoubleToString(progressPercent, 1), "% of Entry-to-TP");
                        }
                     }
                  }
               }
            }
         }
      }
   }
   
   // Clean up closed position tickets from BE tracking array
   CleanupClosedTickets();
}

//+------------------------------------------------------------------+
//| Check if break-even has been applied to a ticket                 |
//+------------------------------------------------------------------+
bool IsBreakEvenApplied(ulong ticket)
{
   int size = ArraySize(g_beAppliedTickets);
   for(int i = 0; i < size; i++)
   {
      if(g_beAppliedTickets[i] == ticket)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Mark a ticket as having break-even applied                       |
//+------------------------------------------------------------------+
void MarkBreakEvenApplied(ulong ticket)
{
   int size = ArraySize(g_beAppliedTickets);
   ArrayResize(g_beAppliedTickets, size + 1);
   g_beAppliedTickets[size] = ticket;
}

//+------------------------------------------------------------------+
//| Remove closed position tickets from tracking array               |
//+------------------------------------------------------------------+
void CleanupClosedTickets()
{
   ulong activeTickets[];
   int activeCount = 0;
   
   // Collect all active tickets for this EA
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
         {
            ArrayResize(activeTickets, activeCount + 1);
            activeTickets[activeCount] = m_position.Ticket();
            activeCount++;
         }
      }
   }
   
   // Rebuild BE tracking array with only active tickets
   ulong newBETickets[];
   int newCount = 0;
   
   for(int i = 0; i < ArraySize(g_beAppliedTickets); i++)
   {
      bool isActive = false;
      for(int j = 0; j < activeCount; j++)
      {
         if(g_beAppliedTickets[i] == activeTickets[j])
         {
            isActive = true;
            break;
         }
      }
      
      if(isActive)
      {
         ArrayResize(newBETickets, newCount + 1);
         newBETickets[newCount] = g_beAppliedTickets[i];
         newCount++;
      }
   }
   
   ArrayFree(g_beAppliedTickets);
   ArrayResize(g_beAppliedTickets, newCount);
   for(int i = 0; i < newCount; i++)
   {
      g_beAppliedTickets[i] = newBETickets[i];
   }
}

//+------------------------------------------------------------------+
//| Modify position SL/TP                                            |
//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double newSL, double newTP)
{
   if(!m_position.SelectByTicket(ticket))
   {
      Print("ERROR: Cannot select position ticket #", ticket);
      return false;
   }
   
   double currentSL = m_position.StopLoss();
   double currentTP = m_position.TakeProfit();
   
   if(MathAbs(newSL - currentSL) < m_symbol.Point() && 
      MathAbs(newTP - currentTP) < m_symbol.Point())
   {
      return false; // No change needed
   }
   
   if(m_trade.PositionModify(ticket, newSL, newTP))
   {
      return true;
   }
   else
   {
      Print("ERROR: Failed to modify position #", ticket, 
            " | Error: ", GetLastError(), 
            " | ", m_trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Normalize price to symbol digits                                 |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//| Validate range size against filters                               |
//+------------------------------------------------------------------+
void ValidateRangeSize()
{
   if(g_rangeHigh == 0 || g_rangeLow == 0)
   {
      g_rangeInvalid = true;
      return;
   }
   
   double midPrice = (g_rangeHigh + g_rangeLow) / 2.0;
   double rangeSize = g_rangeHigh - g_rangeLow;
   double rangeSizePercent = (rangeSize / midPrice) * 100.0;
   
   if(rangeSizePercent < MinRangePercent)
   {
      g_rangeInvalid = true;
      Print("Range too small: ", DoubleToString(rangeSizePercent, 3), 
            "% < ", MinRangePercent, "% minimum");
   }
   else if(rangeSizePercent > MaxRangePercent)
   {
      g_rangeInvalid = true;
      Print("Range too large: ", DoubleToString(rangeSizePercent, 3), 
            "% > ", MaxRangePercent, "% maximum");
   }
   else
   {
      g_rangeInvalid = false;
      if(LogDiagnostics)
         Print("Range size valid: ", DoubleToString(rangeSizePercent, 3), "%");
   }
}

//+------------------------------------------------------------------+
//| Reset daily variables                                             |
//+------------------------------------------------------------------+
void ResetDailyVariables()
{
   g_rangeHigh = 0;
   g_rangeLow = 0;
   g_rangeStartTime = 0;
   g_rangeEndTime = 0;
   g_rangeBuilding = false;
   g_rangeComplete = false;
   g_rangeInvalid = false;
   g_longTaken = false;
   g_shortTaken = false;
}

//+------------------------------------------------------------------+
//| Rebuild range from historical data if needed                      |
//+------------------------------------------------------------------+
void RebuildRangeIfNeeded()
{
   MqlDateTime timeStruct;
   TimeToStruct(TimeCurrent(), timeStruct);
   
   int currentMinutes = timeStruct.hour * 60 + timeStruct.min;
   int rangeStartMinutes = RangeStartHour * 60 + RangeStartMinute;
   int rangeEndMinutes = RangeEndHour * 60 + RangeEndMinute;
   int tradingEndMinutes = TradingEndHour * 60 + TradingEndMinute;
   
   // Only rebuild if we're in the trading phase (after range, before close)
   if(currentMinutes >= rangeEndMinutes && currentMinutes < tradingEndMinutes)
   {
      g_rangeStartTime = GetTimeForToday(RangeStartHour, RangeStartMinute);
      g_rangeEndTime = GetTimeForToday(RangeEndHour, RangeEndMinute);
      
      int bars = Bars(_Symbol, PERIOD_CURRENT, g_rangeStartTime, g_rangeEndTime);
      if(bars <= 0) 
      {
         Print("No bars found for range reconstruction");
         return;
      }
      
      double high = 0;
      double low = DBL_MAX;
      
      int startShift = iBarShift(_Symbol, PERIOD_CURRENT, g_rangeStartTime);
      int endShift = iBarShift(_Symbol, PERIOD_CURRENT, g_rangeEndTime);
      
      for(int i = endShift; i <= startShift; i++)
      {
         double barHigh = iHigh(_Symbol, PERIOD_CURRENT, i);
         double barLow = iLow(_Symbol, PERIOD_CURRENT, i);
         
         if(barHigh > high) high = barHigh;
         if(barLow < low) low = barLow;
      }
      
      if(high > 0 && low < DBL_MAX)
      {
         g_rangeHigh = high;
         g_rangeLow = low;
         g_rangeComplete = true;
         
         // Validate range size
         ValidateRangeSize();
         
         DrawRectangle();
         Print("Range reconstructed - High: ", g_rangeHigh, " Low: ", g_rangeLow,
               " | Valid: ", !g_rangeInvalid);
      }
   }
   // If we're during range building phase, start building
   else if(currentMinutes >= rangeStartMinutes && currentMinutes < rangeEndMinutes)
   {
      g_rangeBuilding = true;
      g_rangeStartTime = GetTimeForToday(RangeStartHour, RangeStartMinute);
      g_rangeEndTime = GetTimeForToday(RangeEndHour, RangeEndMinute);
      UpdateRange();
      DrawRectangle();
      Print("Range building resumed after restart");
   }
}

//+------------------------------------------------------------------+
//| Get rectangle name for a specific day                             |
//+------------------------------------------------------------------+
string GetRectangleName(datetime day)
{
   MqlDateTime dt;
   TimeToStruct(day, dt);
   return StringFormat("RangeBox_%s_%04d%02d%02d", _Symbol, dt.year, dt.mon, dt.day);
}

//+------------------------------------------------------------------+
//| Update range high and low                                         |
//+------------------------------------------------------------------+
void UpdateRange()
{
   datetime rangeStart = GetTimeForToday(RangeStartHour, RangeStartMinute);
   
   int bars = Bars(_Symbol, PERIOD_CURRENT, rangeStart, TimeCurrent());
   if(bars <= 0) return;
   
   double high = 0;
   double low = DBL_MAX;
   
   for(int i = 0; i < bars; i++)
   {
      double barHigh = iHigh(_Symbol, PERIOD_CURRENT, i);
      double barLow = iLow(_Symbol, PERIOD_CURRENT, i);
      
      if(barHigh > high) high = barHigh;
      if(barLow < low) low = barLow;
   }
   
   g_rangeHigh = high;
   g_rangeLow = low;
}

//+------------------------------------------------------------------+
//| Draw or update rectangle                                          |
//+------------------------------------------------------------------+
void DrawRectangle()
{
   datetime time1 = GetTimeForToday(RangeStartHour, RangeStartMinute);
   datetime time2 = GetTimeForToday(RangeEndHour, RangeEndMinute);
   
   if(ObjectFind(0, g_rectName) < 0)
   {
      ObjectCreate(0, g_rectName, OBJ_RECTANGLE, 0, time1, g_rangeHigh, time2, g_rangeLow);
      ObjectSetInteger(0, g_rectName, OBJPROP_COLOR, RangeColor);
      ObjectSetInteger(0, g_rectName, OBJPROP_FILL, true);
      ObjectSetInteger(0, g_rectName, OBJPROP_BACK, true);
      ObjectSetInteger(0, g_rectName, OBJPROP_SELECTABLE, false);
      
      int alpha = (int)(255 * RangeOpacity / 100);
      color clr = RangeColor;
      ObjectSetInteger(0, g_rectName, OBJPROP_COLOR, clr);
   }
   else
   {
      ObjectSetDouble(0, g_rectName, OBJPROP_PRICE, 0, g_rangeHigh);
      ObjectSetDouble(0, g_rectName, OBJPROP_PRICE, 1, g_rangeLow);
   }
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Delete all range rectangles from this week                        |
//+------------------------------------------------------------------+
void DeleteWeeklyRectangles()
{
   int totalObjects = ObjectsTotal(0, 0, OBJ_RECTANGLE);
   int deletedCount = 0;
   
   for(int i = totalObjects - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, OBJ_RECTANGLE);
      
      if(StringFind(name, "RangeBox_" + _Symbol + "_") >= 0)
      {
         ObjectDelete(0, name);
         deletedCount++;
         Print("Deleted rectangle: ", name);
      }
   }
   
   ChartRedraw(0);
   Print("Weekly cleanup: Deleted ", deletedCount, " rectangles for ", _Symbol);
}

//+------------------------------------------------------------------+
//| Check for breakout and enter trades                               |
//+------------------------------------------------------------------+
void CheckForBreakout()
{
   if(g_rangeHigh == 0 || g_rangeLow == 0) return;
   
   // Get last closed candle
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
   double rangeSize = g_rangeHigh - g_rangeLow;
   
   // Check for long breakout
   if(!g_longTaken && closePrice > g_rangeHigh)
   {
      double entryPrice = m_symbol.Ask();
      double sl = g_rangeLow - SLBuffer * _Point;
      double tp = g_rangeHigh + (rangeSize * TPMultiple);
      
      // Normalize prices
      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);
      
      double entryToTP = tp - entryPrice;
      
      if(LogDiagnostics)
      {
         Print("========== LONG BREAKOUT ==========");
         Print("Entry: ", entryPrice, " | SL: ", sl, " | TP: ", tp);
         Print("Entry-to-TP: ", DoubleToString(entryToTP, _Digits), " points");
         Print("BE triggers at ", BETriggerPercent, "% = ", DoubleToString(entryPrice + entryToTP * BETriggerPercent / 100.0, _Digits));
         Print("Trailing activates at ", TrailingActivationPercent, "% = ", DoubleToString(entryPrice + entryToTP * TrailingActivationPercent / 100.0, _Digits));
      }
      
      double lotSize = CalculateLotSize(ORDER_TYPE_BUY, entryPrice, sl);
      
      if(lotSize > 0)
      {
         if(OpenTrade(ORDER_TYPE_BUY, lotSize, sl, tp))
         {
            g_longTaken = true;
            Print("Long breakout trade opened");
            
            // Update stats immediately
            if(ShowDashboard)
            {
               CalculateHistoricalStats();
               UpdateDashboard();
            }
         }
      }
   }
   
   // Check for short breakout
   if(!g_shortTaken && closePrice < g_rangeLow)
   {
      double entryPrice = m_symbol.Bid();
      double sl = g_rangeHigh + SLBuffer * _Point;
      double tp = g_rangeLow - (rangeSize * TPMultiple);
      
      // Normalize prices
      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);
      
      double entryToTP = entryPrice - tp;
      
      if(LogDiagnostics)
      {
         Print("========== SHORT BREAKOUT ==========");
         Print("Entry: ", entryPrice, " | SL: ", sl, " | TP: ", tp);
         Print("Entry-to-TP: ", DoubleToString(entryToTP, _Digits), " points");
         Print("BE triggers at ", BETriggerPercent, "% = ", DoubleToString(entryPrice - entryToTP * BETriggerPercent / 100.0, _Digits));
         Print("Trailing activates at ", TrailingActivationPercent, "% = ", DoubleToString(entryPrice - entryToTP * TrailingActivationPercent / 100.0, _Digits));
      }
      
      double lotSize = CalculateLotSize(ORDER_TYPE_SELL, entryPrice, sl);
      
      if(lotSize > 0)
      {
         if(OpenTrade(ORDER_TYPE_SELL, lotSize, sl, tp))
         {
            g_shortTaken = true;
            Print("Short breakout trade opened");
            
            // Update stats immediately
            if(ShowDashboard)
            {
               CalculateHistoricalStats();
               UpdateDashboard();
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size using OrderCalcProfit (accurate method)        |
//+------------------------------------------------------------------+
double CalculateLotSize(ENUM_ORDER_TYPE orderType, double entryPrice, double stopLossPrice)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Calculate loss per 1.0 lot using OrderCalcProfit
   double lossPerLot = 0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, stopLossPrice, lossPerLot))
   {
      Print("ERROR: OrderCalcProfit failed. Error: ", GetLastError());
      return 0;
   }
   
   lossPerLot = MathAbs(lossPerLot);
   
   if(lossPerLot < 0.0001)
   {
      Print("ERROR: Loss per lot is zero. Cannot calculate position size.");
      return 0;
   }
   
   // Calculate lot size based on risk
   double volume = RiskAmount / lossPerLot;
   
   // Normalize to lot step
   volume = MathFloor(volume / lotStep) * lotStep;
   
   // Apply limits
   if(volume < minLot) volume = minLot;
   if(volume > maxLot) volume = maxLot;
   
   // Calculate precision for lot step
   int digits = 0;
   double temp = lotStep;
   while(temp < 1.0 && digits < 8)
   {
      temp *= 10;
      digits++;
   }
   
   volume = NormalizeDouble(volume, digits);
   
   if(LogDiagnostics)
   {
      Print("Risk Amount: ", RiskAmount, " | Loss/Lot: ", lossPerLot, " | Volume: ", volume);
   }
   
   return volume;
}

//+------------------------------------------------------------------+
//| Open a trade with margin check                                    |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType, double lots, double sl, double tp)
{
   double entryPrice = (orderType == ORDER_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
   
   // Check margin before trading
   double requiredMargin = 0;
   if(!OrderCalcMargin(orderType, _Symbol, lots, entryPrice, requiredMargin))
   {
      Print("ERROR: Cannot calculate margin. Trade aborted.");
      return false;
   }
   
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(requiredMargin > freeMargin)
   {
      Print("ERROR: Insufficient margin. Required: ", requiredMargin, " | Available: ", freeMargin);
      return false;
   }
   
   // Execute trade
   string comment = "RangeBreakout";
   bool result = false;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      result = m_trade.Buy(lots, _Symbol, entryPrice, sl, tp, comment);
   }
   else
   {
      result = m_trade.Sell(lots, _Symbol, entryPrice, sl, tp, comment);
   }
   
   if(result)
   {
      Print("========== TRADE EXECUTED ==========");
      Print("Type: ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), " | Volume: ", lots, " lots");
      Print("Entry: ", entryPrice, " | SL: ", sl, " | TP: ", tp);
      Print("Risk: ", RiskAmount, " | Margin: ", requiredMargin);
      Print("=====================================");
      return true;
   }
   else
   {
      Print("========== TRADE FAILED ==========");
      Print("Error: ", GetLastError(), " | ", m_trade.ResultRetcodeDescription());
      Print("===================================");
      return false;
   }
}

//+------------------------------------------------------------------+
//| Close all positions for this EA                                   |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      if(m_trade.PositionClose(ticket))
      {
         Print("Position closed. Ticket: ", ticket);
      }
      else
      {
         Print("Close position error: ", GetLastError(), " | ", m_trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| Get datetime for today at specific hour:minute                    |
//+------------------------------------------------------------------+
datetime GetTimeForToday(int hour, int minute)
{
   MqlDateTime timeStruct;
   TimeToStruct(TimeCurrent(), timeStruct);
   
   timeStruct.hour = hour;
   timeStruct.min = minute;
   timeStruct.sec = 0;
   
   return StructToTime(timeStruct);
}
//+------------------------------------------------------------------+

