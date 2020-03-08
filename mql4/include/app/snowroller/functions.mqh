/**
 * Shared functions used by SnowRoller and Sisyphus
 */


/**
 * Handle incoming commands.
 *
 * @param  string commands[] - received commands
 *
 * @return bool - success status of the executed command
 */
bool onCommand(string commands[]) {
   if (!ArraySize(commands))
      return(_true(warn("onCommand(1)  "+ sequence.longName +" empty parameter commands = {}")));

   string cmd = commands[0];

   // wait
   if (cmd == "wait") {
      if (IsTestSequence() && !IsTesting())
         return(true);

      switch (sequence.status) {
         case STATUS_STOPPED:
            if (!start.conditions)                       // whether any start condition is active
               return(_true(warn("onCommand(2)  "+ sequence.longName +" cannot execute \"wait\" command for sequence "+ sequence.name +"."+ NumberToStr(sequence.level, "+.") +" (no active start conditions found)")));
            sequence.status = STATUS_WAITING;
      }
      return(true);
   }

   // start
   if (cmd == "start") {
      if (IsTestSequence() && !IsTesting())
         return(true);

      switch (sequence.status) {
         case STATUS_WAITING:
         case STATUS_STOPPED:
            bool neverStarted = !ArraySize(sequence.start.event);
            if (neverStarted) return(StartSequence(NULL));
            else              return(ResumeSequence(NULL));

      }
      return(true);
   }

   // stop
   if (cmd == "stop") {
      if (IsTestSequence() && !IsTesting())
         return(true);

      switch (sequence.status) {
         case STATUS_PROGRESSING:
            bool bNull;
            if (!UpdateStatus(bNull)) return(false);     // fall-through to STATUS_WAITING
         case STATUS_WAITING:
            return(StopSequence(NULL));
      }
      return(true);
   }

   if (cmd ==     "orderdisplay") return(ToggleOrderDisplayMode());
   if (cmd == "startstopdisplay") return(ToggleStartStopDisplayMode());

   // log unknown commands and let the EA continue
   return(_true(warn("onCommand(3)  "+ sequence.longName +" unknown command "+ DoubleQuoteStr(cmd))));
}


string   last.Sequence.ID = "";
string   last.GridDirection = "";
int      last.GridSize;
string   last.UnitSize;
int      last.StartLevel;
string   last.StartConditions = "";
string   last.StopConditions = "";
string   last.AutoRestart;
bool     last.ShowProfitInPercent;
datetime last.Sessionbreak.StartTime;
datetime last.Sessionbreak.EndTime;


/**
 * Input parameters changed by the code don't survive init cycles. Therefore inputs are backed-up in deinit() by using this
 * function and can be restored in init(). Called only from onDeinitParameters() and onDeinitChartChange().
 */
void BackupInputs() {
   // backed-up inputs are also accessed from ValidateInputs()
   last.Sequence.ID            = StringConcatenate(Sequence.ID,   "");     // String inputs are references to internal C literals
   last.GridDirection          = StringConcatenate(GridDirection, "");     // and must be copied to break the reference.
   last.GridSize               = GridSize;
   last.UnitSize               = UnitSize;
   last.StartLevel             = StartLevel;
   last.StartConditions        = StringConcatenate(StartConditions, "");
   last.StopConditions         = StringConcatenate(StopConditions,  "");
   last.AutoRestart            = AutoRestart;
   last.ShowProfitInPercent    = ShowProfitInPercent;
   last.Sessionbreak.StartTime = Sessionbreak.StartTime;
   last.Sessionbreak.EndTime   = Sessionbreak.EndTime;
}


/**
 * Restore backed-up input parameters. Called only from onInitParameters() and onInitTimeframeChange().
 */
void RestoreInputs() {
   Sequence.ID            = last.Sequence.ID;
   GridDirection          = last.GridDirection;
   GridSize               = last.GridSize;
   UnitSize               = last.UnitSize;
   StartLevel             = last.StartLevel;
   StartConditions        = last.StartConditions;
   StopConditions         = last.StopConditions;
   AutoRestart            = last.AutoRestart;
   ShowProfitInPercent    = last.ShowProfitInPercent;
   Sessionbreak.StartTime = last.Sessionbreak.StartTime;
   Sessionbreak.EndTime   = last.Sessionbreak.EndTime;
}


/**
 * Backup status variables which may change by modifying input parameters. This way status can be restored in case of input
 * errors. Called only from onInitParameters().
 */
void BackupInputStatus() {
   CopyInputStatus(true);
}


/**
 * Restore status variables from the backup. Called only from onInitParameters().
 */
void RestoreInputStatus() {
   CopyInputStatus(false);
}


/**
 * Backup or restore status variables related to input parameter changes. Called only from BackupInputStatus() and
 * RestoreInputStatus() in onInitParameters().
 *
 * @param  bool store - TRUE:  copy status to internal storage (backup)
 *                      FALSE: copy internal storage to status (restore)
 */
void CopyInputStatus(bool store) {
   store = store!=0;

   static int      _sequence.id;
   static int      _sequence.cycle;
   static string   _sequence.name     = "";
   static string   _sequence.longName = "";
   static datetime _sequence.created;
   static bool     _sequence.isTest;
   static int      _sequence.direction;
   static int      _sequence.status;

   static bool     _start.conditions;
   static bool     _start.trend.condition;
   static string   _start.trend.indicator   = "";
   static int      _start.trend.timeframe;
   static string   _start.trend.params      = "";
   static string   _start.trend.description = "";
   static bool     _start.price.condition;
   static int      _start.price.type;
   static double   _start.price.value;
   static string   _start.price.description = "";
   static bool     _start.time.condition;
   static datetime _start.time.value;
   static string   _start.time.description  = "";

   static bool     _stop.trend.condition;
   static string   _stop.trend.indicator    = "";
   static int      _stop.trend.timeframe;
   static string   _stop.trend.params       = "";
   static string   _stop.trend.description  = "";
   static bool     _stop.price.condition;
   static int      _stop.price.type;
   static double   _stop.price.value;
   static string   _stop.price.description  = "";
   static bool     _stop.time.condition;
   static datetime _stop.time.value;
   static string   _stop.time.description   = "";
   static bool     _stop.profitAbs.condition;
   static double   _stop.profitAbs.value;
   static string   _stop.profitAbs.description = "";
   static bool     _stop.profitPct.condition;
   static double   _stop.profitPct.value;
   static double   _stop.profitPct.absValue;
   static string   _stop.profitPct.description = "";
   static bool     _stop.lossAbs.condition;
   static double   _stop.lossAbs.value;
   static string   _stop.lossAbs.description = "";
   static bool     _stop.lossPct.condition;
   static double   _stop.lossPct.value;
   static double   _stop.lossPct.absValue;
   static string   _stop.lossPct.description = "";

   static datetime _sessionbreak.starttime;
   static datetime _sessionbreak.endtime;

   if (store) {
      _sequence.id                = sequence.id;
      _sequence.cycle             = sequence.cycle;
      _sequence.name              = sequence.name;
      _sequence.longName          = sequence.longName;
      _sequence.created           = sequence.created;
      _sequence.isTest            = sequence.isTest;
      _sequence.direction         = sequence.direction;
      _sequence.status            = sequence.status;

      _start.conditions           = start.conditions;
      _start.trend.condition      = start.trend.condition;
      _start.trend.indicator      = start.trend.indicator;
      _start.trend.timeframe      = start.trend.timeframe;
      _start.trend.params         = start.trend.params;
      _start.trend.description    = start.trend.description;
      _start.price.condition      = start.price.condition;
      _start.price.type           = start.price.type;
      _start.price.value          = start.price.value;
      _start.price.description    = start.price.description;
      _start.time.condition       = start.time.condition;
      _start.time.value           = start.time.value;
      _start.time.description     = start.time.description;

      _stop.trend.condition       = stop.trend.condition;
      _stop.trend.indicator       = stop.trend.indicator;
      _stop.trend.timeframe       = stop.trend.timeframe;
      _stop.trend.params          = stop.trend.params;
      _stop.trend.description     = stop.trend.description;
      _stop.price.condition       = stop.price.condition;
      _stop.price.type            = stop.price.type;
      _stop.price.value           = stop.price.value;
      _stop.price.description     = stop.price.description;
      _stop.time.condition        = stop.time.condition;
      _stop.time.value            = stop.time.value;
      _stop.time.description      = stop.time.description;
      _stop.profitAbs.condition   = stop.profitAbs.condition;
      _stop.profitAbs.value       = stop.profitAbs.value;
      _stop.profitAbs.description = stop.profitAbs.description;
      _stop.profitPct.condition   = stop.profitPct.condition;
      _stop.profitPct.value       = stop.profitPct.value;
      _stop.profitPct.absValue    = stop.profitPct.absValue;
      _stop.profitPct.description = stop.profitPct.description;
      _stop.lossAbs.condition     = stop.lossAbs.condition;
      _stop.lossAbs.value         = stop.lossAbs.value;
      _stop.lossAbs.description   = stop.lossAbs.description;
      _stop.lossPct.condition     = stop.lossPct.condition;
      _stop.lossPct.value         = stop.lossPct.value;
      _stop.lossPct.absValue      = stop.lossPct.absValue;
      _stop.lossPct.description   = stop.lossPct.description;

      _sessionbreak.starttime     = sessionbreak.starttime;
      _sessionbreak.endtime       = sessionbreak.endtime;
   }
   else {
      sequence.id                = _sequence.id;
      sequence.cycle             = _sequence.cycle;
      sequence.name              = _sequence.name;
      sequence.longName          = _sequence.longName;
      sequence.created           = _sequence.created;
      sequence.isTest            = _sequence.isTest;
      sequence.direction         = _sequence.direction;
      sequence.status            = _sequence.status;

      start.conditions           = _start.conditions;
      start.trend.condition      = _start.trend.condition;
      start.trend.indicator      = _start.trend.indicator;
      start.trend.timeframe      = _start.trend.timeframe;
      start.trend.params         = _start.trend.params;
      start.trend.description    = _start.trend.description;
      start.price.condition      = _start.price.condition;
      start.price.type           = _start.price.type;
      start.price.value          = _start.price.value;
      start.price.description    = _start.price.description;
      start.time.condition       = _start.time.condition;
      start.time.value           = _start.time.value;
      start.time.description     = _start.time.description;

      stop.trend.condition       = _stop.trend.condition;
      stop.trend.indicator       = _stop.trend.indicator;
      stop.trend.timeframe       = _stop.trend.timeframe;
      stop.trend.params          = _stop.trend.params;
      stop.trend.description     = _stop.trend.description;
      stop.price.condition       = _stop.price.condition;
      stop.price.type            = _stop.price.type;
      stop.price.value           = _stop.price.value;
      stop.price.description     = _stop.price.description;
      stop.time.condition        = _stop.time.condition;
      stop.time.value            = _stop.time.value;
      stop.time.description      = _stop.time.description;
      stop.profitAbs.condition   = _stop.profitAbs.condition;
      stop.profitAbs.value       = _stop.profitAbs.value;
      stop.profitAbs.description = _stop.profitAbs.description;
      stop.profitPct.condition   = _stop.profitPct.condition;
      stop.profitPct.value       = _stop.profitPct.value;
      stop.profitPct.absValue    = _stop.profitPct.absValue;
      stop.profitPct.description = _stop.profitPct.description;
      stop.lossAbs.condition     = _stop.lossAbs.condition;
      stop.lossAbs.value         = _stop.lossAbs.value;
      stop.lossAbs.description   = _stop.lossAbs.description;
      stop.lossPct.condition     = _stop.lossPct.condition;
      stop.lossPct.value         = _stop.lossPct.value;
      stop.lossPct.absValue      = _stop.lossPct.absValue;
      stop.lossPct.description   = _stop.lossPct.description;

      sessionbreak.starttime     = _sessionbreak.starttime;
      sessionbreak.endtime       = _sessionbreak.endtime;
   }
}


/**
 * Adjust the order markers created or omitted by the terminal for a filled pending order.
 *
 * @param  int i - index in the order arrays
 *
 * @return bool - success status
 */
bool Chart.MarkOrderFilled(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - no display -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   static string sPrefix = "";
   if (!StringLen(sPrefix)) {
      if      (SNOWROLLER) sPrefix = "SR.";
      else if (SISYPHUS)   sPrefix = "SPH.";
      else                 sPrefix = "??.";
   }
   string comment     = sPrefix + sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   color  markerColor = CLR_NONE;

   if (orderDisplayMode >= ODM_PYRAMID)
      markerColor = ifInt(orders.type[i]==OP_BUY, CLR_LONG, CLR_SHORT);

   return(ChartMarker.OrderFilled_B(orders.ticket[i], orders.pendingType[i], orders.pendingPrice[i], Digits, markerColor, sequence.unitsize, Symbol(), orders.openTime[i], orders.openPrice[i], comment));
}


/**
 * Adjust the order markers created or omitted by the terminal for a sent pending or market order.
 *
 * @param  int i - index in the order arrays
 *
 * @return bool - success status
 */
bool Chart.MarkOrderSent(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - no display -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   static string sPrefix = "";
   if (!StringLen(sPrefix)) {
      if      (SNOWROLLER) sPrefix = "SR.";
      else if (SISYPHUS)   sPrefix = "SPH.";
      else                 sPrefix = "??.";
   }
   bool pending = orders.pendingType[i] != OP_UNDEFINED;

   int      type        =    ifInt(pending, orders.pendingType [i], orders.type     [i]);
   datetime openTime    =    ifInt(pending, orders.pendingTime [i], orders.openTime [i]);
   double   openPrice   = ifDouble(pending, orders.pendingPrice[i], orders.openPrice[i]);
   string   comment     = sPrefix + sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   color    markerColor = CLR_NONE;

   if (orderDisplayMode != ODM_NONE) {
      if      (pending)                         markerColor = CLR_PENDING;
      else if (orderDisplayMode >= ODM_PYRAMID) markerColor = ifInt(IsLongOrderType(type), CLR_LONG, CLR_SHORT);
   }
   return(ChartMarker.OrderSent_B(orders.ticket[i], Digits, markerColor, type, sequence.unitsize, Symbol(), openTime, openPrice, orders.stopLoss[i], 0, comment));
}


/**
 * Adjust the order markers created or omitted by the terminal for a closed position.
 *
 * @param  int i - index in the order arrays
 *
 * @return bool - success status
 */
bool Chart.MarkPositionClosed(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - no display -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   color markerColor = CLR_NONE;

   if (orderDisplayMode != ODM_NONE) {
      if ( orders.closedBySL[i]) /*&&*/ if (orderDisplayMode != ODM_PYRAMID) markerColor = CLR_CLOSE;
      if (!orders.closedBySL[i]) /*&&*/ if (orderDisplayMode >= ODM_PYRAMID) markerColor = CLR_CLOSE;
   }
   return(ChartMarker.PositionClosed_B(orders.ticket[i], Digits, markerColor, orders.type[i], sequence.unitsize, Symbol(), orders.openTime[i], orders.openPrice[i], orders.closeTime[i], orders.closePrice[i]));
}


/**
 * Get a user confirmation for a trade request at the first tick. Safety measure against runtime errors.
 *
 * @param  string location - location identifier of the confirmation
 * @param  string message  - confirmation message
 *
 * @return bool - confirmation result
 */
bool ConfirmFirstTickTrade(string location, string message) {
   static bool confirmed;
   if (confirmed)                         // On nested calls behave like a no-op, don't return the former result. Trade requests
      return(true);                       // will differ and the calling logic must correctly interprete the first result.

   bool result;
   if (Tick > 1 || IsTesting()) {
      result = true;
   }
   else {
      PlaySoundEx("Windows Notify.wav");
      result = (IDOK == MessageBoxEx(__NAME() + ifString(StringLen(location), " - "+ location, ""), ifString(IsDemoFix(), "", "- Real Account -\n\n") + message, MB_ICONQUESTION|MB_OKCANCEL));
      RefreshRates();
   }
   confirmed = true;

   return(result);
}


/**
 * Return the number of known open positions of the sequence.
 *
 * @return int
 */
int CountOpenPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]!=OP_UNDEFINED) /*&&*/ if (!orders.closeTime[i])
         count++;
   }
   return(count);
}


/**
 * Return the number of known open pending orders of the sequence.
 *
 * @return int
 */
int CountPendingOrders() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]==OP_UNDEFINED) /*&&*/ if (!orders.closeTime[i])
         count++;
   }
   return(count);
}


/**
 * Generate a new sequence id.
 *
 * @return int - sequence id between SID_MAX and SID_MAX (1000-16383)
 */
int CreateSequenceId() {
   MathSrand(GetTickCount());
   int id;                                               // TODO: in tester generate consecutive ids
   while (id < SID_MIN || id > SID_MAX) {
      id = MathRand();
   }
   return(id);                                           // TODO: test id for uniqueness
}


/**
 * Create the status display box. It consists of overlapping rectangles made of char "g" in font "Webdings". Called only from
 * afterInit().
 *
 * @return int - error status
 */
int CreateStatusBox() {
   if (!__CHART()) return(NO_ERROR);

   int x[]={2, 101, 165}, y=62, fontSize=75, rectangles=ArraySize(x);
   color  bgColor = C'248,248,248';                      // that's chart background color
   string label;

   for (int i=0; i < rectangles; i++) {
      label = __NAME() +".statusbox."+ (i+1);
      if (ObjectFind(label) != 0) {
         ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
         ObjectRegister(label);
      }
      ObjectSet    (label, OBJPROP_CORNER, CORNER_TOP_LEFT);
      ObjectSet    (label, OBJPROP_XDISTANCE, x[i]);
      ObjectSet    (label, OBJPROP_YDISTANCE, y   );
      ObjectSetText(label, "g", fontSize, "Webdings", bgColor);
   }
   return(catch("CreateStatusBox(1)"));
}


/**
 * Return the full name of the custom logfile.
 *
 * @return string - filename or an empty string in tester (no separate logfile)
 */
string GetCustomLogFileName() {
   return("");                            // for the time being: disable the custom log

   string name = GetStatusFileName();
   if (!StringLen(name)) return("");
   if (IsTestSequence()) return("");

   return(StrLeft(name, -3) +"log");
}


/**
 * Return the full name of the status file.
 *
 * @return string - filename or an empty string in case of errors
 */
string GetStatusFileName() {
   if (!sequence.id) return(_EMPTY_STR(catch("GetStatusFileName(1)  "+ sequence.longName +" illegal value of sequence.id = "+ sequence.id, ERR_ILLEGAL_STATE)));

   string sSID = "";
   if (SNOWROLLER) sSID = "SR.";
   if (SISYPHUS)   sSID = "SPH.";

   string directory, baseName=StrToLower(Symbol()) +"."+ sSID + sequence.id +".set";

   if (IsTestSequence()) directory = "\\presets\\";
   else                  directory = "\\presets\\"+ ShortAccountCompany() +"\\";

   return(GetMqlFilesPath() + directory + baseName);
}


/**
 * Handle occurred network errors. Disables regular processing of the EA until the retry condition for the next trade request
 * is fulfilled.
 *
 * @return bool - whether regular processing should continue (i.e. the trade request should be repeated)
 */
bool HandleNetworkErrors() {
   // TODO: Regular processing must always continue, only trade requests must be disabled.
   switch (lastNetworkError) {
      case NO_ERROR:
         return(true);

      case ERR_NO_CONNECTION:
      case ERR_TRADESERVER_GONE:
      case ERR_TRADE_DISABLED:
         if (sequence.status==STATUS_STARTING || sequence.status==STATUS_STOPPING)
            return(!catch("HandleNetworkErrors(1)  "+ sequence.longName +" in status "+ StatusToStr(sequence.status) +" not yet implemented", ERR_NOT_IMPLEMENTED));

         if (sequence.status == STATUS_PROGRESSING) {
            if (Tick.Time >= nextRetry) {
               retries++;
               return(true);
            }
            else {
               return(false);
            }
         }
         return(!catch("HandleNetworkErrors(2)  "+ sequence.longName +" unsupported sequence status "+ StatusToStr(sequence.status), ERR_ILLEGAL_STATE));
   }
   return(!catch("HandleNetworkErrors(3)  "+ sequence.longName +" unsupported error ", lastNetworkError));
}


/**
 * Whether the current sequence was created in Strategy Tester and thus represents a test. Considers the fact that a test
 * sequence may be loaded in an online chart after the test (for visualization).
 *
 * @return bool
 */
bool IsTestSequence() {
   return(sequence.isTest || IsTesting());
}


/**
 * Redraw order markers of the active sequence. Markers of finished sequence cycles will no be redrawn.
 */
void RedrawOrders() {
   if (!__CHART()) return;

   bool wasPending, isPending, closedPosition;
   int  size = ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      wasPending     = orders.pendingType[i] != OP_UNDEFINED;
      isPending      = orders.type[i] == OP_UNDEFINED;
      closedPosition = !isPending && orders.closeTime[i]!=0;

      if    (isPending)                         Chart.MarkOrderSent(i);
      else /*openPosition || closedPosition*/ {                                  // openPosition is result of...
         if (wasPending)                        Chart.MarkOrderFilled(i);        // a filled pending order or...
         else                                   Chart.MarkOrderSent(i);          // a market order
         if (closedPosition)                    Chart.MarkPositionClosed(i);
      }
   }
   catch("RedrawOrders(1)");
}


/**
 * Redraw the start/stop markers of the active sequence. Markers of finished sequence cycles will no be redrawn.
 */
void RedrawStartStop() {
   if (!__CHART()) return;

   string   label, sCycle = StrPadLeft(sequence.cycle, 3, "0");
   datetime time;
   double   price;
   double   profit;
   int starts = ArraySize(sequence.start.event);

   // start markers
   for (int i=0; i < starts; i++) {
      time   = sequence.start.time  [i];
      price  = sequence.start.price [i];
      profit = sequence.start.profit[i];

      label = "SR."+ sequence.id +"."+ sCycle +".start."+ (i+1);
      if (ObjectFind(label) == 0)
         ObjectDelete(label);

      if (startStopDisplayMode != SDM_NONE) {
         ObjectCreate (label, OBJ_ARROW, 0, time, price);
         ObjectSet    (label, OBJPROP_ARROWCODE, startStopDisplayMode);
         ObjectSet    (label, OBJPROP_BACK,      false               );
         ObjectSet    (label, OBJPROP_COLOR,     Blue                );
         ObjectSetText(label, "Profit: "+ DoubleToStr(profit, 2));
      }
   }

   // stop markers
   for (i=0; i < starts; i++) {
      if (sequence.stop.time[i] > 0) {
         time   = sequence.stop.time [i];
         price  = sequence.stop.price[i];
         profit = sequence.stop.profit[i];

         label = "SR."+ sequence.id +"."+ sCycle +".stop."+ (i+1);
         if (ObjectFind(label) == 0)
            ObjectDelete(label);

         if (startStopDisplayMode != SDM_NONE) {
            ObjectCreate (label, OBJ_ARROW, 0, time, price);
            ObjectSet    (label, OBJPROP_ARROWCODE, startStopDisplayMode);
            ObjectSet    (label, OBJPROP_BACK,      false               );
            ObjectSet    (label, OBJPROP_COLOR,     Blue                );
            ObjectSetText(label, "Profit: "+ DoubleToStr(profit, 2));
         }
      }
   }
   catch("RedrawStartStop(1)");
}


/**
 * Restore sequence id and transient status found in the chart after recompilation or terminal restart.
 *
 * @return bool - whether a sequence id was found and restored
 */
bool RestoreChartStatus() {
   string name=__NAME(), key=name +".runtime.Sequence.ID", sValue="";

   if (ObjectFind(key) == 0) {
      Chart.RestoreString(key, sValue);

      if (StrStartsWith(sValue, "T")) {
         sequence.isTest = true;
         sValue = StrSubstr(sValue, 1);
      }
      int iValue = StrToInteger(sValue);
      if (!iValue) {
         sequence.status = STATUS_UNDEFINED;
      }
      else {
         sequence.id     = iValue;
         Sequence.ID     = ifString(IsTestSequence(), "T", "") + sequence.id;
         sequence.status = STATUS_WAITING;
      }
      bool bValue;
      Chart.RestoreInt (name +".runtime.startStopDisplayMode",   startStopDisplayMode  );
      Chart.RestoreInt (name +".runtime.orderDisplayMode",       orderDisplayMode      );
      Chart.RestoreBool(name +".runtime.__STATUS_INVALID_INPUT", __STATUS_INVALID_INPUT);
      Chart.RestoreBool(name +".runtime.CANCELLED_BY_USER",      bValue                ); if (bValue) SetLastError(ERR_CANCELLED_BY_USER);
      catch("RestoreChartStatus(1)");
      return(iValue != 0);
   }
   return(false);
}


/**
 * Delete all sequence data stored in the chart.
 *
 * @return int - error status
 */
int DeleteChartStatus() {
   string label, prefix=__NAME() +".runtime.";

   for (int i=ObjectsTotal()-1; i>=0; i--) {
      label = ObjectName(i);
      if (StrStartsWith(label, prefix)) /*&&*/ if (ObjectFind(label) == 0)
         ObjectDelete(label);
   }
   return(catch("DeleteChartStatus(1)"));
}


/**
 * Update all string representations for ShowStatus().
 */
void SS.All() {
   if (!__CHART()) return;

   SS.SequenceName();
   SS.GridBase();
   SS.GridDirection();
   SS.MissedLevels();
   SS.UnitSize();
   SS.ProfitPerLevel();
   SS.StartStopConditions();
   SS.AutoRestart();
   SS.Stops();
   SS.TotalPL();
   SS.MaxProfit();
   SS.MaxDrawdown();
   SS.StartStopStats();
}


/**
 * ShowStatus(): Update the string representation of the "AutoRestart" option.
 */
void SS.AutoRestart() {
   if (!__CHART()) return;

   if (AutoRestart=="Off") sAutoRestart = "AutoRestart:  "+ AutoRestart + NL;
   else                    sAutoRestart = "AutoRestart:  "+ AutoRestart +" ("+ (sequence.cycle-1) +")" + NL;
}


/**
 * ShowStatus(): Update the string representation of the gridbase.
 */
void SS.GridBase() {
   if (!__CHART()) return;

   double gridbase = GetGridbase();
   if (!gridbase) return;

   sGridBase = " @ "+ NumberToStr(gridbase, PriceFormat);
}


/**
 * ShowStatus(): Update the string representation of the sequence direction.
 */
void SS.GridDirection() {
   if (!__CHART()) return;

   if (sequence.direction != 0) {
      sSequenceDirection = TradeDirectionDescription(sequence.direction) +" ";
   }
}


/**
 * ShowStatus(): Update the string representation of "sequence.maxDrawdown".
 */
void SS.MaxDrawdown() {
   if (!__CHART()) return;

   if (ShowProfitInPercent) sSequenceMaxDrawdown = NumberToStr(MathDiv(sequence.maxDrawdown, sequence.startEquity) * 100, "+.2") +"%";
   else                     sSequenceMaxDrawdown = NumberToStr(sequence.maxDrawdown, "+.2");
   SS.PLStats();
}


/**
 * ShowStatus(): Update the string representation of "sequence.maxProfit".
 */
void SS.MaxProfit() {
   if (!__CHART()) return;

   if (ShowProfitInPercent) sSequenceMaxProfit = NumberToStr(MathDiv(sequence.maxProfit, sequence.startEquity) * 100, "+.2") +"%";
   else                     sSequenceMaxProfit = NumberToStr(sequence.maxProfit, "+.2");
   SS.PLStats();
}


/**
 * ShowStatus(): Update the string representation of the missed gridlevels.
 */
void SS.MissedLevels() {
   if (!__CHART()) return;

   int size = ArraySize(sequence.missedLevels);
   if (!size) sSequenceMissedLevels = "";
   else       sSequenceMissedLevels = ", missed: "+ JoinInts(sequence.missedLevels);
}


/**
 * ShowStatus(): Update the string representaton of the P/L statistics.
 */
void SS.PLStats() {
   if (!__CHART()) return;

   if (sequence.maxLevel != 0) {             // not before a positions was opened
      sSequencePlStats = "  ("+ sSequenceMaxProfit +"/"+ sSequenceMaxDrawdown +")";
   }
}


/**
 * ShowStatus(): Update the string representation of "sequence.profitPerLevel".
 */
void SS.ProfitPerLevel() {
   if (!__CHART()) return;

   if (!sequence.level) {
      sSequenceProfitPerLevel = "";          // not before a positions was opened
   }
   else {
      double stopSize = GridSize * PipValue(sequence.unitsize);
      int    levels   = Abs(sequence.level) - ArraySize(sequence.missedLevels);
      double profit   = levels * stopSize;

      if (ShowProfitInPercent) sSequenceProfitPerLevel = " = "+ DoubleToStr(MathDiv(profit, sequence.startEquity) * 100, 1) +"%/level";
      else                     sSequenceProfitPerLevel = " = "+ DoubleToStr(profit, 2) +"/level";
   }
}


/**
 * ShowStatus(): Update the string representations of standard and long sequence name.
 */
void SS.SequenceName() {
   sequence.name = "";

   if      (sequence.direction == D_LONG)  sequence.name = "L";
   else if (sequence.direction == D_SHORT) sequence.name = "S";

   sequence.name     = sequence.name +"."+ sequence.id;
   sequence.longName = sequence.name +"."+ NumberToStr(sequence.level, "+.");
}


/**
 * ShowStatus(): Update the string representation of the configured start/stop conditions.
 */
void SS.StartStopConditions() {
   if (!__CHART()) return;

   // start conditions, order: [sessionbreak >>] trend, time, price
   string sValue = "";
   if (start.time.description!="" || start.price.description!="") {
      if (start.time.description != "") {
         sValue = sValue + ifString(start.time.condition, "@", "!") + start.time.description;
      }
      if (start.price.description != "") {
         sValue = sValue + ifString(sValue=="", "", " && ") + ifString(start.price.condition, "@", "!") + start.price.description;
      }
   }
   if (start.trend.description != "") {
      string sTrend = ifString(start.trend.condition, "@", "!") + start.trend.description;

      if (start.time.description!="" && start.price.description!="") {
         sValue = "("+ sValue +")";
      }
      if (start.time.description=="" && start.price.description=="") {
         sValue = sTrend;
      }
      else {
         sValue = sTrend +" || "+ sValue;
      }
   }
   if (sessionbreak.waiting) {
      if (sValue != "") sValue = " >> "+ sValue;
      sValue = "sessionbreak"+ sValue;
   }
   if (sValue == "") sStartConditions = "-";
   else              sStartConditions = sValue;

   // stop conditions, order: trend, profit, loss, time, price
   sValue = "";
   if (stop.trend.description != "") {
      sValue = sValue + ifString(sValue=="", "", " || ") + ifString(stop.trend.condition, "@", "!") + stop.trend.description;
   }
   if (stop.profitAbs.description != "") {
      sValue = sValue + ifString(sValue=="", "", " || ") + ifString(stop.profitAbs.condition, "@", "!") + stop.profitAbs.description;
   }
   if (stop.profitPct.description != "") {
      sValue = sValue + ifString(sValue=="", "", " || ") + ifString(stop.profitPct.condition, "@", "!") + stop.profitPct.description;
   }
   if (stop.lossAbs.description != "") {
      sValue = sValue + ifString(sValue=="", "", " || ") + ifString(stop.lossAbs.condition, "@", "!") + stop.lossAbs.description;
   }
   if (stop.lossPct.description != "") {
      sValue = sValue + ifString(sValue=="", "", " || ") + ifString(stop.lossPct.condition, "@", "!") + stop.lossPct.description;
   }
   if (stop.time.description != "") {
      sValue = sValue + ifString(sValue=="", "", " || ") + ifString(stop.time.condition, "@", "!") + stop.time.description;
   }
   if (stop.price.description != "") {
      sValue = sValue + ifString(sValue=="", "", " || ") + ifString(stop.price.condition, "@", "!") + stop.price.description;
   }
   if (sValue == "") sStopConditions = "-";
   else              sStopConditions = sValue;
}


/**
 * ShowStatus(); Update the string representation of the start/stop statistics.
 */
void SS.StartStopStats() {
   if (!__CHART()) return;

   sStartStopStats = "";

   int size = ArraySize(sequence.start.event);
   string sStartPL, sStopPL;

   for (int i=0; i < size-1; i++) {
      if (ShowProfitInPercent) {
         sStartPL = NumberToStr(MathDiv(sequence.start.profit[i], sequence.startEquity) * 100, "+.2") +"%";
         sStopPL  = NumberToStr(MathDiv(sequence.stop.profit [i], sequence.startEquity) * 100, "+.2") +"%";
      }
      else {
         sStartPL = NumberToStr(sequence.start.profit[i], "+.2");
         sStopPL  = NumberToStr(sequence.stop.profit [i], "+.2");
      }
      sStartStopStats = " ----------------------------------------------------"+ NL
                       +" "+ (i+1) +":   Start: "+ sStartPL +"   Stop: "+ sStopPL + StrRightFrom(sStartStopStats, "--", -1);
   }
   if (StringLen(sStartStopStats) > 0)
      sStartStopStats = sStartStopStats + NL;
}


/**
 * ShowStatus(): Update the string representation of "sequence.stops" and "sequence.stopsPL".
 */
void SS.Stops() {
   if (!__CHART()) return;
   sSequenceStops = sequence.stops +" stop"+ ifString(sequence.stops==1, "", "s");

   // not set before the first stopped-out position
   if (sequence.stops > 0) {
      if (ShowProfitInPercent) sSequenceStopsPL = " = "+ DoubleToStr(MathDiv(sequence.stopsPL, sequence.startEquity) * 100, 2) +"%";
      else                     sSequenceStopsPL = " = "+ DoubleToStr(sequence.stopsPL, 2);
   }
}


/**
 * ShowStatus(): Update the string representation of "sequence.totalPL".
 */
void SS.TotalPL() {
   if (!__CHART()) return;

   // not set before the first open position
   if (sequence.maxLevel == 0)   sSequenceTotalPL = "-";
   else if (ShowProfitInPercent) sSequenceTotalPL = NumberToStr(MathDiv(sequence.totalPL, sequence.startEquity) * 100, "+.2") +"%";
   else                          sSequenceTotalPL = NumberToStr(sequence.totalPL, "+.2");
}


/**
 * ShowStatus(): Update the string representation of the unitsize.
 */
void SS.UnitSize() {
   if (!__CHART()) return;

   double equity = sequence.startEquity;

   if (!sequence.unitsize) {
      if (!equity) equity = CalculateStartEquity();
      sequence.unitsize = CalculateUnitSize(equity);
   }
   string sCompounding = ifString(StrIsNumeric(UnitSize), "", " (compound.)");
   double stopSize     = GridSize * PipValue(sequence.unitsize) - sequence.commission;

   if (ShowProfitInPercent) sLotSize = NumberToStr(sequence.unitsize, ".+") +" lot"+ sCompounding +" = "+ DoubleToStr(MathDiv(stopSize, equity) * 100, 2) +"%/stop";
   else                     sLotSize = NumberToStr(sequence.unitsize, ".+") +" lot"+ sCompounding +" = "+ DoubleToStr(stopSize, 2) +"/stop";
}


/**
 * Return a description of a sequence status code.
 *
 * @param  int status
 *
 * @return string
 */
string StatusDescription(int status) {
   switch (status) {
      case STATUS_UNDEFINED  : return("undefined"  );
      case STATUS_WAITING    : return("waiting"    );
      case STATUS_STARTING   : return("starting"   );
      case STATUS_PROGRESSING: return("progressing");
      case STATUS_STOPPING   : return("stopping"   );
      case STATUS_STOPPED    : return("stopped"    );
   }
   return(_EMPTY_STR(catch("StatusDescription(1)  "+ sequence.longName +" invalid parameter status = "+ status, ERR_INVALID_PARAMETER)));
}


/**
 * Return a readable version of a sequence status code.
 *
 * @param  int status
 *
 * @return string
 */
string StatusToStr(int status) {
   switch (status) {
      case STATUS_UNDEFINED  : return("STATUS_UNDEFINED"  );
      case STATUS_WAITING    : return("STATUS_WAITING"    );
      case STATUS_STARTING   : return("STATUS_STARTING"   );
      case STATUS_PROGRESSING: return("STATUS_PROGRESSING");
      case STATUS_STOPPING   : return("STATUS_STOPPING"   );
      case STATUS_STOPPED    : return("STATUS_STOPPED"    );
   }
   return(_EMPTY_STR(catch("StatusToStr(1)  "+ sequence.longName +" invalid parameter status = "+ status, ERR_INVALID_PARAMETER)));
}


/**
 * Store sequence id and transient status in the chart before recompilation or terminal restart.
 *
 * @return int - error status
 */
int StoreChartStatus() {
   string name = __NAME();
   Chart.StoreString(name +".runtime.Sequence.ID",            Sequence.ID                      );
   Chart.StoreInt   (name +".runtime.startStopDisplayMode",   startStopDisplayMode             );
   Chart.StoreInt   (name +".runtime.orderDisplayMode",       orderDisplayMode                 );
   Chart.StoreBool  (name +".runtime.__STATUS_INVALID_INPUT", __STATUS_INVALID_INPUT           );
   Chart.StoreBool  (name +".runtime.CANCELLED_BY_USER",      last_error==ERR_CANCELLED_BY_USER);
   return(catch("StoreChartStatus(1)"));
}


/**
 * Toggle order markers.
 *
 * @return bool - success status
 */
bool ToggleOrderDisplayMode() {
   int pendings   = CountPendingOrders();
   int open       = CountOpenPositions();
   int stoppedOut = CountStoppedOutPositions();
   int closed     = CountClosedPositions();

   // change mode, skip modes without orders
   int oldMode      = orderDisplayMode;
   int size         = ArraySize(orderDisplayModes);
   orderDisplayMode = (orderDisplayMode+1) % size;

   while (orderDisplayMode != oldMode) {                                // #define ODM_NONE     - no display -
      if (orderDisplayMode == ODM_NONE) {                               // #define ODM_STOPS    Pending,       StoppedOut
         break;                                                         // #define ODM_PYRAMID  Pending, Open,             Closed
      }                                                                 // #define ODM_ALL      Pending, Open, StoppedOut, Closed
      else if (orderDisplayMode == ODM_STOPS) {
         if (pendings+stoppedOut > 0)
            break;
      }
      else if (orderDisplayMode == ODM_PYRAMID) {
         if (pendings+open+closed > 0)
            if (open+stoppedOut+closed > 0)                             // otherwise the mode is identical to the previous one
               break;
      }
      else if (orderDisplayMode == ODM_ALL) {
         if (pendings+open+stoppedOut+closed > 0)
            if (stoppedOut > 0)                                         // otherwise the mode is identical to the previous one
               break;
      }
      orderDisplayMode = (orderDisplayMode+1) % size;
   }

   // update display
   if (orderDisplayMode != oldMode) RedrawOrders();
   else                             PlaySoundEx("Plonk.wav");           // nothing to change

   return(!catch("ToggleOrderDisplayMode(1)"));
}


/**
 * Toggle sequence start/stop markers.
 *
 * @return bool - success status of the executed command
 */
bool ToggleStartStopDisplayMode() {
   // change mode
   int i = SearchIntArray(startStopDisplayModes, startStopDisplayMode); // #define SDM_NONE     - no display -
   if (i == -1) {                                                       // #define SDM_PRICE    price markers
      startStopDisplayMode = SDM_PRICE;                                 // default
   }
   else {
      int size = ArraySize(startStopDisplayModes);
      startStopDisplayMode = startStopDisplayModes[(i+1) % size];
   }

   // update display
   RedrawStartStop();
   return(!catch("ToggleStartStopDisplayMode(1)"));
}


/**
 * Syntactically validate and set a specified sequence id (format: /T?[0-9]{4,}/i). Called only from onInitUser().
 *
 * @return bool - validation success status; existence of the status file is NOT checked
 */
bool ValidateInputs.ID() {
   bool interactive = true;

   string sValue = StrToUpper(StrTrim(Sequence.ID));

   if (!StringLen(sValue))
      return(false);

   if (StrLeft(sValue, 1) == "T") {
      sequence.isTest = true;
      sValue = StrSubstr(sValue, 1);
   }
   if (!StrIsDigit(sValue))
      return(_false(ValidateInputs.OnError("ValidateInputs.ID(1)", "Invalid input parameter Sequence.ID: "+ DoubleQuoteStr(Sequence.ID) +" (must be digits only)", interactive)));

   int iValue = StrToInteger(sValue);
   if (iValue < SID_MIN || iValue > SID_MAX)
      return(_false(ValidateInputs.OnError("ValidateInputs.ID(2)", "Invalid input parameter Sequence.ID: "+ DoubleQuoteStr(Sequence.ID) +" (range error)", interactive)));

   sequence.id = iValue;
   Sequence.ID = ifString(IsTestSequence(), "T", "") + sequence.id;
   return(true);
}


/**
 * Error handler for invalid input parameters. Either prompts for input correction or passes on execution to the standard
 * error handler.
 *
 * @param  string location    - error location identifier
 * @param  string message     - error message
 * @param  bool   interactive - whether the error occurred in an interactive or programatic context
 *
 * @return int - resulting error status
 */
int ValidateInputs.OnError(string location, string message, bool interactive) {
   interactive = interactive!=0;
   if (IsTesting() || !interactive)
      return(catch(location +"   "+ message, ERR_INVALID_CONFIG_VALUE));

   int error = ERR_INVALID_INPUT_PARAMETER;
   __STATUS_INVALID_INPUT = true;

   if (__LOG()) log(location +"   "+ message, error);

   PlaySoundEx("Windows Chord.wav");
   int button = MessageBoxEx(__NAME() +" - "+ location, message, MB_ICONERROR|MB_RETRYCANCEL);
   if (button == IDRETRY)
      __STATUS_RELAUNCH_INPUT = true;

   return(error);
}


/**
 * Return a string representation of the input parameters (for logging purposes).
 *
 * @return string
 */
string InputsToStr() {
   return(StringConcatenate("Sequence.ID=",            DoubleQuoteStr(Sequence.ID),                  ";", NL,
                            "GridDirection=",          DoubleQuoteStr(GridDirection),                ";", NL,
                            "GridSize=",               GridSize,                                     ";", NL,
                            "UnitSize=",               DoubleQuoteStr(UnitSize),                     ";", NL,
                            "StartConditions=",        DoubleQuoteStr(StartConditions),              ";", NL,
                            "StopConditions=",         DoubleQuoteStr(StopConditions),               ";", NL,
                            "AutoRestart=",            DoubleQuoteStr(AutoRestart),                  ";", NL,
                            "StartLevel=",             StartLevel,                                   ";", NL,
                            "ShowProfitInPercent=",    BoolToStr(ShowProfitInPercent),               ";", NL,
                            "Sessionbreak.StartTime=", TimeToStr(Sessionbreak.StartTime, TIME_FULL), ";", NL,
                            "Sessionbreak.EndTime=",   TimeToStr(Sessionbreak.EndTime, TIME_FULL),   ";")
   );

   // suppress compiler warnings
   RestoreInputs();
}
