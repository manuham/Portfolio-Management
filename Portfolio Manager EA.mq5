//+------------------------------------------------------------------+
//|                                         Portfolio_Manager_EA.mq5 |
//|                                                            Manuel |
//|                         Portfolio-Wide Risk & Position Management |
//|                                                                   |
//| Features:                                                         |
//|   - Track positions across multiple EAs (by magic number)         |
//|   - Monitor total portfolio heat (open risk)                      |
//|   - Enforce max daily loss across entire portfolio                |
//|   - Enforce max total heat limit                                  |
//|   - Aggregated dashboard with position breakdown                  |
//|   - Alert system when approaching limits                          |
//|   - Global variable signaling to pause other EAs                  |
//+------------------------------------------------------------------+
#property copyright "Manuel"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== EA Tracking ==="
input string   MagicNumberList = "100001,100002,100003";  // Magic Numbers to Track (comma-separated, empty = all)
input bool     TrackAllPositions = false;                  // Track ALL Account Positions (ignore magic list)

input group "=== Risk Limits ==="
input double   MaxDailyLoss = 500.0;           // Max Daily Loss (account currency, 0 = disabled)
input double   MaxWeeklyLoss = 1500.0;         // Max Weekly Loss (account currency, 0 = disabled)
input double   MaxTotalHeat = 1000.0;          // Max Total Heat/Open Risk (account currency, 0 = disabled)
input double   MaxDrawdownPercent = 5.0;       // Max Drawdown (% of balance, 0 = disabled)

input group "=== Actions ==="
input bool     CloseOnDailyLimit = true;       // Close All Positions on Daily Limit
input bool     CloseOnWeeklyLimit = true;      // Close All Positions on Weekly Limit
input bool     CloseOnDrawdownLimit = true;    // Close All Positions on Drawdown Limit
input bool     SignalOtherEAs = true;          // Signal Other EAs to Stop Trading

input group "=== Alert Settings ==="
input bool     EnableAlerts = true;            // Enable Alerts
input int      AlertThresholdPercent = 80;     // Alert When Reaching X% of Limit
input bool     SendPushNotification = false;   // Send Push Notifications
input bool     SendEmail = false;              // Send Email Notifications

input group "=== Dashboard Settings ==="
input bool     ShowDashboard = true;           // Show Dashboard
input int      DashboardX = 10;                // Dashboard X Position
input int      DashboardY = 20;                // Dashboard Y Position
input int      DashboardWidth = 400;           // Dashboard Width
input color    DashColorBG = C'20,20,20';      // Background Color
input color    DashColorBorder = C'60,60,60';  // Border Color
input color    DashColorTitle = clrGold;       // Title Color
input color    DashColorText = clrWhite;       // Text Color
input color    DashColorLabel = clrGray;       // Label Color
input color    DashColorProfit = clrLime;      // Profit Color
input color    DashColorLoss = clrRed;         // Loss Color
input color    DashColorWarning = clrOrange;   // Warning Color

input group "=== General ==="
input int      UpdateIntervalSeconds = 2;      // Update Interval (seconds)
input bool     LogDiagnostics = true;          // Extended Diagnostics Logging

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
string g_prefix = "PortMgr_";
string g_globalVarName = "PORTFOLIO_TRADING_BLOCKED";

// Tracked magic numbers
ulong g_magicNumbers[];
int g_magicCount = 0;

// Portfolio stats
struct PortfolioStats
{
   int      totalPositions;
   double   totalHeat;           // Open risk (potential loss to SL)
   double   totalFloatingPL;
   double   todayPL;
   double   weekPL;
   double   totalVolume;
   double   totalMarginUsed;
   datetime lastUpdate;
};

PortfolioStats g_portfolio;

// Position breakdown by symbol
struct SymbolBreakdown
{
   string   symbol;
   int      count;
   double   volume;
   double   floatingPL;
   double   heat;
};

SymbolBreakdown g_symbols[];
int g_symbolCount = 0;

// Position breakdown by EA (magic)
struct EABreakdown
{
   ulong    magic;
   int      count;
   double   volume;
   double   floatingPL;
   double   heat;
};

EABreakdown g_eas[];
int g_eaCount = 0;

// State tracking
bool g_dailyLimitHit = false;
bool g_weeklyLimitHit = false;
bool g_heatLimitHit = false;
bool g_drawdownLimitHit = false;
datetime g_lastAlertTime = 0;
datetime g_currentDay = 0;
datetime g_currentWeek = 0;

CTrade m_trade;
CPositionInfo m_position;
CSymbolInfo m_symbol;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Parse magic number list
   ParseMagicNumbers();

   // Initialize trade object
   m_trade.SetDeviationInPoints(30);

   // Get filling mode for current chart symbol
   ENUM_ORDER_TYPE_FILLING fillingMode = GetFillingMode();
   m_trade.SetTypeFilling(fillingMode);

   // Initialize dates
   g_currentDay = GetStartOfDay(TimeCurrent());
   g_currentWeek = GetStartOfWeek(TimeCurrent());

   // Reset limits for new day/week
   ResetLimitsIfNeeded();

   // Initialize global variable
   if(SignalOtherEAs)
   {
      GlobalVariableSet(g_globalVarName, 0);  // 0 = trading allowed
   }

   // Create dashboard
   if(ShowDashboard)
      CreateDashboard();

   // Initial update
   UpdatePortfolioStats();

   Print("===== Portfolio Manager Initialized =====");
   Print("Tracking: ", TrackAllPositions ? "ALL positions" : "Magic numbers: " + MagicNumberList);
   Print("Max Daily Loss: ", MaxDailyLoss > 0 ? DoubleToString(MaxDailyLoss, 2) : "Disabled");
   Print("Max Weekly Loss: ", MaxWeeklyLoss > 0 ? DoubleToString(MaxWeeklyLoss, 2) : "Disabled");
   Print("Max Total Heat: ", MaxTotalHeat > 0 ? DoubleToString(MaxTotalHeat, 2) : "Disabled");
   Print("Max Drawdown: ", MaxDrawdownPercent > 0 ? DoubleToString(MaxDrawdownPercent, 1) + "%" : "Disabled");
   Print("==========================================");

   // Set timer
   EventSetTimer(UpdateIntervalSeconds);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Clear global variable
   if(SignalOtherEAs)
   {
      GlobalVariableDel(g_globalVarName);
   }

   DeleteDashboard();

   ArrayFree(g_magicNumbers);
   ArrayFree(g_symbols);
   ArrayFree(g_eas);

   Print("Portfolio Manager removed");
}

//+------------------------------------------------------------------+
//| Timer function                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Check for new day/week
   ResetLimitsIfNeeded();

   // Update stats
   UpdatePortfolioStats();

   // Check limits
   CheckLimits();

   // Update dashboard
   if(ShowDashboard)
      UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Tick function (backup for timer)                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   // Timer handles most updates, but we can use tick for critical checks
   static datetime lastCheck = 0;
   if(TimeCurrent() - lastCheck >= UpdateIntervalSeconds)
   {
      lastCheck = TimeCurrent();
      // Timer will handle the update
   }
}

//+------------------------------------------------------------------+
//| Parse magic number list from input                                |
//+------------------------------------------------------------------+
void ParseMagicNumbers()
{
   if(TrackAllPositions || MagicNumberList == "")
   {
      g_magicCount = 0;
      return;
   }

   string parts[];
   int count = StringSplit(MagicNumberList, ',', parts);

   ArrayResize(g_magicNumbers, count);
   g_magicCount = 0;

   for(int i = 0; i < count; i++)
   {
      string trimmed = parts[i];
      StringTrimLeft(trimmed);
      StringTrimRight(trimmed);
      if(trimmed != "")
      {
         g_magicNumbers[g_magicCount] = (ulong)StringToInteger(trimmed);
         g_magicCount++;
      }
   }

   ArrayResize(g_magicNumbers, g_magicCount);

   if(LogDiagnostics)
   {
      Print("Parsed ", g_magicCount, " magic numbers");
      for(int i = 0; i < g_magicCount; i++)
      {
         Print("  Magic[", i, "]: ", g_magicNumbers[i]);
      }
   }
}

//+------------------------------------------------------------------+
//| Check if a magic number should be tracked                        |
//+------------------------------------------------------------------+
bool ShouldTrackMagic(ulong magic)
{
   if(TrackAllPositions)
      return true;

   if(g_magicCount == 0)
      return true;  // Empty list = track all

   for(int i = 0; i < g_magicCount; i++)
   {
      if(g_magicNumbers[i] == magic)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Update portfolio statistics                                       |
//+------------------------------------------------------------------+
void UpdatePortfolioStats()
{
   // Reset stats
   g_portfolio.totalPositions = 0;
   g_portfolio.totalHeat = 0;
   g_portfolio.totalFloatingPL = 0;
   g_portfolio.totalVolume = 0;
   g_portfolio.totalMarginUsed = 0;

   // Reset breakdowns
   ArrayResize(g_symbols, 0);
   g_symbolCount = 0;
   ArrayResize(g_eas, 0);
   g_eaCount = 0;

   // Scan all positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;

      ulong magic = m_position.Magic();

      if(!ShouldTrackMagic(magic))
         continue;

      string symbol = m_position.Symbol();
      double volume = m_position.Volume();
      double floatingPL = m_position.Profit() + m_position.Swap() + m_position.Commission();
      double entryPrice = m_position.PriceOpen();
      double sl = m_position.StopLoss();
      double margin = 0;

      // Calculate margin used
      if(!OrderCalcMargin(m_position.PositionType() == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                      symbol, volume, entryPrice, margin))
      {
         margin = 0;  // Default if calculation fails
      }

      // Calculate heat (potential loss to SL)
      double heat = 0;
      if(sl > 0)
      {
         double lossToSL = 0;
         ENUM_ORDER_TYPE orderType = m_position.PositionType() == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         if(OrderCalcProfit(orderType, symbol, volume, entryPrice, sl, lossToSL))
         {
            heat = MathAbs(lossToSL);
         }
      }
      else
      {
         // No SL set - estimate based on current loss or fixed percentage
         heat = MathAbs(floatingPL) + volume * 100;  // Rough estimate
      }

      // Update portfolio totals
      g_portfolio.totalPositions++;
      g_portfolio.totalHeat += heat;
      g_portfolio.totalFloatingPL += floatingPL;
      g_portfolio.totalVolume += volume;
      g_portfolio.totalMarginUsed += margin;

      // Update symbol breakdown
      UpdateSymbolBreakdown(symbol, volume, floatingPL, heat);

      // Update EA breakdown
      UpdateEABreakdown(magic, volume, floatingPL, heat);
   }

   // Calculate P/L from closed trades
   CalculatePeriodPL();

   g_portfolio.lastUpdate = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Update symbol breakdown                                           |
//+------------------------------------------------------------------+
void UpdateSymbolBreakdown(string symbol, double volume, double floatingPL, double heat)
{
   // Find existing symbol
   for(int i = 0; i < g_symbolCount; i++)
   {
      if(g_symbols[i].symbol == symbol)
      {
         g_symbols[i].count++;
         g_symbols[i].volume += volume;
         g_symbols[i].floatingPL += floatingPL;
         g_symbols[i].heat += heat;
         return;
      }
   }

   // Add new symbol
   ArrayResize(g_symbols, g_symbolCount + 1);
   g_symbols[g_symbolCount].symbol = symbol;
   g_symbols[g_symbolCount].count = 1;
   g_symbols[g_symbolCount].volume = volume;
   g_symbols[g_symbolCount].floatingPL = floatingPL;
   g_symbols[g_symbolCount].heat = heat;
   g_symbolCount++;
}

//+------------------------------------------------------------------+
//| Update EA breakdown                                               |
//+------------------------------------------------------------------+
void UpdateEABreakdown(ulong magic, double volume, double floatingPL, double heat)
{
   // Find existing EA
   for(int i = 0; i < g_eaCount; i++)
   {
      if(g_eas[i].magic == magic)
      {
         g_eas[i].count++;
         g_eas[i].volume += volume;
         g_eas[i].floatingPL += floatingPL;
         g_eas[i].heat += heat;
         return;
      }
   }

   // Add new EA
   ArrayResize(g_eas, g_eaCount + 1);
   g_eas[g_eaCount].magic = magic;
   g_eas[g_eaCount].count = 1;
   g_eas[g_eaCount].volume = volume;
   g_eas[g_eaCount].floatingPL = floatingPL;
   g_eas[g_eaCount].heat = heat;
   g_eaCount++;
}

//+------------------------------------------------------------------+
//| Calculate P/L for today and this week                            |
//+------------------------------------------------------------------+
void CalculatePeriodPL()
{
   g_portfolio.todayPL = g_portfolio.totalFloatingPL;
   g_portfolio.weekPL = g_portfolio.totalFloatingPL;

   datetime startOfDay = GetStartOfDay(TimeCurrent());
   datetime startOfWeek = GetStartOfWeek(TimeCurrent());

   // Select history
   if(!HistorySelect(startOfWeek, TimeCurrent()))
      return;

   int totalDeals = HistoryDealsTotal();

   for(int i = 0; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      ulong magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);

      if(!ShouldTrackMagic(magic))
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

      // Add to week P/L
      g_portfolio.weekPL += totalPL;

      // Add to today P/L if from today
      if(dealTime >= startOfDay)
      {
         g_portfolio.todayPL += totalPL;
      }
   }
}

//+------------------------------------------------------------------+
//| Check all risk limits                                             |
//+------------------------------------------------------------------+
void CheckLimits()
{
   bool shouldBlock = false;
   string blockReason = "";

   // Check daily loss limit
   if(MaxDailyLoss > 0 && !g_dailyLimitHit)
   {
      double dailyLossPercent = (MathAbs(g_portfolio.todayPL) / MaxDailyLoss) * 100.0;

      if(g_portfolio.todayPL <= -MaxDailyLoss)
      {
         g_dailyLimitHit = true;
         shouldBlock = true;
         blockReason = "Daily loss limit hit";

         SendAlert("DAILY LOSS LIMIT HIT! P/L: " + DoubleToString(g_portfolio.todayPL, 2));

         if(CloseOnDailyLimit)
         {
            Print("Closing all positions due to daily loss limit");
            CloseAllTrackedPositions();
         }
      }
      else if(dailyLossPercent >= AlertThresholdPercent && g_portfolio.todayPL < 0)
      {
         SendAlert("WARNING: Daily loss at " + DoubleToString(dailyLossPercent, 1) + "% of limit");
      }
   }

   // Check weekly loss limit
   if(MaxWeeklyLoss > 0 && !g_weeklyLimitHit)
   {
      double weeklyLossPercent = (MathAbs(g_portfolio.weekPL) / MaxWeeklyLoss) * 100.0;

      if(g_portfolio.weekPL <= -MaxWeeklyLoss)
      {
         g_weeklyLimitHit = true;
         shouldBlock = true;
         blockReason = "Weekly loss limit hit";

         SendAlert("WEEKLY LOSS LIMIT HIT! P/L: " + DoubleToString(g_portfolio.weekPL, 2));

         if(CloseOnWeeklyLimit)
         {
            Print("Closing all positions due to weekly loss limit");
            CloseAllTrackedPositions();
         }
      }
      else if(weeklyLossPercent >= AlertThresholdPercent && g_portfolio.weekPL < 0)
      {
         SendAlert("WARNING: Weekly loss at " + DoubleToString(weeklyLossPercent, 1) + "% of limit");
      }
   }

   // Check heat limit
   if(MaxTotalHeat > 0)
   {
      double heatPercent = (g_portfolio.totalHeat / MaxTotalHeat) * 100.0;

      if(g_portfolio.totalHeat >= MaxTotalHeat)
      {
         if(!g_heatLimitHit)
         {
            g_heatLimitHit = true;
            shouldBlock = true;
            blockReason = "Heat limit hit";

            SendAlert("HEAT LIMIT HIT! Total heat: " + DoubleToString(g_portfolio.totalHeat, 2));
         }
      }
      else
      {
         g_heatLimitHit = false;

         if(heatPercent >= AlertThresholdPercent)
         {
            SendAlert("WARNING: Portfolio heat at " + DoubleToString(heatPercent, 1) + "% of limit");
         }
      }
   }

   // Check drawdown limit
   if(MaxDrawdownPercent > 0)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double drawdownPercent = ((balance - equity) / balance) * 100.0;

      if(drawdownPercent >= MaxDrawdownPercent)
      {
         if(!g_drawdownLimitHit)
         {
            g_drawdownLimitHit = true;
            shouldBlock = true;
            blockReason = "Drawdown limit hit";

            SendAlert("DRAWDOWN LIMIT HIT! Drawdown: " + DoubleToString(drawdownPercent, 2) + "%");

            if(CloseOnDrawdownLimit)
            {
               Print("Closing all positions due to drawdown limit");
               CloseAllTrackedPositions();
            }
         }
      }
      else
      {
         g_drawdownLimitHit = false;
      }
   }

   // Update global variable to signal other EAs
   if(SignalOtherEAs)
   {
      double currentSignal = GlobalVariableGet(g_globalVarName);

      if(shouldBlock && currentSignal == 0)
      {
         GlobalVariableSet(g_globalVarName, 1);  // 1 = trading blocked
         Print("Trading BLOCKED for all EAs. Reason: ", blockReason);
      }
      else if(!g_dailyLimitHit && !g_weeklyLimitHit && !g_heatLimitHit && !g_drawdownLimitHit && currentSignal == 1)
      {
         GlobalVariableSet(g_globalVarName, 0);  // 0 = trading allowed
         Print("Trading UNBLOCKED for all EAs");
      }
   }
}

//+------------------------------------------------------------------+
//| Close all tracked positions                                       |
//+------------------------------------------------------------------+
void CloseAllTrackedPositions()
{
   int closed = 0;
   int failed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      ulong magic = PositionGetInteger(POSITION_MAGIC);

      if(!ShouldTrackMagic(magic))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);

      // Set filling mode for this symbol
      ENUM_ORDER_TYPE_FILLING fillMode = GetFillingModeForSymbol(symbol);
      m_trade.SetTypeFilling(fillMode);

      if(m_trade.PositionClose(ticket))
      {
         closed++;
         Print("Closed position #", ticket, " on ", symbol);
      }
      else
      {
         failed++;
         Print("Failed to close position #", ticket, " - Error: ", GetLastError());
      }
   }

   Print("Portfolio Manager: Closed ", closed, " positions, ", failed, " failed");
}

//+------------------------------------------------------------------+
//| Send alert/notification                                           |
//+------------------------------------------------------------------+
void SendAlert(string message)
{
   // Throttle alerts (max 1 per minute)
   if(TimeCurrent() - g_lastAlertTime < 60)
      return;

   g_lastAlertTime = TimeCurrent();

   string fullMessage = "Portfolio Manager: " + message;

   if(EnableAlerts)
   {
      Alert(fullMessage);
   }

   if(SendPushNotification)
   {
      SendNotification(fullMessage);
   }

   if(SendEmail)
   {
      SendMail("Portfolio Manager Alert", fullMessage);
   }

   Print("ALERT: ", message);
}

//+------------------------------------------------------------------+
//| Reset limits if new day/week started                              |
//+------------------------------------------------------------------+
void ResetLimitsIfNeeded()
{
   datetime today = GetStartOfDay(TimeCurrent());
   datetime thisWeek = GetStartOfWeek(TimeCurrent());

   // Check for new day
   if(today != g_currentDay)
   {
      g_currentDay = today;
      g_dailyLimitHit = false;
      Print("New day started - Daily limit reset");

      // Update global signal
      if(SignalOtherEAs && !g_weeklyLimitHit && !g_drawdownLimitHit)
      {
         GlobalVariableSet(g_globalVarName, 0);
      }
   }

   // Check for new week
   if(thisWeek != g_currentWeek)
   {
      g_currentWeek = thisWeek;
      g_weeklyLimitHit = false;
      Print("New week started - Weekly limit reset");

      // Update global signal
      if(SignalOtherEAs && !g_dailyLimitHit && !g_drawdownLimitHit)
      {
         GlobalVariableSet(g_globalVarName, 0);
      }
   }
}

//+------------------------------------------------------------------+
//| Get start of day                                                  |
//+------------------------------------------------------------------+
datetime GetStartOfDay(datetime time)
{
   MqlDateTime dt;
   TimeToStruct(time, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Get start of week (Monday)                                        |
//+------------------------------------------------------------------+
datetime GetStartOfWeek(datetime time)
{
   MqlDateTime dt;
   TimeToStruct(time, dt);

   // Calculate days since Monday (Monday = 1)
   int daysSinceMonday = dt.day_of_week - 1;
   if(daysSinceMonday < 0) daysSinceMonday = 6;  // Sunday

   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;

   return StructToTime(dt) - daysSinceMonday * 86400;
}

//+------------------------------------------------------------------+
//| Get filling mode for current symbol                               |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   return GetFillingModeForSymbol(_Symbol);
}

//+------------------------------------------------------------------+
//| Get filling mode for specific symbol                              |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingModeForSymbol(string symbol)
{
   uint fillingModes = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((fillingModes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;

   if((fillingModes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Create dashboard                                                  |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   int panelWidth = DashboardWidth;
   int panelHeight = 220;  // Will be dynamic based on content

   // Background
   CreateRectLabel(g_prefix + "BG", DashboardX, DashboardY, panelWidth, panelHeight, DashColorBG, DashColorBorder);

   // Title
   CreateLabel(g_prefix + "Title", DashboardX + 10, DashboardY + 5, "PORTFOLIO MANAGER", DashColorTitle, 10, true);

   // Status indicator
   CreateLabel(g_prefix + "Status", DashboardX + panelWidth - 80, DashboardY + 5, "ACTIVE", clrLime, 9, true);

   // Separator
   CreateLine(g_prefix + "Sep1", DashboardX + 10, DashboardY + 24, DashboardX + panelWidth - 10, DashboardY + 24, DashColorBorder);

   int y = DashboardY + 30;
   int col1 = DashboardX + 10;
   int col2 = DashboardX + 120;
   int col3 = DashboardX + 220;
   int col4 = DashboardX + 320;

   // === Row 1: Position Summary ===
   CreateLabel(g_prefix + "LblPositions", col1, y, "Positions:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValPositions", col2, y, "0", DashColorText, 8, false);

   CreateLabel(g_prefix + "LblVolume", col3, y, "Volume:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValVolume", col4, y, "0.00", DashColorText, 8, false);

   // === Row 2: Floating P/L ===
   y += 16;
   CreateLabel(g_prefix + "LblFloating", col1, y, "Floating P/L:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValFloating", col2, y, "0.00", DashColorText, 8, true);

   CreateLabel(g_prefix + "LblMargin", col3, y, "Margin:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValMargin", col4, y, "0.00", DashColorText, 8, false);

   // === Row 3: Today P/L ===
   y += 16;
   CreateLabel(g_prefix + "LblToday", col1, y, "Today P/L:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValToday", col2, y, "0.00", DashColorText, 8, true);

   CreateLabel(g_prefix + "LblTodayLimit", col3, y, "Limit:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValTodayLimit", col4, y, "0.00", DashColorText, 8, false);

   // === Row 4: Week P/L ===
   y += 16;
   CreateLabel(g_prefix + "LblWeek", col1, y, "Week P/L:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValWeek", col2, y, "0.00", DashColorText, 8, true);

   CreateLabel(g_prefix + "LblWeekLimit", col3, y, "Limit:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValWeekLimit", col4, y, "0.00", DashColorText, 8, false);

   // === Separator ===
   y += 20;
   CreateLine(g_prefix + "Sep2", DashboardX + 10, y, DashboardX + panelWidth - 10, y, DashColorBorder);

   // === Row 5: Heat ===
   y += 6;
   CreateLabel(g_prefix + "LblHeat", col1, y, "Total Heat:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValHeat", col2, y, "0.00", DashColorText, 8, true);

   CreateLabel(g_prefix + "LblHeatLimit", col3, y, "Limit:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValHeatLimit", col4, y, "0.00", DashColorText, 8, false);

   // === Row 6: Heat Bar ===
   y += 18;
   CreateRectLabel(g_prefix + "HeatBarBG", col1, y, panelWidth - 20, 12, C'40,40,40', DashColorBorder);
   CreateRectLabel(g_prefix + "HeatBar", col1 + 1, y + 1, 1, 10, clrLime, clrLime);

   // === Separator ===
   y += 18;
   CreateLine(g_prefix + "Sep3", DashboardX + 10, y, DashboardX + panelWidth - 10, y, DashColorBorder);

   // === Row 7: Drawdown ===
   y += 6;
   CreateLabel(g_prefix + "LblDrawdown", col1, y, "Drawdown:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValDrawdown", col2, y, "0.00%", DashColorText, 8, false);

   CreateLabel(g_prefix + "LblDDLimit", col3, y, "Limit:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValDDLimit", col4, y, "0.00%", DashColorText, 8, false);

   // === Row 8: Account Info ===
   y += 16;
   CreateLabel(g_prefix + "LblBalance", col1, y, "Balance:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValBalance", col2, y, "0.00", DashColorText, 8, false);

   CreateLabel(g_prefix + "LblEquity", col3, y, "Equity:", DashColorLabel, 8, false);
   CreateLabel(g_prefix + "ValEquity", col4, y, "0.00", DashColorText, 8, false);

   // === Separator ===
   y += 20;
   CreateLine(g_prefix + "Sep4", DashboardX + 10, y, DashboardX + panelWidth - 10, y, DashColorBorder);

   // === EA Breakdown Header ===
   y += 6;
   CreateLabel(g_prefix + "LblBreakdown", col1, y, "EA Breakdown:", DashColorTitle, 8, true);

   // === EA List (up to 5 EAs) ===
   for(int i = 0; i < 5; i++)
   {
      y += 14;
      CreateLabel(g_prefix + "EA" + IntegerToString(i), col1, y, "", DashColorLabel, 7, false);
   }

   // Update panel height
   y += 10;
   ObjectSetInteger(0, g_prefix + "BG", OBJPROP_YSIZE, y - DashboardY);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update dashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!ShowDashboard) return;

   // Update status
   string status = "ACTIVE";
   color statusColor = clrLime;

   if(g_dailyLimitHit || g_weeklyLimitHit || g_drawdownLimitHit)
   {
      status = "BLOCKED";
      statusColor = DashColorLoss;
   }
   else if(g_heatLimitHit)
   {
      status = "HEAT LIMIT";
      statusColor = DashColorWarning;
   }

   ObjectSetString(0, g_prefix + "Status", OBJPROP_TEXT, status);
   ObjectSetInteger(0, g_prefix + "Status", OBJPROP_COLOR, statusColor);

   // Position summary
   ObjectSetString(0, g_prefix + "ValPositions", OBJPROP_TEXT, IntegerToString(g_portfolio.totalPositions));
   ObjectSetString(0, g_prefix + "ValVolume", OBJPROP_TEXT, DoubleToString(g_portfolio.totalVolume, 2));

   // Floating P/L
   ObjectSetString(0, g_prefix + "ValFloating", OBJPROP_TEXT, FormatPL(g_portfolio.totalFloatingPL));
   ObjectSetInteger(0, g_prefix + "ValFloating", OBJPROP_COLOR, g_portfolio.totalFloatingPL >= 0 ? DashColorProfit : DashColorLoss);

   // Margin
   ObjectSetString(0, g_prefix + "ValMargin", OBJPROP_TEXT, DoubleToString(g_portfolio.totalMarginUsed, 2));

   // Today P/L
   ObjectSetString(0, g_prefix + "ValToday", OBJPROP_TEXT, FormatPL(g_portfolio.todayPL));
   ObjectSetInteger(0, g_prefix + "ValToday", OBJPROP_COLOR, g_portfolio.todayPL >= 0 ? DashColorProfit : DashColorLoss);
   ObjectSetString(0, g_prefix + "ValTodayLimit", OBJPROP_TEXT, MaxDailyLoss > 0 ? DoubleToString(MaxDailyLoss, 2) : "---");

   // Week P/L
   ObjectSetString(0, g_prefix + "ValWeek", OBJPROP_TEXT, FormatPL(g_portfolio.weekPL));
   ObjectSetInteger(0, g_prefix + "ValWeek", OBJPROP_COLOR, g_portfolio.weekPL >= 0 ? DashColorProfit : DashColorLoss);
   ObjectSetString(0, g_prefix + "ValWeekLimit", OBJPROP_TEXT, MaxWeeklyLoss > 0 ? DoubleToString(MaxWeeklyLoss, 2) : "---");

   // Heat
   ObjectSetString(0, g_prefix + "ValHeat", OBJPROP_TEXT, DoubleToString(g_portfolio.totalHeat, 2));
   color heatColor = DashColorProfit;
   if(MaxTotalHeat > 0)
   {
      double heatPercent = (g_portfolio.totalHeat / MaxTotalHeat) * 100.0;
      if(heatPercent >= 100) heatColor = DashColorLoss;
      else if(heatPercent >= AlertThresholdPercent) heatColor = DashColorWarning;
   }
   ObjectSetInteger(0, g_prefix + "ValHeat", OBJPROP_COLOR, heatColor);
   ObjectSetString(0, g_prefix + "ValHeatLimit", OBJPROP_TEXT, MaxTotalHeat > 0 ? DoubleToString(MaxTotalHeat, 2) : "---");

   // Heat bar
   if(MaxTotalHeat > 0)
   {
      double heatPercent = MathMin((g_portfolio.totalHeat / MaxTotalHeat) * 100.0, 100.0);
      int barWidth = (int)((DashboardWidth - 22) * heatPercent / 100.0);
      if(barWidth < 1) barWidth = 1;

      ObjectSetInteger(0, g_prefix + "HeatBar", OBJPROP_XSIZE, barWidth);
      ObjectSetInteger(0, g_prefix + "HeatBar", OBJPROP_BGCOLOR, heatColor);
      ObjectSetInteger(0, g_prefix + "HeatBar", OBJPROP_BORDER_COLOR, heatColor);
   }

   // Drawdown
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPercent = balance > 0 ? ((balance - equity) / balance) * 100.0 : 0;

   ObjectSetString(0, g_prefix + "ValDrawdown", OBJPROP_TEXT, DoubleToString(drawdownPercent, 2) + "%");
   color ddColor = DashColorProfit;
   if(MaxDrawdownPercent > 0)
   {
      if(drawdownPercent >= MaxDrawdownPercent) ddColor = DashColorLoss;
      else if(drawdownPercent >= MaxDrawdownPercent * AlertThresholdPercent / 100.0) ddColor = DashColorWarning;
   }
   ObjectSetInteger(0, g_prefix + "ValDrawdown", OBJPROP_COLOR, ddColor);
   ObjectSetString(0, g_prefix + "ValDDLimit", OBJPROP_TEXT, MaxDrawdownPercent > 0 ? DoubleToString(MaxDrawdownPercent, 1) + "%" : "---");

   // Account info
   ObjectSetString(0, g_prefix + "ValBalance", OBJPROP_TEXT, DoubleToString(balance, 2));
   ObjectSetString(0, g_prefix + "ValEquity", OBJPROP_TEXT, DoubleToString(equity, 2));

   // EA Breakdown
   for(int i = 0; i < 5; i++)
   {
      string labelName = g_prefix + "EA" + IntegerToString(i);

      if(i < g_eaCount)
      {
         string eaText = StringFormat("Magic %d: %d pos, %.2f lots, P/L: %s",
                                       g_eas[i].magic,
                                       g_eas[i].count,
                                       g_eas[i].volume,
                                       FormatPL(g_eas[i].floatingPL));
         ObjectSetString(0, labelName, OBJPROP_TEXT, eaText);
         ObjectSetInteger(0, labelName, OBJPROP_COLOR, g_eas[i].floatingPL >= 0 ? DashColorProfit : DashColorLoss);
      }
      else
      {
         ObjectSetString(0, labelName, OBJPROP_TEXT, "");
      }
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Format P/L with sign                                              |
//+------------------------------------------------------------------+
string FormatPL(double value)
{
   string sign = value >= 0 ? "+" : "";
   return sign + DoubleToString(value, 2);
}

//+------------------------------------------------------------------+
//| Delete dashboard                                                  |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Create rectangle label                                            |
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
//| Create label                                                      |
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
//| Create line                                                       |
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
