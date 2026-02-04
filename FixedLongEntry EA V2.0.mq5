//+------------------------------------------------------------------+
//|                                       FixedLongEntry_EA_V2.0.mq5 |
//|                              Fixed Long Entry EA with Risk Cap   |
//|                                                                  |
//| V2.0 Changes:                                                    |
//|   - Added spread filter to prevent bad entries during news       |
//|   - Added lastEntryDay persistence (checks existing positions)   |
//|   - Added max daily loss protection                              |
//|   - Reduced timer frequency (5 sec instead of 1 sec)             |
//|   - Added day-of-week trading filter                             |
//|   - Added max spread input parameter                             |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

input group "==== Time Settings ===="
input int      EntryHour = 9;              // Entry Hour (0-23)
input int      EntryMinute = 0;            // Entry Minute (0-59)
input int      EntryWindowMinutes = 5;     // Entry Window (minutes after entry time)

input group "==== Day Filters ===="
input bool     TradeMonday = true;         // Trade on Monday
input bool     TradeTuesday = true;        // Trade on Tuesday
input bool     TradeWednesday = true;      // Trade on Wednesday
input bool     TradeThursday = true;       // Trade on Thursday
input bool     TradeFriday = true;         // Trade on Friday

input group "==== Risk Management ===="
input double   RiskAmount = 100.0;         // Risk Amount in Account Currency
input double   StopLossPercent = 1.0;      // Stop Loss Percentage of Market Price
input double   TakeProfitPercent = 2.0;    // Take Profit Percentage of Market Price
input double   MaxDailyLoss = 0.0;         // Max Daily Loss (0 = disabled)

input group "==== Portfolio Manager Integration ===="
input bool     UsePortfolioManager = true;  // Respect Portfolio Manager Signals
input string   PortfolioSignalName = "PORTFOLIO_TRADING_BLOCKED";  // Global Variable Name

input group "==== Spread Filter ===="
input bool     UseSpreadFilter = true;     // Enable Spread Filter
input double   MaxSpreadPercent = 0.0;     // Max Spread (% of price, 0 = auto: 10% of SL)

input group "==== Break-Even Settings ===="
input bool     UseBreakEven = true;        // Enable Break-Even
input double   BreakEvenTriggerPercent = 0.5;  // BE Trigger (% profit to activate)
input double   BreakEvenBufferPercent = 0.05;  // BE Buffer (% profit to lock in)

input group "==== Trailing Stop Settings ===="
input bool     UseTrailingStop = true;     // Enable Trailing Stop
input double   TrailingActivationPercent = 1.0;  // Trailing Activation (% profit)
input double   TrailingDistancePercent = 0.5;    // Trailing Distance (% from price)

input group "==== Trading Settings ===="
input int      MaxPositions = 10;          // Maximum Open Positions
input ulong    MagicNumber = 123456;       // Magic Number
input string   TradeComment = "FixedLong"; // Trade Comment
input int      Slippage = 10;              // Slippage in Points
input bool     LogDiagnostics = true;      // Extended Diagnostics Logging

input group "==== Dashboard Settings ===="
input bool     ShowDashboard = true;       // Show Performance Dashboard
input int      DashboardX = 10;            // Dashboard X Position
input int      DashboardY = 20;            // Dashboard Y Position
input color    DashColorBG = C'25,25,25';  // Background Color
input color    DashColorBorder = C'60,60,60';  // Border Color
input color    DashColorText = clrWhite;   // Text Color
input color    DashColorLabel = clrGray;   // Label Color
input color    DashColorProfit = clrLime;  // Profit Color
input color    DashColorLoss = clrRed;     // Loss Color

CTrade m_trade;
CPositionInfo m_position;
CSymbolInfo m_symbol;

datetime lastEntryDay = 0;

// Arrays to track break-even status per position ticket
ulong    g_beAppliedTickets[];

// Dashboard prefix
string g_prefix = "LongEA_";

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

// Calculated spread limit
double g_maxSpreadPercent;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    if(!m_symbol.Name(_Symbol))
    {
        Print("Failed to initialize symbol");
        return INIT_FAILED;
    }

    m_trade.SetExpertMagicNumber(MagicNumber);
    m_trade.SetDeviationInPoints(Slippage);

    // Auto-detect and set the correct filling mode
    ENUM_ORDER_TYPE_FILLING fillingMode = GetFillingMode();
    m_trade.SetTypeFilling(fillingMode);

    // Validate inputs
    if(RiskAmount <= 0)
    {
        Print("Risk Amount must be greater than 0");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(StopLossPercent <= 0)
    {
        Print("Stop Loss Percentage must be greater than 0");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(TakeProfitPercent <= 0)
    {
        Print("Take Profit Percentage must be greater than 0");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(EntryHour < 0 || EntryHour > 23)
    {
        Print("Entry Hour must be between 0 and 23");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(EntryMinute < 0 || EntryMinute > 59)
    {
        Print("Entry Minute must be between 0 and 59");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(MaxPositions <= 0)
    {
        Print("Maximum Positions must be greater than 0");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(EntryWindowMinutes < 1 || EntryWindowMinutes > 60)
    {
        Print("Entry Window must be between 1 and 60 minutes");
        return INIT_PARAMETERS_INCORRECT;
    }

    // Validate break-even settings
    if(UseBreakEven)
    {
        if(BreakEvenTriggerPercent <= 0)
        {
            Print("Break-Even Trigger must be greater than 0");
            return INIT_PARAMETERS_INCORRECT;
        }
        if(BreakEvenBufferPercent < 0)
        {
            Print("Break-Even Buffer cannot be negative");
            return INIT_PARAMETERS_INCORRECT;
        }
        if(BreakEvenBufferPercent >= BreakEvenTriggerPercent)
        {
            Print("Break-Even Buffer must be less than Trigger");
            return INIT_PARAMETERS_INCORRECT;
        }
    }

    // Validate trailing stop settings
    if(UseTrailingStop)
    {
        if(TrailingActivationPercent <= 0)
        {
            Print("Trailing Activation must be greater than 0");
            return INIT_PARAMETERS_INCORRECT;
        }
        if(TrailingDistancePercent <= 0)
        {
            Print("Trailing Distance must be greater than 0");
            return INIT_PARAMETERS_INCORRECT;
        }
        if(TrailingDistancePercent >= TrailingActivationPercent)
        {
            Print("Trailing Distance should be less than Activation for logical behavior");
        }
    }

    // Calculate spread limit (auto or manual)
    if(MaxSpreadPercent > 0)
    {
        g_maxSpreadPercent = MaxSpreadPercent;
    }
    else
    {
        // Auto: 10% of stop loss
        g_maxSpreadPercent = StopLossPercent * 0.1;
    }

    // Initialize BE tracking array
    ArrayResize(g_beAppliedTickets, 0);

    // Initialize performance stats
    ZeroMemory(g_stats);
    CalculateHistoricalStats();

    // Check for existing position from today (persistence across restarts)
    CheckExistingPositionsToday();

    // Create dashboard
    if(ShowDashboard)
        CreateDashboard();

    Print("===== EA V2.0 Initialized Successfully =====");
    Print("Entry Time: ", StringFormat("%02d:%02d", EntryHour, EntryMinute),
          " (Window: ", EntryWindowMinutes, " min)");
    Print("Trading Days: ", GetTradingDaysString());
    Print("Max Positions: ", MaxPositions);
    Print("Risk Amount: ", RiskAmount);
    Print("Stop Loss: ", StopLossPercent, "%");
    Print("Take Profit: ", TakeProfitPercent, "%");
    Print("Max Daily Loss: ", MaxDailyLoss > 0 ? DoubleToString(MaxDailyLoss, 2) : "Disabled");
    Print("Spread Filter: ", UseSpreadFilter ? StringFormat("ON (Max: %.3f%%)", g_maxSpreadPercent) : "OFF");
    Print("Break-Even: ", UseBreakEven ? StringFormat("ON (Trigger: %.2f%%, Buffer: %.2f%%)",
          BreakEvenTriggerPercent, BreakEvenBufferPercent) : "OFF");
    Print("Trailing Stop: ", UseTrailingStop ? StringFormat("ON (Activation: %.2f%%, Distance: %.2f%%)",
          TrailingActivationPercent, TrailingDistancePercent) : "OFF");
    Print("Filling Mode: ", EnumToString(fillingMode));
    Print("Diagnostics Logging: ", LogDiagnostics ? "ON" : "OFF");
    Print("============================================");

    // Set timer for dashboard updates (reduced frequency)
    EventSetTimer(5);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Get string of trading days for logging                           |
//+------------------------------------------------------------------+
string GetTradingDaysString()
{
    string days = "";
    if(TradeMonday) days += "Mon ";
    if(TradeTuesday) days += "Tue ";
    if(TradeWednesday) days += "Wed ";
    if(TradeThursday) days += "Thu ";
    if(TradeFriday) days += "Fri";
    if(days == "") days = "NONE (Trading Disabled!)";
    return days;
}

//+------------------------------------------------------------------+
//| Check for existing positions opened today                        |
//+------------------------------------------------------------------+
void CheckExistingPositionsToday()
{
    datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(m_position.SelectByIndex(i))
        {
            if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
            {
                datetime posTime = (datetime)m_position.Time();
                if(posTime >= today)
                {
                    lastEntryDay = today;
                    Print("Existing position found from today (Ticket #", m_position.Ticket(),
                          ") - Entry already recorded for today");
                    return;
                }
            }
        }
    }

    // Also check deal history for positions that were already closed today
    if(HistorySelect(today, TimeCurrent()))
    {
        int totalDeals = HistoryDealsTotal();
        for(int i = 0; i < totalDeals; i++)
        {
            ulong ticket = HistoryDealGetTicket(i);
            if(ticket == 0) continue;

            ulong dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
            string dealSymbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);

            if(dealMagic == MagicNumber && dealSymbol == _Symbol && entry == DEAL_ENTRY_IN)
            {
                lastEntryDay = today;
                Print("Found entry deal from today in history - Entry already recorded for today");
                return;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    ArrayFree(g_beAppliedTickets);
    DeleteDashboard();
    Print("EA V2.0 Deinitialized");
}

//+------------------------------------------------------------------+
//| Timer function for dashboard updates                             |
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
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!m_symbol.RefreshRates())
        return;

    datetime currentTime = TimeCurrent();

    // Manage existing positions (BE and Trailing)
    if(UseBreakEven || UseTrailingStop)
    {
        ManageOpenPositions();
    }

    // Check for new entry
    if(ShouldEnterTrade(currentTime))
    {
        int currentPositions = CountOpenPositions();
        if(currentPositions < MaxPositions)
        {
            OpenLongPosition();
            lastEntryDay = StringToTime(TimeToString(currentTime, TIME_DATE));
            Print("Position opened. Total open positions: ", currentPositions + 1, "/", MaxPositions);
        }
        else
        {
            datetime todayDate = StringToTime(TimeToString(currentTime, TIME_DATE));
            if(lastEntryDay != todayDate)
            {
                Print("Maximum positions reached: ", currentPositions, "/", MaxPositions);
                lastEntryDay = todayDate;
            }
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
    int panelWidth = 340;
    int panelHeight = 95;

    // Background
    CreateRectangle(g_prefix + "BG", DashboardX, DashboardY, panelWidth, panelHeight, DashColorBG, DashColorBorder);

    // Title with symbol
    string title = "LongEA - " + _Symbol;
    CreateLabel(g_prefix + "Title", DashboardX + 8, DashboardY + 5, title, DashColorText, 9, true);

    // Separator
    CreateLine(g_prefix + "Sep1", DashboardX + 8, DashboardY + 22, DashboardX + panelWidth - 8, DashboardY + 22, DashColorBorder);

    // === ROW 1: Trade Stats ===
    int y = DashboardY + 28;
    int col1 = DashboardX + 8;
    int col2 = DashboardX + 90;
    int col3 = DashboardX + 175;
    int col4 = DashboardX + 260;

    CreateLabel(g_prefix + "LblTrades", col1, y, "Trades:", DashColorLabel, 8, false);
    CreateLabel(g_prefix + "ValTrades", col1 + 42, y, "0", DashColorText, 8, false);

    CreateLabel(g_prefix + "LblWins", col2, y, "W:", DashColorLabel, 8, false);
    CreateLabel(g_prefix + "ValWins", col2 + 18, y, "0", DashColorProfit, 8, false);

    CreateLabel(g_prefix + "LblLosses", col2 + 45, y, "L:", DashColorLabel, 8, false);
    CreateLabel(g_prefix + "ValLosses", col2 + 58, y, "0", DashColorLoss, 8, false);

    CreateLabel(g_prefix + "LblWinRate", col3, y, "WinRate:", DashColorLabel, 8, false);
    CreateLabel(g_prefix + "ValWinRate", col3 + 50, y, "0%", DashColorText, 8, false);

    CreateLabel(g_prefix + "LblPositions", col4, y, "Open:", DashColorLabel, 8, false);
    CreateLabel(g_prefix + "ValPositions", col4 + 35, y, "0", DashColorText, 8, false);

    // === ROW 2: P/L Stats ===
    y += 16;

    CreateLabel(g_prefix + "LblNetPL", col1, y, "Net P/L:", DashColorLabel, 8, false);
    CreateLabel(g_prefix + "ValNetPL", col1 + 45, y, "0.00", DashColorText, 8, true);

    CreateLabel(g_prefix + "LblToday", col2 + 30, y, "Today:", DashColorLabel, 8, false);
    CreateLabel(g_prefix + "ValToday", col2 + 70, y, "0.00", DashColorText, 8, true);

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

    // === Bottom: Entry Time ===
    y += 18;
    CreateLine(g_prefix + "Sep2", DashboardX + 8, y, DashboardX + panelWidth - 8, y, DashColorBorder);
    y += 4;

    string entryInfo = "Entry: " + StringFormat("%02d:%02d", EntryHour, EntryMinute) +
                       " | SL: " + DoubleToString(StopLossPercent, 1) + "%" +
                       " | TP: " + DoubleToString(TakeProfitPercent, 1) + "%" +
                       " | Risk: " + DoubleToString(RiskAmount, 0);
    CreateLabel(g_prefix + "EntryInfo", col1, y, entryInfo, DashColorLabel, 7, false);

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
    ObjectSetString(0, g_prefix + "ValPositions", OBJPROP_TEXT, IntegerToString(openPos) + "/" + IntegerToString(MaxPositions));

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
//| Create rectangle helper                                           |
//+------------------------------------------------------------------+
void CreateRectangle(string name, int x, int y, int width, int height, color bgColor, color borderColor)
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
//| Check if current day is a trading day                            |
//+------------------------------------------------------------------+
bool IsTradingDay(int dayOfWeek)
{
    switch(dayOfWeek)
    {
        case 1: return TradeMonday;
        case 2: return TradeTuesday;
        case 3: return TradeWednesday;
        case 4: return TradeThursday;
        case 5: return TradeFriday;
        default: return false;  // Saturday (6) and Sunday (0)
    }
}

//+------------------------------------------------------------------+
//| Check if spread is acceptable                                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
    if(!UseSpreadFilter)
        return true;

    double ask = m_symbol.Ask();
    double bid = m_symbol.Bid();
    double spread = ask - bid;
    double spreadPercent = (spread / bid) * 100.0;

    if(spreadPercent > g_maxSpreadPercent)
    {
        if(LogDiagnostics)
        {
            Print("Spread filter blocked entry: ", DoubleToString(spreadPercent, 4),
                  "% > ", DoubleToString(g_maxSpreadPercent, 4), "% max");
        }
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Check if max daily loss has been reached                         |
//+------------------------------------------------------------------+
bool IsMaxDailyLossReached()
{
    if(MaxDailyLoss <= 0)
        return false;  // Disabled

    // Need fresh stats
    CalculateHistoricalStats();

    if(g_stats.todayPL <= -MaxDailyLoss)
    {
        if(LogDiagnostics)
        {
            Print("Max daily loss reached: ", DoubleToString(g_stats.todayPL, 2),
                  " <= -", DoubleToString(MaxDailyLoss, 2));
        }
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Check if Portfolio Manager has blocked trading                   |
//+------------------------------------------------------------------+
bool IsPortfolioBlocked()
{
    if(!UsePortfolioManager)
        return false;

    if(GlobalVariableCheck(PortfolioSignalName))
    {
        double signal = GlobalVariableGet(PortfolioSignalName);
        if(signal == 1)
        {
            if(LogDiagnostics)
            {
                Print("Trading blocked by Portfolio Manager");
            }
            return true;
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| Check if we should enter a trade                                 |
//+------------------------------------------------------------------+
bool ShouldEnterTrade(datetime currentTime)
{
    // Check if already entered today
    datetime todayDate = StringToTime(TimeToString(currentTime, TIME_DATE));
    if(lastEntryDay == todayDate)
        return false;

    MqlDateTime timeStruct;
    TimeToStruct(currentTime, timeStruct);

    // Check day-of-week filter
    if(!IsTradingDay(timeStruct.day_of_week))
    {
        return false;
    }

    // Check max daily loss
    if(IsMaxDailyLossReached())
    {
        return false;
    }

    // Check Portfolio Manager block signal
    if(IsPortfolioBlocked())
    {
        return false;
    }

    // Check time window
    int currentMinutes = timeStruct.hour * 60 + timeStruct.min;
    int entryStartMinutes = EntryHour * 60 + EntryMinute;
    int entryEndMinutes = entryStartMinutes + EntryWindowMinutes;

    if(currentMinutes >= entryStartMinutes && currentMinutes < entryEndMinutes)
    {
        // Check spread filter
        if(!IsSpreadAcceptable())
        {
            return false;
        }

        if(LogDiagnostics)
        {
            Print("Entry window active: ",
                  StringFormat("%02d:%02d", EntryHour, EntryMinute), " - ",
                  StringFormat("%02d:%02d", entryEndMinutes / 60, entryEndMinutes % 60),
                  " | Current: ", StringFormat("%02d:%02d", timeStruct.hour, timeStruct.min));
        }
        return true;
    }

    return false;
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

        if(m_position.PositionType() != POSITION_TYPE_BUY)
            continue;

        ulong ticket = m_position.Ticket();
        double entryPrice = m_position.PriceOpen();
        double currentSL = m_position.StopLoss();
        double currentTP = m_position.TakeProfit();
        double currentBid = m_symbol.Bid();

        // Calculate price levels
        double profitPercent = ((currentBid - entryPrice) / entryPrice) * 100.0;

        // Break-Even Logic
        if(UseBreakEven && !IsBreakEvenApplied(ticket))
        {
            if(profitPercent >= BreakEvenTriggerPercent)
            {
                double newSL = entryPrice * (1.0 + BreakEvenBufferPercent / 100.0);
                newSL = NormalizePrice(newSL);

                if(newSL > currentSL)
                {
                    if(ModifyPosition(ticket, newSL, currentTP))
                    {
                        MarkBreakEvenApplied(ticket);
                        Print("Break-Even applied to ticket #", ticket,
                              " | Entry: ", entryPrice,
                              " | New SL: ", newSL,
                              " | Profit: ", DoubleToString(profitPercent, 2), "%");
                    }
                }
            }
        }

        // Trailing Stop Logic
        if(UseTrailingStop)
        {
            if(profitPercent >= TrailingActivationPercent)
            {
                double trailDistance = currentBid * (TrailingDistancePercent / 100.0);
                double newSL = currentBid - trailDistance;
                newSL = NormalizePrice(newSL);

                // Only move SL up, never down
                if(newSL > currentSL)
                {
                    // Ensure minimum distance from current price (broker requirement)
                    double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();
                    if(currentBid - newSL >= minStopLevel)
                    {
                        if(ModifyPosition(ticket, newSL, currentTP))
                        {
                            if(LogDiagnostics)
                            {
                                Print("Trailing Stop updated for ticket #", ticket,
                                      " | Price: ", currentBid,
                                      " | New SL: ", newSL,
                                      " | Profit: ", DoubleToString(profitPercent, 2), "%");
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
    // Refresh position data
    if(!m_position.SelectByTicket(ticket))
    {
        Print("ERROR: Cannot select position ticket #", ticket);
        return false;
    }

    // Check if modification is needed
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
//| Count open positions with our magic number                       |
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
//| Normalize volume to symbol constraints                           |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume, double minLot, double maxLot, double lotStep)
{
    if(volume < minLot) volume = minLot;
    if(volume > maxLot) volume = maxLot;

    volume = MathFloor(volume / lotStep) * lotStep;

    int digits = 0;
    double temp = lotStep;
    while(temp < 1.0 && digits < 8)
    {
        temp *= 10;
        digits++;
    }

    return NormalizeDouble(volume, digits);
}

//+------------------------------------------------------------------+
//| Calculate risk-based lot size                                    |
//+------------------------------------------------------------------+
double CalculateVolume(ENUM_ORDER_TYPE orderType, double entryPrice, double stopLossPrice)
{
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

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

    double volume = RiskAmount / lossPerLot;
    volume = NormalizeVolume(volume, minLot, maxLot, lotStep);

    if(LogDiagnostics)
    {
        Print("Risk Amount: ", RiskAmount, " | Loss/Lot: ", lossPerLot, " | Volume: ", volume);
    }

    return volume;
}

//+------------------------------------------------------------------+
//| Open a long position                                             |
//+------------------------------------------------------------------+
void OpenLongPosition()
{
    int positionNumber = CountOpenPositions() + 1;

    ENUM_ORDER_TYPE orderType = ORDER_TYPE_BUY;
    double entryPrice = m_symbol.Ask();
    double stopLossPrice = entryPrice * (1.0 - StopLossPercent / 100.0);
    double takeProfitPrice = entryPrice * (1.0 + TakeProfitPercent / 100.0);

    // Normalize prices
    stopLossPrice = NormalizePrice(stopLossPrice);
    takeProfitPrice = NormalizePrice(takeProfitPrice);

    if(LogDiagnostics)
    {
        Print("========== POSITION SIZING ==========");
        Print("Symbol: ", _Symbol);
        Print("Entry: ", entryPrice, " | SL: ", stopLossPrice, " | TP: ", takeProfitPrice);
    }

    double volume = CalculateVolume(orderType, entryPrice, stopLossPrice);

    if(volume <= 0)
    {
        Print("ERROR: Invalid volume. Trade aborted.");
        return;
    }

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    if(volume < minLot)
    {
        Print("ERROR: Volume ", volume, " below minimum ", minLot, ". Trade aborted.");
        return;
    }

    // Check margin before trading
    double requiredMargin = 0;
    if(!OrderCalcMargin(orderType, _Symbol, volume, entryPrice, requiredMargin))
    {
        Print("ERROR: Cannot calculate margin. Trade aborted.");
        return;
    }

    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    if(requiredMargin > freeMargin)
    {
        Print("ERROR: Insufficient margin. Required: ", requiredMargin, " | Available: ", freeMargin);
        return;
    }

    string customComment = TradeComment + "_" + IntegerToString(positionNumber);

    if(m_trade.Buy(volume, _Symbol, entryPrice, stopLossPrice, takeProfitPrice, customComment))
    {
        Print("========== TRADE EXECUTED ==========");
        Print("Position #", positionNumber, " | Volume: ", volume, " lots");
        Print("Entry: ", entryPrice, " | SL: ", stopLossPrice, " | TP: ", takeProfitPrice);
        Print("Risk: ", RiskAmount, " | Margin: ", requiredMargin);
        Print("=====================================");

        // Update stats immediately after trade
        if(ShowDashboard)
        {
            CalculateHistoricalStats();
            UpdateDashboard();
        }
    }
    else
    {
        Print("========== TRADE FAILED ==========");
        Print("Error: ", GetLastError(), " | ", m_trade.ResultRetcodeDescription());
        Print("===================================");
    }
}
//+------------------------------------------------------------------+
