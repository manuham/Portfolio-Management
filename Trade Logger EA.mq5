//+------------------------------------------------------------------+
//|                                              Trade Logger EA.mq5 |
//|                                   Portfolio Management Suite     |
//|                            Logs all closed trades to CSV files   |
//+------------------------------------------------------------------+
#property copyright "Portfolio Management Suite"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\DealInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== General Settings ==="
input string   MagicNumberList    = "";           // Magic Numbers to Track (comma-separated, empty = all)
input int      UpdateIntervalSec  = 5;            // Update Interval (seconds)
input bool     LogAllSymbols      = true;         // Log All Symbols (false = current chart only)

input group "=== File Settings ==="
input string   FilePrefix         = "TradeLog";   // CSV File Prefix
input bool     MonthlyFiles       = true;         // Create Monthly Files (false = single file)
input string   Delimiter          = ",";          // CSV Delimiter

input group "=== Dashboard Settings ==="
input bool     ShowDashboard      = true;         // Show Dashboard on Chart
input int      DashboardX         = 10;           // Dashboard X Position
input int      DashboardY         = 30;           // Dashboard Y Position
input int      RecentTradesCount  = 10;           // Recent Trades to Display
input color    HeaderColor        = clrGold;      // Header Color
input color    TextColor          = clrWhite;     // Text Color
input color    ProfitColor        = clrLime;      // Profit Color
input color    LossColor          = clrRed;       // Loss Color
input int      FontSize           = 9;            // Font Size

input group "=== Diagnostics ==="
input bool     LogDiagnostics     = false;        // Print Diagnostic Messages

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
ulong    g_magicNumbers[];
int      g_magicCount = 0;
ulong    g_lastLoggedTicket = 0;
datetime g_lastLoggedTime = 0;
int      g_totalLogged = 0;
int      g_sessionLogged = 0;
double   g_sessionProfit = 0;
string   g_currentFileName = "";

// Dashboard object names
string   g_dashboardPrefix = "TL_";

// Recent trades storage for dashboard
struct TradeRecord
{
   ulong    ticket;
   datetime closeTime;
   string   symbol;
   string   direction;
   double   volume;
   double   profit;
   ulong    magic;
};
TradeRecord g_recentTrades[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Parse magic numbers
   ParseMagicNumbers();

   // Load last logged ticket from global variable
   LoadLastLoggedState();

   // Initialize recent trades array
   ArrayResize(g_recentTrades, 0);

   // Set timer
   EventSetTimer(UpdateIntervalSec);

   // Create dashboard
   if(ShowDashboard)
   {
      CreateDashboard();
   }

   Print("Trade Logger EA initialized");
   Print("Tracking ", g_magicCount == 0 ? "ALL" : IntegerToString(g_magicCount), " magic number(s)");
   Print("Update interval: ", UpdateIntervalSec, " seconds");
   Print("File prefix: ", FilePrefix);

   // Do initial scan
   ScanAndLogNewTrades();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Save state
   SaveLastLoggedState();

   // Clean up dashboard
   DeleteDashboard();

   Print("Trade Logger EA stopped. Session logged: ", g_sessionLogged, " trades, Profit: $", DoubleToString(g_sessionProfit, 2));
}

//+------------------------------------------------------------------+
//| Timer function                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   ScanAndLogNewTrades();

   if(ShowDashboard)
   {
      UpdateDashboard();
   }
}

//+------------------------------------------------------------------+
//| Parse magic numbers from input string                             |
//+------------------------------------------------------------------+
void ParseMagicNumbers()
{
   if(MagicNumberList == "")
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
}

//+------------------------------------------------------------------+
//| Check if magic number should be tracked                           |
//+------------------------------------------------------------------+
bool ShouldTrackMagic(ulong magic)
{
   if(g_magicCount == 0)
      return true;  // Track all

   for(int i = 0; i < g_magicCount; i++)
   {
      if(g_magicNumbers[i] == magic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Load last logged state from global variable                       |
//+------------------------------------------------------------------+
void LoadLastLoggedState()
{
   string gvTicket = "TRADELOGGER_LAST_TICKET";
   string gvTime = "TRADELOGGER_LAST_TIME";

   if(GlobalVariableCheck(gvTicket))
   {
      g_lastLoggedTicket = (ulong)GlobalVariableGet(gvTicket);
   }

   if(GlobalVariableCheck(gvTime))
   {
      g_lastLoggedTime = (datetime)GlobalVariableGet(gvTime);
   }

   if(LogDiagnostics)
   {
      Print("Loaded state - Last ticket: ", g_lastLoggedTicket, ", Last time: ", TimeToString(g_lastLoggedTime));
   }
}

//+------------------------------------------------------------------+
//| Save last logged state to global variable                         |
//+------------------------------------------------------------------+
void SaveLastLoggedState()
{
   GlobalVariableSet("TRADELOGGER_LAST_TICKET", (double)g_lastLoggedTicket);
   GlobalVariableSet("TRADELOGGER_LAST_TIME", (double)g_lastLoggedTime);
}

//+------------------------------------------------------------------+
//| Get current filename based on settings                            |
//+------------------------------------------------------------------+
string GetFileName()
{
   if(MonthlyFiles)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return StringFormat("%s_%04d_%02d.csv", FilePrefix, dt.year, dt.mon);
   }
   else
   {
      return FilePrefix + ".csv";
   }
}

//+------------------------------------------------------------------+
//| Check if file exists and has header                               |
//+------------------------------------------------------------------+
bool FileNeedsHeader(string filename)
{
   if(!FileIsExist(filename))
      return true;

   int handle = FileOpen(filename, FILE_READ|FILE_TXT);
   if(handle == INVALID_HANDLE)
      return true;

   bool isEmpty = (FileSize(handle) == 0);
   FileClose(handle);

   return isEmpty;
}

//+------------------------------------------------------------------+
//| Write CSV header                                                  |
//+------------------------------------------------------------------+
void WriteHeader(int handle)
{
   string header = "Ticket" + Delimiter +
                   "OpenTime" + Delimiter +
                   "CloseTime" + Delimiter +
                   "Symbol" + Delimiter +
                   "Direction" + Delimiter +
                   "Volume" + Delimiter +
                   "EntryPrice" + Delimiter +
                   "ExitPrice" + Delimiter +
                   "StopLoss" + Delimiter +
                   "TakeProfit" + Delimiter +
                   "Commission" + Delimiter +
                   "Swap" + Delimiter +
                   "Profit" + Delimiter +
                   "NetProfit" + Delimiter +
                   "ProfitPips" + Delimiter +
                   "MagicNumber" + Delimiter +
                   "Comment" + Delimiter +
                   "Duration_Minutes" + Delimiter +
                   "RiskReward";

   FileWriteString(handle, header + "\n");
}

//+------------------------------------------------------------------+
//| Scan deal history and log new trades                              |
//+------------------------------------------------------------------+
void ScanAndLogNewTrades()
{
   // Select all history
   datetime fromDate = g_lastLoggedTime > 0 ? g_lastLoggedTime - 86400 : 0;  // Go back 1 day for safety

   if(!HistorySelect(fromDate, TimeCurrent()))
   {
      if(LogDiagnostics)
         Print("Failed to select history");
      return;
   }

   int totalDeals = HistoryDealsTotal();
   CDealInfo dealInfo;

   // Collect new trades to log
   TradeRecord newTrades[];
   ArrayResize(newTrades, 0);

   for(int i = 0; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      dealInfo.Ticket(ticket);

      // Only log exit deals (DEAL_ENTRY_OUT)
      if(dealInfo.Entry() != DEAL_ENTRY_OUT)
         continue;

      // Skip if already logged
      if(ticket <= g_lastLoggedTicket)
         continue;

      // Check magic number filter
      if(!ShouldTrackMagic(dealInfo.Magic()))
         continue;

      // Check symbol filter
      if(!LogAllSymbols && dealInfo.Symbol() != _Symbol)
         continue;

      // Log this trade
      if(LogTrade(dealInfo))
      {
         // Add to recent trades for dashboard
         TradeRecord record;
         record.ticket = ticket;
         record.closeTime = dealInfo.Time();
         record.symbol = dealInfo.Symbol();
         record.direction = dealInfo.DealType() == DEAL_TYPE_SELL ? "BUY" : "SELL";  // Exit direction is opposite
         record.volume = dealInfo.Volume();
         record.profit = dealInfo.Profit() + dealInfo.Swap() + dealInfo.Commission();
         record.magic = dealInfo.Magic();

         int size = ArraySize(newTrades);
         ArrayResize(newTrades, size + 1);
         newTrades[size] = record;

         // Update tracking
         if(ticket > g_lastLoggedTicket)
         {
            g_lastLoggedTicket = ticket;
            g_lastLoggedTime = dealInfo.Time();
         }

         g_totalLogged++;
         g_sessionLogged++;
         g_sessionProfit += record.profit;
      }
   }

   // Add new trades to recent trades array (for dashboard)
   for(int i = 0; i < ArraySize(newTrades); i++)
   {
      AddToRecentTrades(newTrades[i]);
   }

   // Save state periodically
   if(ArraySize(newTrades) > 0)
   {
      SaveLastLoggedState();

      if(LogDiagnostics)
      {
         Print("Logged ", ArraySize(newTrades), " new trade(s)");
      }
   }
}

//+------------------------------------------------------------------+
//| Log a single trade to CSV                                         |
//+------------------------------------------------------------------+
bool LogTrade(CDealInfo &dealInfo)
{
   string filename = GetFileName();
   bool needHeader = FileNeedsHeader(filename);

   int handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_TXT);
   if(handle == INVALID_HANDLE)
   {
      Print("Failed to open file: ", filename, " Error: ", GetLastError());
      return false;
   }

   // Seek to end
   FileSeek(handle, 0, SEEK_END);

   // Write header if needed
   if(needHeader)
   {
      WriteHeader(handle);
   }

   // Get entry deal info
   ulong positionId = dealInfo.PositionId();
   datetime openTime = 0;
   double entryPrice = 0;
   double stopLoss = 0;
   double takeProfit = 0;
   string dealDirection = "";

   // Find the entry deal for this position
   if(HistorySelectByPosition(positionId))
   {
      int posDeals = HistoryDealsTotal();
      for(int j = 0; j < posDeals; j++)
      {
         ulong entryTicket = HistoryDealGetTicket(j);
         if(entryTicket == 0) continue;

         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(entryTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN)
         {
            openTime = (datetime)HistoryDealGetInteger(entryTicket, DEAL_TIME);
            entryPrice = HistoryDealGetDouble(entryTicket, DEAL_PRICE);

            ENUM_DEAL_TYPE entryType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(entryTicket, DEAL_TYPE);
            dealDirection = (entryType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
            break;
         }
      }
   }

   // Calculate derived values
   datetime closeTime = dealInfo.Time();
   double exitPrice = dealInfo.Price();
   double volume = dealInfo.Volume();
   double commission = dealInfo.Commission();
   double swap = dealInfo.Swap();
   double profit = dealInfo.Profit();
   double netProfit = profit + swap + commission;
   string symbol = dealInfo.Symbol();
   ulong magic = dealInfo.Magic();
   string comment = dealInfo.Comment();

   // Calculate duration in minutes
   int durationMinutes = (openTime > 0) ? (int)((closeTime - openTime) / 60) : 0;

   // Calculate profit in pips
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipValue = (digits == 3 || digits == 5) ? point * 10 : point;
   double profitPips = 0;

   if(dealDirection == "BUY" && entryPrice > 0)
   {
      profitPips = (exitPrice - entryPrice) / pipValue;
   }
   else if(dealDirection == "SELL" && entryPrice > 0)
   {
      profitPips = (entryPrice - exitPrice) / pipValue;
   }

   // Calculate Risk/Reward (if we have SL info from comment or estimate)
   string rrString = "N/A";

   // Build CSV line
   string line = StringFormat("%I64u%s%s%s%s%s%s%s%s%s%.5f%s%.5f%s%.2f%s%.2f%s%.2f%s%.2f%s%.2f%s%.2f%s%.1f%s%I64u%s%s%s%d%s%s",
      dealInfo.Ticket(), Delimiter,
      TimeToString(openTime, TIME_DATE|TIME_MINUTES), Delimiter,
      TimeToString(closeTime, TIME_DATE|TIME_MINUTES), Delimiter,
      symbol, Delimiter,
      dealDirection, Delimiter,
      volume, Delimiter,
      entryPrice, Delimiter,
      exitPrice, Delimiter,
      stopLoss, Delimiter,
      takeProfit, Delimiter,
      commission, Delimiter,
      swap, Delimiter,
      profit, Delimiter,
      netProfit, Delimiter,
      profitPips, Delimiter,
      magic, Delimiter,
      comment, Delimiter,
      durationMinutes, Delimiter,
      rrString);

   FileWriteString(handle, line + "\n");
   FileClose(handle);

   if(LogDiagnostics)
   {
      Print("Logged trade: ", symbol, " ", dealDirection, " ", DoubleToString(volume, 2), " lots, P/L: $", DoubleToString(netProfit, 2));
   }

   return true;
}

//+------------------------------------------------------------------+
//| Add trade to recent trades array                                  |
//+------------------------------------------------------------------+
void AddToRecentTrades(TradeRecord &trade)
{
   int size = ArraySize(g_recentTrades);

   // Insert at beginning
   ArrayResize(g_recentTrades, size + 1);

   // Shift existing elements
   for(int i = size; i > 0; i--)
   {
      g_recentTrades[i] = g_recentTrades[i-1];
   }

   g_recentTrades[0] = trade;

   // Trim to max size
   if(ArraySize(g_recentTrades) > RecentTradesCount)
   {
      ArrayResize(g_recentTrades, RecentTradesCount);
   }
}

//+------------------------------------------------------------------+
//| Create dashboard objects                                          |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   DeleteDashboard();  // Clean up first

   int y = DashboardY;
   int lineHeight = FontSize + 6;

   // Title
   CreateLabel(g_dashboardPrefix + "Title", DashboardX, y, "═══ TRADE LOGGER ═══", HeaderColor, FontSize + 2);
   y += lineHeight + 4;

   // Stats
   CreateLabel(g_dashboardPrefix + "SessionLabel", DashboardX, y, "Session Trades:", TextColor, FontSize);
   CreateLabel(g_dashboardPrefix + "SessionValue", DashboardX + 120, y, "0", TextColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashboardPrefix + "SessionPLLabel", DashboardX, y, "Session P/L:", TextColor, FontSize);
   CreateLabel(g_dashboardPrefix + "SessionPLValue", DashboardX + 120, y, "$0.00", TextColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashboardPrefix + "FileLabel", DashboardX, y, "Current File:", TextColor, FontSize);
   CreateLabel(g_dashboardPrefix + "FileValue", DashboardX + 120, y, GetFileName(), TextColor, FontSize);
   y += lineHeight;

   CreateLabel(g_dashboardPrefix + "LastUpdateLabel", DashboardX, y, "Last Update:", TextColor, FontSize);
   CreateLabel(g_dashboardPrefix + "LastUpdateValue", DashboardX + 120, y, "--:--:--", TextColor, FontSize);
   y += lineHeight + 4;

   // Recent trades header
   CreateLabel(g_dashboardPrefix + "RecentHeader", DashboardX, y, "─── Recent Trades ───", HeaderColor, FontSize);
   y += lineHeight;

   // Column headers
   CreateLabel(g_dashboardPrefix + "ColTime", DashboardX, y, "Time", HeaderColor, FontSize - 1);
   CreateLabel(g_dashboardPrefix + "ColSymbol", DashboardX + 60, y, "Symbol", HeaderColor, FontSize - 1);
   CreateLabel(g_dashboardPrefix + "ColDir", DashboardX + 140, y, "Dir", HeaderColor, FontSize - 1);
   CreateLabel(g_dashboardPrefix + "ColLots", DashboardX + 175, y, "Lots", HeaderColor, FontSize - 1);
   CreateLabel(g_dashboardPrefix + "ColPL", DashboardX + 220, y, "P/L", HeaderColor, FontSize - 1);
   y += lineHeight;

   // Trade rows
   for(int i = 0; i < RecentTradesCount; i++)
   {
      string rowPrefix = g_dashboardPrefix + "Row" + IntegerToString(i) + "_";
      CreateLabel(rowPrefix + "Time", DashboardX, y, "---", TextColor, FontSize - 1);
      CreateLabel(rowPrefix + "Symbol", DashboardX + 60, y, "---", TextColor, FontSize - 1);
      CreateLabel(rowPrefix + "Dir", DashboardX + 140, y, "---", TextColor, FontSize - 1);
      CreateLabel(rowPrefix + "Lots", DashboardX + 175, y, "---", TextColor, FontSize - 1);
      CreateLabel(rowPrefix + "PL", DashboardX + 220, y, "---", TextColor, FontSize - 1);
      y += lineHeight;
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update dashboard values                                           |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   // Update stats
   UpdateLabel(g_dashboardPrefix + "SessionValue", IntegerToString(g_sessionLogged));

   color plColor = g_sessionProfit >= 0 ? ProfitColor : LossColor;
   string plText = (g_sessionProfit >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(g_sessionProfit), 2);
   UpdateLabel(g_dashboardPrefix + "SessionPLValue", plText, plColor);

   UpdateLabel(g_dashboardPrefix + "FileValue", GetFileName());
   UpdateLabel(g_dashboardPrefix + "LastUpdateValue", TimeToString(TimeCurrent(), TIME_SECONDS));

   // Update recent trades
   int tradeCount = ArraySize(g_recentTrades);
   for(int i = 0; i < RecentTradesCount; i++)
   {
      string rowPrefix = g_dashboardPrefix + "Row" + IntegerToString(i) + "_";

      if(i < tradeCount)
      {
         TradeRecord trade = g_recentTrades[i];

         UpdateLabel(rowPrefix + "Time", TimeToString(trade.closeTime, TIME_MINUTES));
         UpdateLabel(rowPrefix + "Symbol", trade.symbol);
         UpdateLabel(rowPrefix + "Dir", trade.direction);
         UpdateLabel(rowPrefix + "Lots", DoubleToString(trade.volume, 2));

         color tradeColor = trade.profit >= 0 ? ProfitColor : LossColor;
         string tradePL = (trade.profit >= 0 ? "+" : "") + DoubleToString(trade.profit, 2);
         UpdateLabel(rowPrefix + "PL", tradePL, tradeColor);
      }
      else
      {
         UpdateLabel(rowPrefix + "Time", "---");
         UpdateLabel(rowPrefix + "Symbol", "---");
         UpdateLabel(rowPrefix + "Dir", "---");
         UpdateLabel(rowPrefix + "Lots", "---");
         UpdateLabel(rowPrefix + "PL", "---", TextColor);
      }
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete all dashboard objects                                      |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, g_dashboardPrefix) == 0)
      {
         ObjectDelete(0, name);
      }
   }
}

//+------------------------------------------------------------------+
//| Create a label object                                             |
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
//| Update label text and optionally color                            |
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
//| Chart event handler                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   // Redraw dashboard on chart changes
   if(id == CHARTEVENT_CHART_CHANGE && ShowDashboard)
   {
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| OnTick - not used but required                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // Timer handles everything
}
//+------------------------------------------------------------------+
