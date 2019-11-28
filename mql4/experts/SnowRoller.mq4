/**
 * SnowRoller - a pyramiding trade manager
 *
 *
 * For theoretical background and proof-of-concept see the links to "Snowballs and the anti-grid" by Bernd Kreu� aka 7bit.
 *
 * This EA is a re-implementation of the above concept. It can be used as a trade manager or as a complete trading system.
 * Once started the EA waits until one of the defined start conditions is fulfilled. It then manages the resulting trades in
 * a pyramiding way until one of the defined stop conditions is fulfilled. Start conditions can be price, time or a trend
 * change of one of the supported trend indicators. Stop conditions can be price, time, a trend change of one the supported
 * trend indicators or an absolute or percentage profit amount. Multiple start and stop conditions may be combined.
 *
 * If AutoResume is enabled and both start and stop define a trend condition the EA waits after a stop and continues trading
 * when the next trend start condition is fulfilled. The EA finally stops after the profit target is reached.
 *
 * If AutoRestart is enabled and the profit target is reached the EA resets itself to the initial state and starts over with
 * a new sequence of trades. For this again both start and stop must define a trend condition.
 *
 * If both AutoResume and AutoRestart are enabled the EA continuously resets itself and trades to the profit target without
 * ever stopping.
 *
 * The EA can automatically interrupt and resume trading during configurable session breaks, e.g. Midnight or weekends.
 * During session breaks all pending orders and open positions are closed. Session break configuration supports holidays.
 *
 * In "/mql4/scripts" are two accompanying scripts "SnowRoller.Start" and "SnowRoller.Stop" to manually control the EA.
 * The EA can be tested and the scripts work in tester, too. The EA can't be optimized in tester as it doesn't make sense.
 *
 * The EA is not FIFO conforming (and will never be) and requires an account with support for "close by opposite positions".
 * It does not support bucket shop accounts, i.e. accounts where MODE_FREEZELEVEL or MODE_STOPLEVEL are not set to 0 (zero).
 *
 *  @link  https://sites.google.com/site/prof7bit/snowball       ["Snowballs and the anti-grid"]
 *  @link  https://www.forexfactory.com/showthread.php?t=226059  ["Snowballs and the anti-grid"]
 *  @link  https://www.forexfactory.com/showthread.php?t=239717  ["Trading the anti-grid with the Snowball EA"]
 *
 *
 * Risk warning: The market can range longer without reaching the profit target than a trading account can survive.
 */
#include <stddefines.mqh>
#include <app/SnowRoller/defines.mqh>
int   __INIT_FLAGS__[] = {INIT_TIMEZONE, INIT_PIPVALUE, INIT_CUSTOMLOG};
int __DEINIT_FLAGS__[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string   Sequence.ID            = "";                      // sequence to load from a status file
extern string   GridDirection          = "Long | Short";          // no bi-directional mode
extern int      GridSize               = 20;
extern double   LotSize                = 0.1;
extern int      StartLevel             = 0;
extern string   StartConditions        = "";                      // @trend(<indicator>:<timeframe>:<params>) | @price(double) | @time(datetime)
extern string   StopConditions         = "";                      // @trend(<indicator>:<timeframe>:<params>) | @price(double) | @time(datetime) | @profit(double[%])
extern bool     AutoResume             = false;                   // whether to automatically reactivate a trend start condition after StopSequence(SIGNAL_TREND)
extern bool     AutoRestart            = false;                   // whether to automatically reset and restart a sequence after TP is reached
extern bool     ShowProfitInPercent    = true;                    // whether PL values are displayed in absolute or percentage values
extern datetime Sessionbreak.StartTime = D'1970.01.01 23:56:00';  // in FXT, the date part is ignored
extern datetime Sessionbreak.EndTime   = D'1970.01.01 01:02:10';  // in FXT, the date part is ignored

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfHistory.mqh>
#include <rsfLibs.mqh>
#include <functions/BarOpenEvent.mqh>
#include <functions/JoinInts.mqh>
#include <functions/JoinStrings.mqh>
#include <structs/rsf/OrderExecution.mqh>
#include <win32api.mqh>

// --- sequence data -----------------------
int      sequence.id;
int      sequence.cycle;                           // counter of restarted sequences if AutoRestart=On: 1...+n
string   sequence.name    = "";                    // "L.1234" | "S.5678"
string   sequence.created = "";                    // GmtTimeFormat(datetime, "%a, %Y.%m.%d %H:%M:%S")
bool     sequence.isTest;                          // whether the sequence is/was a test (a finished test can be loaded into a live chart)
int      sequence.direction;
int      sequence.status;
int      sequence.level;                           // current grid level:      -n...0...+n
int      sequence.maxLevel;                        // max. reached grid level: -n...0...+n
int      sequence.missedLevels[];                  // missed grid levels, e.g. in a fast moving market
double   sequence.startEquity;
int      sequence.stops;                           // number of stopped-out positions: 0...+n
double   sequence.stopsPL;                         // accumulated P/L of all stopped-out positions
double   sequence.closedPL;                        // accumulated P/L of all positions closed at sequence stop
double   sequence.floatingPL;                      // accumulated P/L of all open positions
double   sequence.totalPL;                         // current total P/L of the sequence: totalPL = stopsPL + closedPL + floatingPL
double   sequence.maxProfit;                       // max. experienced total sequence profit:   0...+n
double   sequence.maxDrawdown;                     // max. experienced total sequence drawdown: -n...0
double   sequence.profitPerLevel;                  // current profit amount per grid level
double   sequence.breakeven;                       // current breakeven price
double   sequence.commission;                      // commission value per grid level: -n...0

int      sequence.start.event [];                  // sequence starts (the moment status changes to STATUS_PROGRESSING)
datetime sequence.start.time  [];
double   sequence.start.price [];
double   sequence.start.profit[];

int      sequence.stop.event  [];                  // sequence stops (the moment status changes to STATUS_STOPPED)
datetime sequence.stop.time   [];
double   sequence.stop.price  [];                  // average realized close price of all closed positions
double   sequence.stop.profit [];

// --- start conditions (AND combined) -----
bool     start.conditions;                         // whether any start condition is active

bool     start.trend.condition;
string   start.trend.indicator   = "";
int      start.trend.timeframe;
string   start.trend.params      = "";
string   start.trend.description = "";

bool     start.price.condition;
int      start.price.type;                         // PRICE_BID | PRICE_ASK | PRICE_MEDIAN
double   start.price.value;
double   start.price.lastValue;
string   start.price.description = "";

bool     start.time.condition;
datetime start.time.value;
string   start.time.description = "";

// --- stop conditions (OR combined) -------
bool     stop.trend.condition;                     // whether a stop trend condition is active
string   stop.trend.indicator   = "";
int      stop.trend.timeframe;
string   stop.trend.params      = "";
string   stop.trend.description = "";

bool     stop.price.condition;                     // whether a stop price condition is active
int      stop.price.type;                          // PRICE_BID | PRICE_ASK | PRICE_MEDIAN
double   stop.price.value;
double   stop.price.lastValue;
string   stop.price.description = "";

bool     stop.time.condition;                      // whether a stop time condition is active
datetime stop.time.value;
string   stop.time.description = "";

bool     stop.profitAbs.condition;                 // whether an absolute stop profit condition is active
double   stop.profitAbs.value;
string   stop.profitAbs.description = "";

bool     stop.profitPct.condition;                 // whether a percentage stop profit condition is active
double   stop.profitPct.value;
double   stop.profitPct.absValue    = INT_MAX;
string   stop.profitPct.description = "";

// --- session break management ------------
datetime sessionbreak.starttime;                   // configurable via inputs and framework config
datetime sessionbreak.endtime;
bool     sessionbreak.waiting;                     // whether the sequence waits to resume during or after a session break

// --- gridbase management -----------------
double   gridbase;                                 // current gridbase
int      gridbase.event[];                         // gridbase history
datetime gridbase.time [];
double   gridbase.price[];

// --- order data --------------------------
int      orders.ticket         [];
int      orders.level          [];                 // order grid level: -n...-1 | 1...+n
double   orders.gridBase       [];                 // gridbase when the order was active
int      orders.pendingType    [];                 // pending order type (if applicable)        or -1
datetime orders.pendingTime    [];                 // time of OrderOpen() or last OrderModify() or  0
double   orders.pendingPrice   [];                 // pending entry limit                       or  0
int      orders.type           [];
int      orders.openEvent      [];
datetime orders.openTime       [];
double   orders.openPrice      [];
int      orders.closeEvent     [];
datetime orders.closeTime      [];
double   orders.closePrice     [];
double   orders.stopLoss       [];
bool     orders.clientsideLimit[];                 // whether a limit is managed client-side
bool     orders.closedBySL     [];
double   orders.swap           [];
double   orders.commission     [];
double   orders.profit         [];

// --- other -------------------------------
int      lastEventId;

int      ignorePendingOrders  [];                  // orphaned tickets to ignore
int      ignoreOpenPositions  [];                  // ...
int      ignoreClosedPositions[];                  // ...

int      startStopDisplayMode = SDM_PRICE;         // whether start/stop markers are displayed
int      orderDisplayMode     = ODM_PYRAMID;       // current order display mode

string   sLotSize                = "";             // caching vars to speed-up execution of ShowStatus()
string   sGridBase               = "";
string   sSequenceDirection      = "";
string   sSequenceMissedLevels   = "";
string   sSequenceStops          = "";
string   sSequenceStopsPL        = "";
string   sSequenceTotalPL        = "";
string   sSequenceMaxProfit      = "";
string   sSequenceMaxDrawdown    = "";
string   sSequenceProfitPerLevel = "";
string   sSequencePlStats        = "";
string   sStartConditions        = "";
string   sStopConditions         = "";
string   sAutoResume             = "";
string   sAutoRestart            = "";
string   sRestartStats           = "";

// --- debug settings ----------------------       // configurable via framework config, @see SnowRoller::afterInit()
bool     tester.onStopPause         = false;       // whether to pause the tester on any fulfilled stop condition
bool     tester.onSessionBreakPause = false;       // whether to pause the tester on a sessionbreak stop/resume
bool     tester.onTrendChangePause  = false;       // whether to pause the tester when a trend condition changes
bool     tester.onTakeProfitPause   = false;       // whether to pause the tester when the profit target is reached
bool     tester.reduceStatusWrites  = true;        // whether to skip redundant status file writing in tester


#include <app/SnowRoller/init.mqh>
//#include <app/SnowRoller/deinit.mqh>


/*
  Program actions, events and status changes:
 +---------------------+---------------------+--------------------+
 |       Actions       |       Events        |       Status       |
 +---------------------+---------------------+--------------------+
 | EA::init()          |         -           | STATUS_UNDEFINED   |
 +---------------------+---------------------+--------------------+
 | EA::start()         |         -           | STATUS_WAITING     |
 |                     |                     |                    |
 | (start condition)   |         -           | STATUS_WAITING     |
 |                     |                     |                    |
 | StartSequence()     | EV_SEQUENCE_START   | STATUS_STARTING    |
 | (open order)        |                     | STATUS_PROGRESSING |
 |                     |                     |                    |
 | TrailPendingOrder() | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order filled)      | EV_POSITION_OPEN    | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order stopped out) | EV_POSITION_STOPOUT | STATUS_PROGRESSING |
 |                     |                     |                    |
 | TrailGridBase()     | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (stop condition)    |         -           | STATUS_PROGRESSING |
 |                     |                     |                    |
 | StopSequence()      |         -           | STATUS_STOPPING    |
 | (close position)    | EV_POSITION_CLOSE   | STATUS_STOPPING    |
 |                     | EV_SEQUENCE_STOP    | STATUS_STOPPED     |
 +---------------------+---------------------+--------------------+
 | (start condition)   |         -           | STATUS_WAITING     |
 |                     |                     |                    |
 | ResumeSequence()    |         -           | STATUS_STARTING    |
 | (update gridbase)   | EV_GRIDBASE_CHANGE  | STATUS_STARTING    |
 | (open position)     | EV_POSITION_OPEN    | STATUS_STARTING    |
 |                     | EV_SEQUENCE_START   | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order filled)      | EV_POSITION_OPEN    | STATUS_PROGRESSING |
 |                     |                     |                    |
 | (order stopped out) | EV_POSITION_STOPOUT | STATUS_PROGRESSING |
 |                     |                     |                    |
 | TrailGridBase()     | EV_GRIDBASE_CHANGE  | STATUS_PROGRESSING |
 | ...                 |                     |                    |
 +---------------------+---------------------+--------------------+
*/


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   if (sequence.status == STATUS_UNDEFINED)
      return(NO_ERROR);

   // process chart commands
   if (!HandleEvent(EVENT_CHART_CMD))
      return(last_error);

   int  signal, activatedOrders[];                          // indexes of activated client-side orders
   bool gridChanged;                                        // whether the current gridbase or level changed

   // sequence either waits for start/resume signal...
   if (sequence.status == STATUS_WAITING) {
      if (!IsSessionBreak()) {                              // pause during sessionbreaks
         signal = IsStartSignal();
         if (signal != 0) {
            if (!ArraySize(sequence.start.event)) StartSequence(signal);
            else                                  ResumeSequence(signal);
         }
      }
   }

   // ...or sequence is running...
   else if (sequence.status == STATUS_PROGRESSING) {
      if (UpdateStatus(gridChanged, activatedOrders)) {
         signal = IsStopSignal();
         if (!signal) {
            if (ArraySize(activatedOrders) > 0) ExecuteOrders(activatedOrders);
            if (Tick==1 || gridChanged)         UpdatePendingOrders();
         }
         else StopSequence(signal);
      }
   }

   // ...or sequence is stopped
   else if (sequence.status != STATUS_STOPPED) return(catch("onTick(1)  illegal sequence status: "+ StatusToStr(sequence.status), ERR_ILLEGAL_STATE));

   // update current equity value for equity recorder
   if (EA.RecordEquity)
      tester.equityValue = sequence.startEquity + sequence.totalPL;

   // update profit targets
   if (IsBarOpenEvent(PERIOD_M1)) ShowProfitTargets();

   return(last_error);
}


/**
 * Handle incoming commands.
 *
 * @param  string commands[] - received external commands
 *
 * @return bool - success status
 */
bool onCommand(string commands[]) {
   if (!ArraySize(commands))
      return(_true(warn("onCommand(1)  empty parameter commands = {}")));

   string cmd = commands[0];

   if (cmd == "start") {
      switch (sequence.status) {
         case STATUS_WAITING:
         case STATUS_STOPPED:
            bool neverStarted = !ArraySize(sequence.start.event);
            if (neverStarted) StartSequence(NULL);
            else              ResumeSequence(NULL);

      }
      return(true);
   }

   else if (cmd == "stop") {
      switch (sequence.status) {
         case STATUS_PROGRESSING:
            bool bNull;
            int  iNull[];
            if (!UpdateStatus(bNull, iNull))
               return(false);                   // fall-through to STATUS_WAITING
         case STATUS_WAITING:
            return(StopSequence(NULL));
      }
      return(true);
   }

   else if (cmd ==     "orderdisplay") return(!ToggleOrderDisplayMode()    );
   else if (cmd == "startstopdisplay") return(!ToggleStartStopDisplayMode());

   // log unknown commands and let the EA continue
   return(_true(warn("onCommand(2)  unknown command \""+ cmd +"\"")));
}


/**
 * Start a new trade sequence.
 *
 * @param  int signal - signal which triggered a start condition or NULL if no condition was triggered (explicit start)
 *
 * @return bool - success status
 */
bool StartSequence(int signal) {
   if (IsLastError())                     return(false);
   if (sequence.status != STATUS_WAITING) return(!catch("StartSequence(1)  cannot start "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("StartSequence()", "Do you really want to start a new \""+ StrToLower(TradeDirectionDescription(sequence.direction)) +"\" sequence now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   sequence.status = STATUS_STARTING;
   if (__LOG()) log("StartSequence(2)  starting sequence "+ sequence.name + ifString(sequence.level, " at level "+ Abs(sequence.level), ""));

   // update start/stop conditions
   switch (signal) {
      case SIGNAL_SESSIONBREAK:
         sessionbreak.waiting = false;
         break;

      case SIGNAL_TREND:
         start.trend.condition = AutoResume;
         start.conditions      = false;
         break;

      case SIGNAL_PRICETIME:
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = false;
         break;

      case NULL:                                            // manual start
         sessionbreak.waiting  = false;
         start.trend.condition = (start.trend.description!="" && AutoResume);
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = false;
         break;

      default: return(!catch("StartSequence(3)  unsupported start signal = "+ signal, ERR_INVALID_PARAMETER));
   }
   SS.StartStopConditions();

   sequence.level       = ifInt(sequence.direction==D_LONG, StartLevel, -StartLevel);
   sequence.maxLevel    = sequence.level;

   bool compoundProfits = false;
   if (IsTesting() && !compoundProfits) sequence.startEquity = tester.startEquity;
   else                                 sequence.startEquity = NormalizeDouble(AccountEquity()-AccountCredit(), 2);

   datetime startTime  = TimeCurrentEx("StartSequence(4)");
   double   startPrice = ifDouble(sequence.direction==D_SHORT, Bid, Ask);

   ArrayPushInt   (sequence.start.event,  CreateEventId());
   ArrayPushInt   (sequence.start.time,   startTime      );
   ArrayPushDouble(sequence.start.price,  startPrice     );
   ArrayPushDouble(sequence.start.profit, 0              );

   ArrayPushInt   (sequence.stop.event,   0);               // keep sizes of sequence.start/stop.* synchronous
   ArrayPushInt   (sequence.stop.time,    0);
   ArrayPushDouble(sequence.stop.price,   0);
   ArrayPushDouble(sequence.stop.profit,  0);

   // set the gridbase (event after sequence.start.time in time)
   double gridBase = NormalizeDouble(startPrice - sequence.level*GridSize*Pips, Digits);
   GridBase.Reset(startTime, gridBase);

   // open start positions if configured (and update sequence start price)
   if (sequence.level != 0) {
      if (!RestorePositions(startTime, startPrice)) return(false);
      sequence.start.price[ArraySize(sequence.start.price)-1] = startPrice;
   }
   sequence.status = STATUS_PROGRESSING;

   // open the next stop orders
   if (!UpdatePendingOrders()) return(false);

   if (!SaveSequence()) return(false);
   RedrawStartStop();

   if (__LOG()) log("StartSequence(5)  sequence "+ sequence.name +" started at "+ NumberToStr(startPrice, PriceFormat) + ifString(sequence.level, " and level "+ sequence.level, ""));

   // pause the tester according to the configuration
   if (IsTesting() && IsVisualMode()) {
      if      (tester.onSessionBreakPause && signal==SIGNAL_SESSIONBREAK) Tester.Pause();
      else if (tester.onTrendChangePause  && signal==SIGNAL_TREND)        Tester.Pause();
   }
   return(!catch("StartSequence(6)"));
}


/**
 * Close all open positions and delete pending orders. Stop the sequence and configure auto-resuming: If auto-resuming for a
 * trend condition is enabled the sequence is automatically resumed the next time the trend condition is fulfilled. If the
 * sequence is stopped due to a session break it is automatically resumed after the session break ends.
 *
 * @param  int signal - signal which triggered the stop condition or NULL if no condition was triggered (explicit stop)
 *
 * @return bool - success status
 */
bool StopSequence(int signal) {
   if (IsLastError())                                                          return(false);
   if (sequence.status!=STATUS_WAITING && sequence.status!=STATUS_PROGRESSING) return(!catch("StopSequence(1)  cannot stop "+ StatusDescription(sequence.status) +" sequence "+ sequence.name, ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("StopSequence()", "Do you really want to stop sequence "+ sequence.name +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   bool entryStatus = sequence.status;

   // a waiting sequence has no open orders (before first start or after stop)
   if (sequence.status == STATUS_WAITING) {
      sequence.status = STATUS_STOPPED;
      if (__LOG()) log("StopSequence(2)  sequence "+ sequence.name +" stopped");
   }

   // a progressing sequence has open orders to close
   else if (sequence.status == STATUS_PROGRESSING) {
      sequence.status = STATUS_STOPPING;
      if (__LOG()) log("StopSequence(3)  stopping sequence "+ sequence.name +" at level "+ sequence.level);

      // close open orders
      double stopPrice, slippage = 2;                                         // 2 pip
      int level, oeFlags, oes[][ORDER_EXECUTION.intSize];
      int pendingLimits[], openPositions[], sizeOfTickets = ArraySize(orders.ticket);
      ArrayResize(pendingLimits, 0);
      ArrayResize(openPositions, 0);

      // get all locally active orders (pending limits and open positions)
      for (int i=sizeOfTickets-1; i >= 0; i--) {
         if (!orders.closeTime[i]) {                                          // local: if (isOpen)
            level = orders.level[i];
            if (orders.ticket[i] < 0) {                                       // drop client-side managed pending orders
               if (!Grid.DropData(i)) return(false);
               sizeOfTickets--;
               ArrayAddInt(pendingLimits, -1);                                // decrease indexes of already stored limits
            }
            else {
               ArrayPushInt(pendingLimits, i);                                // pending entry or stop limit
               if (orders.type[i] != OP_UNDEFINED)
                  ArrayPushInt(openPositions, orders.ticket[i]);              // open position
            }
            if (Abs(level) == 1) break;
         }
      }

      // hedge open positions
      int sizeOfPositions = ArraySize(openPositions);
      if (sizeOfPositions > 0) {
         oeFlags = F_OE_DONT_CHECK_STATUS;                                    // skip status check to prevent errors
         int ticket = OrdersHedge(openPositions, slippage, oeFlags, oes); if (!ticket) return(!SetLastError(oes.Error(oes, 0)));
         ArrayPushInt(openPositions, ticket);
         sizeOfPositions++;
         stopPrice = oes.ClosePrice(oes, 0);
      }

      // delete all pending limits
      int sizeOfPendings = ArraySize(pendingLimits);
      for (i=0; i < sizeOfPendings; i++) {                                    // ordered by descending grid level
         if (orders.type[pendingLimits[i]] == OP_UNDEFINED) {
            int error = Grid.DeleteOrder(pendingLimits[i]);                   // removes the order from the order arrays
            if (!error) continue;
            if (error == -1) {                                                // entry stop is already executed
               if (!SelectTicket(orders.ticket[pendingLimits[i]], "StopSequence(4)")) return(false);
               orders.type      [pendingLimits[i]] = OrderType();
               orders.openEvent [pendingLimits[i]] = CreateEventId();
               orders.openTime  [pendingLimits[i]] = OrderOpenTime();
               orders.openPrice [pendingLimits[i]] = OrderOpenPrice();
               orders.swap      [pendingLimits[i]] = OrderSwap();
               orders.commission[pendingLimits[i]] = OrderCommission();
               orders.profit    [pendingLimits[i]] = OrderProfit();
               if (__LOG()) log("StopSequence(5)  "+ UpdateStatus.OrderFillMsg(pendingLimits[i]));
               if (IsStopOrderType(orders.pendingType[pendingLimits[i]])) {   // the next grid level was triggered
                  sequence.level   += Sign(orders.level[pendingLimits[i]]);
                  sequence.maxLevel = Sign(orders.level[pendingLimits[i]]) * Max(Abs(sequence.level), Abs(sequence.maxLevel));
               }
               else {                                                         // a previously missed grid level was triggered
                  ArrayDropInt(sequence.missedLevels, orders.level[pendingLimits[i]]);
                  SS.MissedLevels();
               }
               if (__LOG()) log("StopSequence(6)  sequence "+ sequence.name +" adding ticket #"+ OrderTicket() +" to open positions");
               ArrayPushInt(openPositions, OrderTicket());                    // add to open positions
               i--;                                                           // process the position's stoploss limit
            }
            else return(false);
         }
         else {
            error = Grid.DeleteLimit(pendingLimits[i]);
            if (!error) continue;
            if (error == -1) {                                                // stoploss is already executed
               if (!SelectTicket(orders.ticket[pendingLimits[i]], "StopSequence(7)")) return(false);
               orders.closeEvent[pendingLimits[i]] = CreateEventId();
               orders.closeTime [pendingLimits[i]] = OrderCloseTime();
               orders.closePrice[pendingLimits[i]] = OrderClosePrice();
               orders.closedBySL[pendingLimits[i]] = true;
               orders.swap      [pendingLimits[i]] = OrderSwap();
               orders.commission[pendingLimits[i]] = OrderCommission();
               orders.profit    [pendingLimits[i]] = OrderProfit();
               if (__LOG()) log("StopSequence(8)  "+ UpdateStatus.StopLossMsg(pendingLimits[i]));
               sequence.stops++;
               sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[pendingLimits[i]] + orders.commission[pendingLimits[i]] + orders.profit[pendingLimits[i]], 2); SS.Stops();
               ArrayDropInt(openPositions, OrderTicket());                    // remove from open positions
            }
            else return(false);
         }
      }

      // close open positions
      int pos;
      sizeOfPositions = ArraySize(openPositions);
      double remainingSwap, remainingCommission, remainingProfit;

      if (sizeOfPositions > 0) {
         if (!OrdersClose(openPositions, slippage, CLR_CLOSE, NULL, oes)) return(!SetLastError(oes.Error(oes, 0)));
         for (i=0; i < sizeOfPositions; i++) {
            pos = SearchIntArray(orders.ticket, openPositions[i]);
            if (pos != -1) {
               orders.closeEvent[pos] = CreateEventId();
               orders.closeTime [pos] = oes.CloseTime (oes, i);
               orders.closePrice[pos] = oes.ClosePrice(oes, i);
               orders.closedBySL[pos] = false;
               orders.swap      [pos] = oes.Swap      (oes, i);
               orders.commission[pos] = oes.Commission(oes, i);
               orders.profit    [pos] = oes.Profit    (oes, i);
            }
            else {
               remainingSwap       += oes.Swap      (oes, i);
               remainingCommission += oes.Commission(oes, i);
               remainingProfit     += oes.Profit    (oes, i);
            }
            sequence.closedPL = NormalizeDouble(sequence.closedPL + oes.Swap(oes, i) + oes.Commission(oes, i) + oes.Profit(oes, i), 2);
         }
         pos = ArraySize(orders.ticket)-1;                                    // the last ticket is always a closed position
         orders.swap      [pos] += remainingSwap;
         orders.commission[pos] += remainingCommission;
         orders.profit    [pos] += remainingProfit;
      }

      // update statistics and sequence status
      sequence.floatingPL = 0;
      sequence.totalPL    = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2); SS.TotalPL();
      if      (sequence.totalPL > sequence.maxProfit  ) { sequence.maxProfit   = sequence.totalPL; SS.MaxProfit();   }
      else if (sequence.totalPL < sequence.maxDrawdown) { sequence.maxDrawdown = sequence.totalPL; SS.MaxDrawdown(); }

      int n = ArraySize(sequence.stop.event) - 1;
      if (!stopPrice) stopPrice = ifDouble(sequence.direction==D_LONG, Bid, Ask);

      sequence.stop.event [n] = CreateEventId();
      sequence.stop.time  [n] = TimeCurrentEx("StopSequence(9)");
      sequence.stop.price [n] = stopPrice;
      sequence.stop.profit[n] = sequence.totalPL;
      RedrawStartStop();

      sequence.status = STATUS_STOPPED;
      if (__LOG()) log("StopSequence(10)  sequence "+ sequence.name +" stopped at "+ NumberToStr(stopPrice, PriceFormat) +", level "+ sequence.level);
      UpdateProfitTargets();
      ShowProfitTargets();
      SS.ProfitPerLevel();
   }

   // update start/stop conditions (sequence.status is STATUS_STOPPED)
   switch (signal) {
      case SIGNAL_SESSIONBREAK:
         sessionbreak.waiting = true;
         sequence.status      = STATUS_WAITING;
         break;

      case SIGNAL_TREND:
         if (start.trend.description!="" && AutoResume) {   // auto-resume if enabled and StartCondition is @trend
            start.conditions      = true;
            start.trend.condition = true;
            stop.trend.condition  = true;                   // stop condition is @trend
            sequence.status       = STATUS_WAITING;
         }
         else {
            stop.trend.condition = false;
         }
         break;

      case SIGNAL_PRICETIME:
         stop.price.condition = false;
         stop.time.condition  = false;
         if (start.trend.description!="" && AutoResume) {   // auto-resume if enabled, StartCondition is @trend and another
            start.conditions      = true;                   // stop condition is defined
            start.trend.condition = true;
            sequence.status       = STATUS_WAITING;
         }
         break;

      case SIGNAL_TP:
         stop.profitAbs.condition = false;
         stop.profitPct.condition = false;
         break;

      case NULL:                                            // explicit stop (manual or at end of test)
         if (entryStatus == STATUS_WAITING) {
            start.trend.condition = false;
            start.price.condition = false;
            start.time.condition  = false;
            start.conditions      = false;
            sessionbreak.waiting  = false;
         }
         break;

      default: return(!catch("StopSequence(11)  unsupported stop signal = "+ signal, ERR_INVALID_PARAMETER));
   }
   SS.StartStopConditions();
   SaveSequence();

   // reset the sequence and start a new cycle (using the same sequence id)
   if (signal==SIGNAL_TP && AutoRestart) {
      ResetSequence();
   }

   // pause/stop the tester according to the configuration
   if (IsTesting()) {
      if (IsVisualMode()) {
         if      (tester.onStopPause)                                        Tester.Pause();    // pause on any stop
         else if (tester.onSessionBreakPause && signal==SIGNAL_SESSIONBREAK) Tester.Pause();
         else if (tester.onTrendChangePause  && signal==SIGNAL_TREND)        Tester.Pause();
         else if (tester.onTakeProfitPause   && signal==SIGNAL_TP)           Tester.Pause();
      }
      else if (sequence.status == STATUS_STOPPED)                            Tester.Stop();
   }
   return(!catch("StopSequence(12)"));
}


/**
 * Reset a sequence to its initial state. Called if AutoRestart is enabled and the sequence was stopped due to a reached
 * profit target.
 *
 * @return bool - success status
 */
bool ResetSequence() {
   if (IsLastError())                   return(false);
   if (sequence.status!=STATUS_STOPPED) return(!catch("ResetSequence(1)  cannot reset "+ StatusDescription(sequence.status) +" sequence "+ sequence.name, ERR_ILLEGAL_STATE));
   if (!AutoRestart)                    return(!catch("ResetSequence(2)  cannot restart sequence "+ sequence.name +" (AutoRestart not enabled)", ERR_ILLEGAL_STATE));
   if (start.trend.description == "")   return(!catch("ResetSequence(3)  cannot restart sequence "+ sequence.name +" without a trend start condition", ERR_ILLEGAL_STATE));

   // memorize needed vars
   int    iCycle   = sequence.cycle;
   string sPL      = sSequenceTotalPL;
   string sPlStats = sSequencePlStats;

   // reset input parameters
   StartLevel = 0;

   // reset global vars
   if (true) {                                           // a block to just separate the code
      // --- sequence data ------------------
      //sequence.id           = ...                      // unchanged
      sequence.cycle++;                                  // increase restart cycle
      //sequence.name         = ...                      // unchanged
      //sequence.created      = ...                      // unchanged
      //sequence.isTest       = ...                      // unchanged
      //sequence.direction    = ...                      // unchanged
      sequence.status         = STATUS_UNDEFINED;
      sequence.level          = 0;
      sequence.maxLevel       = 0;
      ArrayResize(sequence.missedLevels, 0);
      //sequence.startEquity  = ...                      // kept           TODO: really?
      sequence.stops          = 0;
      sequence.stopsPL        = 0;
      sequence.closedPL       = 0;
      sequence.floatingPL     = 0;
      sequence.totalPL        = 0;
      sequence.maxProfit      = 0;
      sequence.maxDrawdown    = 0;
      sequence.profitPerLevel = 0;
      sequence.breakeven      = 0;
      //sequence.commission   = ...                      // kept

      ArrayResize(sequence.start.event,  0);
      ArrayResize(sequence.start.time,   0);
      ArrayResize(sequence.start.price,  0);
      ArrayResize(sequence.start.profit, 0);

      ArrayResize(sequence.stop.event,  0);
      ArrayResize(sequence.stop.time,   0);
      ArrayResize(sequence.stop.price,  0);
      ArrayResize(sequence.stop.profit, 0);

      // --- start conditions ---------------
      start.conditions           = true;
      start.trend.condition      = true;
      //start.trend.indicator    = ...                   // unchanged
      //start.trend.timeframe    = ...                   // unchanged
      //start.trend.params       = ...                   // unchanged
      //start.trend.description  = ...                   // unchanged

      start.price.condition      = false;
      start.price.type           = 0;
      start.price.value          = 0;
      start.price.lastValue      = 0;
      start.price.description    = "";

      start.time.condition       = false;
      start.time.value           = 0;
      start.time.description     = "";

      // --- stop conditions ----------------
      stop.trend.condition       = (stop.trend.description != "");
      stop.trend.indicator       = ifString(stop.trend.condition, stop.trend.indicator,   "");
      stop.trend.timeframe       = ifInt   (stop.trend.condition, stop.trend.timeframe,    0);
      stop.trend.params          = ifString(stop.trend.condition, stop.trend.params,      "");
      stop.trend.description     = ifString(stop.trend.condition, stop.trend.description, "");

      stop.price.condition       = false;
      stop.price.type            = 0;
      stop.price.value           = 0;
      stop.price.lastValue       = 0;
      stop.price.description     = "";

      stop.time.condition        = false;
      stop.time.value            = 0;
      stop.time.description      = "";

      stop.profitAbs.condition   = (stop.profitAbs.description != "");
      stop.profitAbs.value       = ifDouble(stop.profitAbs.condition, stop.profitAbs.value, 0);
      stop.profitAbs.description = ifString(stop.profitAbs.condition, stop.profitAbs.description, "");

      stop.profitPct.condition   = (stop.profitPct.description != "");
      stop.profitPct.value       = ifDouble(stop.profitPct.condition, stop.profitPct.value,          0);
      stop.profitPct.absValue    = ifDouble(stop.profitPct.condition, stop.profitPct.absValue, INT_MAX);
      stop.profitPct.description = ifString(stop.profitPct.condition, stop.profitPct.description,   "");

      // --- session break management -------
      sessionbreak.starttime     = 0;
      sessionbreak.endtime       = 0;
      sessionbreak.waiting       = false;

      // --- gridbase management ------------
      gridbase                   = 0;
      ArrayResize(gridbase.event, 0);
      ArrayResize(gridbase.time,  0);
      ArrayResize(gridbase.price, 0);

      // --- order data ---------------------
      ArrayResize(orders.ticket,          0);
      ArrayResize(orders.level,           0);
      ArrayResize(orders.gridBase,        0);
      ArrayResize(orders.pendingType,     0);
      ArrayResize(orders.pendingTime,     0);
      ArrayResize(orders.pendingPrice,    0);
      ArrayResize(orders.type,            0);
      ArrayResize(orders.openEvent,       0);
      ArrayResize(orders.openTime,        0);
      ArrayResize(orders.openPrice,       0);
      ArrayResize(orders.closeEvent,      0);
      ArrayResize(orders.closeTime,       0);
      ArrayResize(orders.closePrice,      0);
      ArrayResize(orders.stopLoss,        0);
      ArrayResize(orders.clientsideLimit, 0);
      ArrayResize(orders.closedBySL,      0);
      ArrayResize(orders.swap,            0);
      ArrayResize(orders.commission,      0);
      ArrayResize(orders.profit,          0);

      // --- other --------------------------
      ArrayResize(ignorePendingOrders,   0);
      ArrayResize(ignoreOpenPositions,   0);
      ArrayResize(ignoreClosedPositions, 0);

      //startStopDisplayMode       = ...                 // kept
      //orderDisplayMode           = ...                 // kept

      sLotSize                     = "";
      sGridBase                    = "";
      sSequenceDirection           = "";
      sSequenceMissedLevels        = "";
      sSequenceStops               = "";
      sSequenceStopsPL             = "";
      sSequenceTotalPL             = "";
      sSequenceMaxProfit           = "";
      sSequenceMaxDrawdown         = "";
      sSequenceProfitPerLevel      = "";
      sSequencePlStats             = "";
      sStartConditions             = "";
      sStopConditions              = "";
      sAutoResume                  = "";
      sRestartStats                = NL +" "+ iCycle +":  "+ sPL + sPlStats + sRestartStats;

      // --- debug settings -----------------
      //tester.onTrendChangePause  = ...                 // unchanged
      //tester.onSessionBreakPause = ...                 // unchanged
      //tester.onTakeProfitPause   = ...                 // unchanged
      //tester.onStopPause         = ...                 // unchanged
      //tester.reduceStatusWrites  = ...                 // unchanged
   }

   sequence.status = STATUS_WAITING;
   SS.All();
   SaveSequence();

   if (__LOG()) log("ResetSequence(4)  sequence "+ sequence.name +" reset, waiting for start condition");
   return(!catch("ResetSequence(5)"));
}


/**
 * Add a value to all elements of an integer array.
 *
 * @param  _InOut_ int &array[]
 * @param  _In_    int  value
 *
 * @return bool - success status
 */
bool ArrayAddInt(int &array[], int value) {
   int size = ArraySize(array);
   for (int i=0; i < size; i++) {
      array[i] += value;
   }
   return(!catch("ArrayAddInt(1)"));
}


/**
 * Resume a waiting or stopped trade sequence.
 *
 * @param  int signal - signal which triggered a resume condition or NULL if no condition was triggered (explicit resume)
 *
 * @return bool - success status
 */
bool ResumeSequence(int signal) {
   if (IsLastError())                                                      return(false);
   if (sequence.status!=STATUS_WAITING && sequence.status!=STATUS_STOPPED) return(!catch("ResumeSequence(1)  cannot resume "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("ResumeSequence()", "Do you really want to resume sequence "+ sequence.name +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   datetime startTime;
   double   gridBase, startPrice, lastStopPrice = sequence.stop.price[ArraySize(sequence.stop.price)-1];

   sequence.status = STATUS_STARTING;
   if (__LOG()) log("ResumeSequence(2)  resuming sequence "+ sequence.name +" at level "+ sequence.level +" (stopped at "+ NumberToStr(lastStopPrice, PriceFormat) +", gridbase "+ NumberToStr(gridbase, PriceFormat) +")");

   // update start/stop conditions
   switch (signal) {
      case SIGNAL_SESSIONBREAK:
         sessionbreak.waiting = false;
         break;

      case SIGNAL_TREND:
         start.trend.condition = AutoResume;
         start.conditions      = false;
         break;

      case SIGNAL_PRICETIME:
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = false;
         break;

      case NULL:                                               // manual resume
         sessionbreak.waiting  = false;
         start.trend.condition = (start.trend.description!="" && AutoResume);
         start.price.condition = false;
         start.time.condition  = false;
         start.conditions      = false;
         break;

      default: return(!catch("ResumeSequence(3)  unsupported start signal = "+ signal, ERR_INVALID_PARAMETER));
   }
   SS.StartStopConditions();

   // check for existing positions (after a former error some levels may already be open)
   if (sequence.level > 0) {
      for (int level=1; level <= sequence.level; level++) {
         int i = Grid.FindOpenPosition(level);
         if (i != -1) {
            gridBase = orders.gridBase[i];                     // get the previously used gridbase
            break;
         }
      }
   }
   else if (sequence.level < 0) {
      for (level=-1; level >= sequence.level; level--) {
         i = Grid.FindOpenPosition(level);
         if (i != -1) {
            gridBase = orders.gridBase[i];
            break;
         }
      }
   }

   if (!gridBase) {
      // define the new gridbase if no open positions have been found
      startTime  = TimeCurrentEx("ResumeSequence(4)");
      startPrice = ifDouble(sequence.direction==D_SHORT, Bid, Ask);
      GridBase.Change(startTime, gridbase + startPrice - lastStopPrice);
   }
   else {
      gridbase = NormalizeDouble(gridBase, Digits);            // re-use the previously used gridbase
   }

   // open the previously active Positionen and receive last(OrderOpenTime) and avg(OrderOpenPrice)
   if (!RestorePositions(startTime, startPrice)) return(false);

   // store new sequence start
   ArrayPushInt   (sequence.start.event,  CreateEventId() );
   ArrayPushInt   (sequence.start.time,   startTime       );
   ArrayPushDouble(sequence.start.price,  startPrice      );
   ArrayPushDouble(sequence.start.profit, sequence.totalPL);   // same as at the last stop

   ArrayPushInt   (sequence.stop.event,  0);                   // keep sequence.starts/stops synchronous
   ArrayPushInt   (sequence.stop.time,   0);
   ArrayPushDouble(sequence.stop.price,  0);
   ArrayPushDouble(sequence.stop.profit, 0);

   sequence.status = STATUS_PROGRESSING;                       // TODO: correct the resulting gridbase and adjust the previously set stoplosses

   // update stop orders
   if (!UpdatePendingOrders()) return(false);

   // update and store status
   bool changes;
   int  iNull[];                                               // If RestorePositions() encountered a magic ticket #-2 (spread violation)
   if (!UpdateStatus(changes, iNull)) return(false);           // UpdateStatus() closes it with PL=0.00 and decreases the grid level.
   if (changes) UpdatePendingOrders();                         // In this case pending orders need to be updated again.
   if (!SaveSequence()) return(false);
   RedrawStartStop();

   if (__LOG()) log("ResumeSequence(5)  sequence "+ sequence.name +" resumed at level "+ sequence.level +" (start price "+ NumberToStr(startPrice, PriceFormat) +", new gridbase "+ NumberToStr(gridbase, PriceFormat) +")");

   // pause the tester according to the configuration
   if (IsTesting() && IsVisualMode()) {
      if      (tester.onSessionBreakPause && signal==SIGNAL_SESSIONBREAK) Tester.Pause();
      else if (tester.onTrendChangePause  && signal==SIGNAL_TREND)        Tester.Pause();
   }
   return(!catch("ResumeSequence(6)"));
}


/**
 * Restore open positions and limit orders for missed sequence levels. Called from StartSequence() and ResumeSequence().
 *
 * @param  datetime &lpOpenTime  - variable receiving the OpenTime of the last opened position
 * @param  double   &lpOpenPrice - variable receiving the average OpenPrice of all open positions
 *
 * @return bool - success status
 *
 * Note: If the sequence is at level 0 the passed variables are not modified.
 */
bool RestorePositions(datetime &lpOpenTime, double &lpOpenPrice) {
   if (IsLastError())                      return(false);
   if (sequence.status != STATUS_STARTING) return(!catch("RestorePositions(1)  cannot restore positions of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int i, level, missedLevels=ArraySize(sequence.missedLevels);
   bool isMissedLevel, success;
   datetime openTime;
   double openPrice;

   // Long
   if (sequence.level > 0) {
      for (level=1; level <= sequence.level; level++) {
         isMissedLevel = IntInArray(sequence.missedLevels, level);
         i = Grid.FindOpenPosition(level);
         if (i == -1) {
            if (isMissedLevel) success = Grid.AddPendingOrder(level);
            else               success = Grid.AddPosition(level);
            if (!success) return(false);
            i = ArraySize(orders.ticket) - 1;
         }
         else {
            // TODO: check/update the stoploss
         }
         if (!isMissedLevel) {
            openTime   = Max(openTime, orders.openTime[i]);
            openPrice += orders.openPrice[i];
         }
      }
      openPrice /= (Abs(sequence.level)-missedLevels);                  // avg(OpenPrice)
   }

   // Short
   else if (sequence.level < 0) {
      for (level=-1; level >= sequence.level; level--) {
         isMissedLevel = IntInArray(sequence.missedLevels, level);
         i = Grid.FindOpenPosition(level);
         if (i == -1) {
            if (isMissedLevel) success = Grid.AddPendingOrder(level);
            else               success = Grid.AddPosition(level);
            if (!success) return(false);
            i = ArraySize(orders.ticket) - 1;
         }
         else {
            // TODO: check/update the stoploss
         }
         if (!isMissedLevel) {
            openTime   = Max(openTime, orders.openTime[i]);
            openPrice += orders.openPrice[i];
         }
      }
      openPrice /= (Abs(sequence.level)-missedLevels);                  // avg(OpenPrice)
   }

   // write-back results to the passed variables
   if (openTime != 0) {                                                 // sequence.level != 0
      lpOpenTime  = openTime;
      lpOpenPrice = NormalizeDouble(openPrice, Digits);
   }
   return(!catch("RestorePositions(2)"));
}


/**
 * Pr�ft und synchronisiert die im EA gespeicherten mit den aktuellen Laufzeitdaten.
 *
 * @param  _Out_ bool &gridChanged       - variable indicating whether the current gridbase or level changed
 * @param  _Out_ int   activatedOrders[] - array receiving the order indexes of activated client-side stops/limits
 *
 * @return bool - success status
 */
bool UpdateStatus(bool &gridChanged, int activatedOrders[]) {
   gridChanged = gridChanged!=0;
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdateStatus(1)  cannot update order status of "+ StatusDescription(sequence.status) +" sequence "+ sequence.name, ERR_ILLEGAL_STATE));

   ArrayResize(activatedOrders, 0);
   bool wasPending, isClosed, openPositions;
   int  closed[][2], close[2], sizeOfTickets=ArraySize(orders.ticket); ArrayResize(closed, 0);
   sequence.floatingPL = 0;

   // Tickets aktualisieren
   for (int i=0; i < sizeOfTickets; i++) {
      if (!orders.closeTime[i]) {                                                   // Ticket pr�fen, wenn es beim letzten Aufruf offen war
         wasPending = (orders.type[i] == OP_UNDEFINED);

         // client-seitige PendingOrders pr�fen
         if (wasPending) /*&&*/ if (orders.ticket[i] == -1) {
            if (IsStopTriggered(orders.pendingType[i], orders.pendingPrice[i])) {   // handles stop and limit orders
               if (__LOG()) log("UpdateStatus(2)  "+ UpdateStatus.StopTriggerMsg(i));
               ArrayPushInt(activatedOrders, i);
            }
            continue;
         }

         // Magic-Ticket #-2 pr�fen (wird sofort hier "geschlossen")
         if (orders.ticket[i] == -2) {
            orders.closeEvent[i] = CreateEventId();                                 // Event-ID kann sofort vergeben werden.
            orders.closeTime [i] = TimeCurrentEx("UpdateStatus(3)");
            orders.closePrice[i] = orders.openPrice[i];
            orders.closedBySL[i] = true;
            Chart.MarkPositionClosed(i);
            if (__LOG()) log("UpdateStatus(4)  "+ UpdateStatus.StopLossMsg(i));

            sequence.level  -= Sign(orders.level[i]);
            sequence.stops++; SS.Stops();
          //sequence.stopsPL = ...                                                  // unver�ndert, da P/L des Magic-Tickets #-2 immer 0.00 ist
            gridChanged      = true;
            continue;
         }

         // regul�re server-seitige Tickets
         if (!SelectTicket(orders.ticket[i], "UpdateStatus(5)")) return(false);

         if (wasPending) {
            // beim letzten Aufruf Pending-Order
            if (OrderType() != orders.pendingType[i]) {                             // order limit was executed
               orders.type      [i] = OrderType();
               orders.openEvent [i] = CreateEventId();
               orders.openTime  [i] = OrderOpenTime();
               orders.openPrice [i] = OrderOpenPrice();
               orders.swap      [i] = OrderSwap();
               orders.commission[i] = OrderCommission(); sequence.commission = OrderCommission(); SS.LotSize();
               orders.profit    [i] = OrderProfit();
               Chart.MarkOrderFilled(i);
               if (__LOG()) log("UpdateStatus(6)  "+ UpdateStatus.OrderFillMsg(i));

               if (IsStopOrderType(orders.pendingType[i])) {
                  sequence.level   += Sign(orders.level[i]);
                  sequence.maxLevel = Sign(orders.level[i]) * Max(Abs(sequence.level), Abs(sequence.maxLevel));
                  gridChanged       = true;
               }
               else {
                  ArrayDropInt(sequence.missedLevels, orders.level[i]);             // update missed grid levels
                  SS.MissedLevels();
               }
            }
         }
         else {
            // beim letzten Aufruf offene Position
            orders.swap      [i] = OrderSwap();
            orders.commission[i] = OrderCommission();
            orders.profit    [i] = OrderProfit();
         }

         isClosed = OrderCloseTime() != 0;                                          // Bei Spikes kann eine Pending-Order ausgef�hrt *und* bereits geschlossen sein.
         if (!isClosed) {                                                           // weiterhin offenes Ticket
            if (orders.type[i] != OP_UNDEFINED) {
               openPositions = true;
               if (orders.clientsideLimit[i]) /*&&*/ if (IsStopTriggered(orders.type[i], orders.stopLoss[i])) {
                  if (__LOG()) log("UpdateStatus(7)  "+ UpdateStatus.StopTriggerMsg(i));
                  ArrayPushInt(activatedOrders, i);
               }
            }
            sequence.floatingPL = NormalizeDouble(sequence.floatingPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
         }
         else if (orders.type[i] == OP_UNDEFINED) {                                 // jetzt geschlossenes Ticket: gestrichene Pending-Order
            Grid.DropData(i);
            sizeOfTickets--; i--;
         }
         else {
            orders.closeTime [i] = OrderCloseTime();                                // jetzt geschlossenes Ticket: geschlossene Position
            orders.closePrice[i] = OrderClosePrice();
            orders.closedBySL[i] = IsOrderClosedBySL();
            Chart.MarkPositionClosed(i);

            if (orders.closedBySL[i]) {                                             // ausgestoppt
               orders.closeEvent[i] = CreateEventId();                              // Event-ID kann sofort vergeben werden.
               if (__LOG()) log("UpdateStatus(8)  "+ UpdateStatus.StopLossMsg(i));
               sequence.level  -= Sign(orders.level[i]);
               sequence.stops++;
               sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2); SS.Stops();
               gridChanged      = true;
            }
            else {                                                                  // manually closed or automatically closed at test end
               close[0] = OrderCloseTime();
               close[1] = OrderTicket();                                            // Geschlossene Positionen werden zwischengespeichert, um ihnen Event-IDs
               ArrayPushInts(closed, close);                                        // zeitlich *nach* den ausgestoppten Positionen zuweisen zu k�nnen.
               if (__LOG()) log("UpdateStatus(9)  "+ UpdateStatus.PositionCloseMsg(i));
               sequence.closedPL = NormalizeDouble(sequence.closedPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
            }
         }
      }
   }

   // Event-IDs geschlossener Positionen setzen (zeitlich nach allen ausgestoppten Positionen)
   int sizeOfClosed = ArrayRange(closed, 0);
   if (sizeOfClosed > 0) {
      ArraySort(closed);
      for (i=0; i < sizeOfClosed; i++) {
         int n = SearchIntArray(orders.ticket, closed[i][1]);
         if (n == -1) return(!catch("UpdateStatus(10)  closed ticket #"+ closed[i][1] +" not found in order arrays", ERR_ILLEGAL_STATE));
         orders.closeEvent[n] = CreateEventId();
      }
      ArrayResize(closed, 0);
   }

   // update PL numbers
   sequence.totalPL = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2); SS.TotalPL();
   if      (sequence.totalPL > sequence.maxProfit  ) { sequence.maxProfit   = sequence.totalPL; SS.MaxProfit();   }
   else if (sequence.totalPL < sequence.maxDrawdown) { sequence.maxDrawdown = sequence.totalPL; SS.MaxDrawdown(); }

   // trail gridbase
   if (!sequence.level) {
      if (!sizeOfTickets) {                                                   // the pending order was manually cancelled
         SetLastError(ERR_CANCELLED_BY_USER);
      }
      else {
         double last = gridbase;
         if (sequence.direction == D_LONG) gridbase = MathMin(gridbase, NormalizeDouble((Bid + Ask)/2, Digits));
         else                              gridbase = MathMax(gridbase, NormalizeDouble((Bid + Ask)/2, Digits));

         if (NE(gridbase, last, Digits)) {
            GridBase.Change(TimeCurrentEx("UpdateStatus(11)"), gridbase);
            gridChanged = true;
         }
         else if (NE(orders.gridBase[sizeOfTickets-1], gridbase, Digits)) {   // Gridbasis des letzten Tickets inspizieren, da Trailing online
            gridChanged = true;                                               // u.U. verz�gert wird
         }
      }
   }

   return(!catch("UpdateStatus(12)"));
}


/**
 * Compose a log message for a filled entry order.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.OrderFillMsg(int i) {
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was filled[ at 1.5457'2 (0.3 pip [positive ]slippage)]
   string sType         = OperationTypeDescription(orders.pendingType[i]);
   string sPendingPrice = NumberToStr(orders.pendingPrice[i], PriceFormat);
   string comment       = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message       = "#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(LotSize, ".+") +" "+ Symbol() +" at "+ sPendingPrice +" (\""+ comment +"\") was filled";

   if (NE(orders.pendingPrice[i], orders.openPrice[i])) {
      double slippage = (orders.openPrice[i] - orders.pendingPrice[i])/Pip;
         if (orders.type[i] == OP_SELL)
            slippage = -slippage;
      string sSlippage;
      if (slippage > 0) sSlippage = DoubleToStr(slippage, Digits & 1) +" pip slippage";
      else              sSlippage = DoubleToStr(-slippage, Digits & 1) +" pip positive slippage";
      message = message +" at "+ NumberToStr(orders.openPrice[i], PriceFormat) +" ("+ sSlippage +")";
   }
   return(message);
}


/**
 * Compose a log message for a closed position.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.PositionCloseMsg(int i) {
   // #1 Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17") was closed at 1.5457'2
   string sType       = OperationTypeDescription(orders.type[i]);
   string sOpenPrice  = NumberToStr(orders.openPrice[i], PriceFormat);
   string sClosePrice = NumberToStr(orders.closePrice[i], PriceFormat);
   string comment     = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message     = "#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(LotSize, ".+") +" "+ Symbol() +" at "+ sOpenPrice +" (\""+ comment +"\") was closed at "+ sClosePrice;

   return(message);
}


/**
 * Compose a log message for an executed stoploss.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.StopLossMsg(int i) {
   // [magic ticket ]#1 Sell 0.1 GBPUSD at 1.5457'2 ("SR.8692.+17"), [client-side ]stoploss 1.5457'2 was executed[ at 1.5457'2 (0.3 pip [positive ]slippage)]
   string sMagic     = ifString(orders.ticket[i]==-2, "magic ticket ", "");
   string sType      = OperationTypeDescription(orders.type[i]);
   string sOpenPrice = NumberToStr(orders.openPrice[i], PriceFormat);
   string sStopSide  = ifString(orders.clientsideLimit[i], "client-side ", "");
   string sStopLoss  = NumberToStr(orders.stopLoss[i], PriceFormat);
   string comment    = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   string message    = sMagic +"#"+ orders.ticket[i] +" "+ sType +" "+ NumberToStr(LotSize, ".+") +" "+ Symbol() +" at "+ sOpenPrice +" (\""+ comment +"\"), "+ sStopSide +"stoploss "+ sStopLoss +" was executed";

   if (NE(orders.closePrice[i], orders.stopLoss[i])) {
      double slippage = (orders.stopLoss[i] - orders.closePrice[i])/Pip;
         if (orders.type[i] == OP_SELL)
            slippage = -slippage;
      string sSlippage;
      if (slippage > 0) sSlippage = DoubleToStr(slippage, Digits & 1) +" pip slippage";
      else              sSlippage = DoubleToStr(-slippage, Digits & 1) +" pip positive slippage";
      message = message +" at "+ NumberToStr(orders.closePrice[i], PriceFormat) +" ("+ sSlippage +")";
   }
   return(message);
}


/**
 * Compose a log message for a triggered client-side stop or limit.
 *
 * @param  int i - order index
 *
 * @return string
 */
string UpdateStatus.StopTriggerMsg(int i) {
   string sSequence = sequence.name +"."+ NumberToStr(orders.level[i], "+.");

   if (orders.type[i] == OP_UNDEFINED) {
      // sequence L.8692.+17 client-side Stop Buy at 1.5457'2 was triggered
      return("sequence "+ sSequence +" client-side "+ OperationTypeDescription(orders.pendingType[i]) +" at "+ NumberToStr(orders.pendingPrice[i], PriceFormat) +" was triggered");
   }
   else {
      // sequence L.8692.+17 #1 client-side stoploss at 1.5457'2 was triggered
      return("sequence "+ sSequence +" #"+ orders.ticket[i] +" client-side stoploss at "+ NumberToStr(orders.stopLoss[i], PriceFormat) +" was triggered");
   }
}


/**
 * Whether a chart command was sent to the expert. If so, the command is retrieved and stored.
 *
 * @param  string commands[] - array to store received commands in
 *
 * @return bool
 */
bool EventListener_ChartCommand(string &commands[]) {
   if (!__CHART()) return(false);

   static string label, mutex; if (!StringLen(label)) {
      label = __NAME() +".command";
      mutex = "mutex."+ label;
   }

   // check non-synchronized (read-only) for a command to prevent aquiring the lock on each tick
   if (ObjectFind(label) == 0) {
      // aquire the lock for write-access if there's indeed a command
      if (!AquireLock(mutex, true)) return(false);

      ArrayPushString(commands, ObjectDescription(label));
      ObjectDelete(label);
      return(ReleaseLock(mutex));
   }
   return(false);
}


/**
 * Ob die aktuell selektierte Order durch den StopLoss geschlossen wurde (client- oder server-seitig).
 *
 * @return bool
 */
bool IsOrderClosedBySL() {
   bool position   = OrderType()==OP_BUY || OrderType()==OP_SELL;
   bool closed     = OrderCloseTime() != 0;                          // geschlossene Position
   bool closedBySL = false;

   if (closed) /*&&*/ if (position) {
      if (StrEndsWithI(OrderComment(), "[sl]")) {
         closedBySL = true;
      }
      else {
         // StopLoss aus Orderdaten verwenden (ist bei client-seitiger Verwaltung nur dort gespeichert)
         int i = SearchIntArray(orders.ticket, OrderTicket());

         if (i == -1)             return(!catch("IsOrderClosedBySL(1)  closed position #"+ OrderTicket() +" not found in order arrays", ERR_ILLEGAL_STATE));
         if (!orders.stopLoss[i]) return(!catch("IsOrderClosedBySL(2)  cannot resolve status of position #"+ OrderTicket() +" (closed but has neither local nor remote SL attached)", ERR_ILLEGAL_STATE));

         if      (orders.closedBySL[i])   closedBySL = true;
         else if (OrderType() == OP_BUY ) closedBySL = LE(OrderClosePrice(), orders.stopLoss[i]);
         else if (OrderType() == OP_SELL) closedBySL = GE(OrderClosePrice(), orders.stopLoss[i]);
      }
   }
   return(closedBySL);
}


/**
 * Whether a start or resume condition is satisfied for a waiting sequence. Price and time conditions are AND combined.
 *
 * @return int - the signal identifier of the fulfilled start condition or NULL if no start condition is satisfied
 */
int IsStartSignal() {
   if (last_error || sequence.status!=STATUS_WAITING) return(NULL);
   string message;
   bool triggered, resuming = (sequence.maxLevel != 0);

   // -- sessionbreak: wait for the stop price to be reached ----------------------------------------------------------------
   if (sessionbreak.waiting) {
      double price = sequence.stop.price[ArraySize(sequence.stop.price)-1];
      if (sequence.direction == D_LONG) triggered = (Ask <= price);
      else                              triggered = (Bid >= price);
      if (triggered) {
         if (__LOG()) log("IsStartSignal(1)  sequence "+ sequence.name +" resume condition \"@sessionbreak price "+ NumberToStr(price, PriceFormat) +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "ask", "bid") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Ask, Bid), PriceFormat) +")");
         return(SIGNAL_SESSIONBREAK);
      }
      return(NULL);                       // temporarily ignore all other conditions
   }

   if (start.conditions) {
      // -- start.trend: bei Trendwechsel in Richtung der Sequenz erf�llt ---------------------------------------------------
      if (start.trend.condition) {
         if (IsBarOpenEvent(start.trend.timeframe)) {
            int trend = GetStartTrendValue(1);

            if ((sequence.direction==D_LONG && trend==1) || (sequence.direction==D_SHORT && trend==-1)) {
               message = "IsStartSignal(2)  sequence "+ sequence.name +" "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.trend.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
               if (!IsTesting()) warn(message);
               else if (__LOG()) log(message);
               return(SIGNAL_TREND);
            }
         }
         return(NULL);
      }

      // -- start.price: erf�llt, wenn der aktuelle Preis den Wert ber�hrt oder kreuzt --------------------------------------
      if (start.price.condition) {
         triggered = false;
         switch (start.price.type) {
            case PRICE_BID:    price =  Bid;        break;
            case PRICE_ASK:    price =  Ask;        break;
            case PRICE_MEDIAN: price = (Bid+Ask)/2; break;
         }
         if (start.price.lastValue != 0) {
            if (start.price.lastValue < start.price.value) triggered = (price >= start.price.value);  // price crossed upwards
            else                                           triggered = (price <= start.price.value);  // price crossed downwards
         }
         start.price.lastValue = price;
         if (!triggered) return(NULL);

         message = "IsStartSignal(3)  sequence "+ sequence.name +" "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.price.description +"\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
      }

      // -- start.time: zum angegebenen Zeitpunkt oder danach erf�llt -------------------------------------------------------
      if (start.time.condition) {
         if (TimeCurrentEx("IsStartSignal(4)") < start.time.value)
            return(NULL);

         message = "IsStartSignal(5)  sequence "+ sequence.name +" "+ ifString(!resuming, "start", "resume") +" condition \"@"+ start.time.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
      }

      // -- both price and time conditions are fullfilled (AND combined) ----------------------------------------------------
      return(SIGNAL_PRICETIME);
   }

   // no start condition is a valid start signal before first sequence start only
   if (!ArraySize(sequence.start.event)) {
      return(SIGNAL_PRICETIME);                    // a manual start implies a fulfilled price/time condition
   }

   return(NULL);
}


/**
 * Whether a stop condition is satisfied for a progressing sequence. All stop conditions are OR combined.
 *
 * @return int - the signal identifier of the fulfilled stop condition or NULL if no stop condition is satisfied
 */
int IsStopSignal() {
   if (last_error || sequence.status!=STATUS_PROGRESSING) return(NULL);
   string message;

   // -- stop.trend: bei Trendwechsel entgegen der Richtung der Sequenz erf�llt ---------------------------------------------
   if (stop.trend.condition) {
      if (IsBarOpenEvent(stop.trend.timeframe)) {
         int trend = GetStopTrendValue(1);

         if ((sequence.direction==D_LONG && trend==-1) || (sequence.direction==D_SHORT && trend==1)) {
            message = "IsStopSignal(1)  sequence "+ sequence.name +" stop condition \"@"+ stop.trend.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
            if (!IsTesting()) warn(message);
            else if (__LOG()) log(message);
            return(SIGNAL_TREND);
         }
      }
   }

   // -- stop.price: erf�llt, wenn der aktuelle Preis den Wert ber�hrt oder kreuzt ------------------------------------------
   if (stop.price.condition) {
      bool triggered = false;
      double price;
      switch (stop.price.type) {
         case PRICE_BID:    price =  Bid;        break;
         case PRICE_ASK:    price =  Ask;        break;
         case PRICE_MEDIAN: price = (Bid+Ask)/2; break;
      }
      if (stop.price.lastValue != 0) {
         if (stop.price.lastValue < stop.price.value) triggered = (price >= stop.price.value);  // price crossed upwards
         else                                         triggered = (price <= stop.price.value);  // price crossed downwards
      }
      stop.price.lastValue = price;

      if (triggered) {
         message = "IsStopSignal(2)  sequence "+ sequence.name +" stop condition \"@"+ stop.price.description +"\" fulfilled";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         stop.price.condition = false;
         return(SIGNAL_PRICETIME);
      }
   }

   // -- stop.time: zum angegebenen Zeitpunkt oder danach erf�llt -----------------------------------------------------------
   if (stop.time.condition) {
      if (TimeCurrentEx("IsStopSignal(3)") >= stop.time.value) {
         message = "IsStopSignal(4)  sequence "+ sequence.name +" stop condition \"@"+ stop.time.description +"\" fulfilled (market: "+ NumberToStr((Bid+Ask)/2, PriceFormat) +")";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         stop.time.condition = false;
         return(SIGNAL_PRICETIME);
      }
   }

   // -- stop.profitAbs: ----------------------------------------------------------------------------------------------------
   if (stop.profitAbs.condition) {
      if (sequence.totalPL >= stop.profitAbs.value) {
         message = "IsStopSignal(5)  sequence "+ sequence.name +" stop condition \"@"+ stop.profitAbs.description +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         stop.profitAbs.condition = false;
         return(SIGNAL_TP);
      }
   }

   // -- stop.profitPct: ----------------------------------------------------------------------------------------------------
   if (stop.profitPct.condition) {
      if (stop.profitPct.absValue == INT_MAX) {
         stop.profitPct.absValue = stop.profitPct.value/100 * sequence.startEquity;
      }
      if (sequence.totalPL >= stop.profitPct.absValue) {
         message = "IsStopSignal(6)  sequence "+ sequence.name +" stop condition \"@"+ stop.profitPct.description +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
         if (!IsTesting()) warn(message);
         else if (__LOG()) log(message);
         stop.profitPct.condition = false;
         return(SIGNAL_TP);
      }
   }

   // -- session break ------------------------------------------------------------------------------------------------------
   if (IsSessionBreak()) {
      message = "IsStopSignal(7)  sequence "+ sequence.name +" stop condition \"sessionbreak from "+ GmtTimeFormat(sessionbreak.starttime, "%Y.%m.%d %H:%M:%S") +" to "+ GmtTimeFormat(sessionbreak.endtime, "%Y.%m.%d %H:%M:%S") +"\" fulfilled ("+ ifString(sequence.direction==D_LONG, "bid", "ask") +": "+ NumberToStr(ifDouble(sequence.direction==D_LONG, Bid, Ask), PriceFormat) +")";
      if (__LOG()) log(message);
      return(SIGNAL_SESSIONBREAK);
   }

   return(NULL);
}


/**
 * Whether the current server time falls into a sessionbreak. After function return the global vars sessionbreak.starttime
 * and sessionbreak.endtime are up-to-date (sessionbreak.active is not modified).
 *
 * @return bool
 */
bool IsSessionBreak() {
   if (IsLastError()) return(false);

   datetime serverTime = TimeServer();
   if (!serverTime) return(false);

   // check whether to recalculate sessionbreak times
   if (serverTime >= sessionbreak.endtime) {
      int startOffset = Sessionbreak.StartTime % DAYS;            // sessionbreak start time in seconds since Midnight
      int endOffset   = Sessionbreak.EndTime % DAYS;              // sessionbreak end time in seconds since Midnight
      if (!startOffset && !endOffset)
         return(false);                                           // skip session breaks if both values are set to Midnight

      // calculate today's sessionbreak end time
      datetime fxtNow  = ServerToFxtTime(serverTime);
      datetime today   = fxtNow - fxtNow%DAYS;                    // today's Midnight in FXT
      datetime fxtTime = today + endOffset;                       // today's sessionbreak end time in FXT

      // determine the next regular sessionbreak end time
      int dow = TimeDayOfWeekFix(fxtTime);
      while (fxtTime <= fxtNow || dow==SATURDAY || dow==SUNDAY) {
         fxtTime += 1*DAY;
         dow = TimeDayOfWeekFix(fxtTime);
      }
      datetime fxtResumeTime = fxtTime;
      sessionbreak.endtime = FxtToServerTime(fxtResumeTime);

      // determine the corresponding sessionbreak start time
      datetime resumeDay = fxtResumeTime - fxtResumeTime%DAYS;    // resume day's Midnight in FXT
      fxtTime = resumeDay + startOffset;                          // resume day's sessionbreak start time in FXT

      dow = TimeDayOfWeekFix(fxtTime);
      while (fxtTime >= fxtResumeTime || dow==SATURDAY || dow==SUNDAY) {
         fxtTime -= 1*DAY;
         dow = TimeDayOfWeekFix(fxtTime);
      }
      sessionbreak.starttime = FxtToServerTime(fxtTime);

      if (__LOG()) log("IsSessionBreak(1)  recalculated next sessionbreak: from "+ GmtTimeFormat(sessionbreak.starttime, "%a, %Y.%m.%d %H:%M:%S") +" to "+ GmtTimeFormat(sessionbreak.endtime, "%a, %Y.%m.%d %H:%M:%S"));
   }

   // perform the actual check
   return(serverTime >= sessionbreak.starttime);                  // here sessionbreak.endtime is always in the future
}


/**
 * Execute orders with activated client-side stops or limits. Called only from onTick().
 *
 * @param  int orders[] - indexes of orders with activated stops or limits
 *
 * @return bool - success status
 */
bool ExecuteOrders(int orders[]) {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("ExecuteOrders(1)  cannot execute client-side orders of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int sizeOfOrders = ArraySize(orders);
   if (!sizeOfOrders) return(true);

   int button, ticket;
   int oe[];

   // Der Stop kann eine getriggerte Entry-Order oder ein getriggerter StopLoss sein.
   for (int i, n=0; n < sizeOfOrders; n++) {
      i = orders[n];
      if (i >= ArraySize(orders.ticket))     return(!catch("ExecuteOrders(2)  illegal order index "+ i +" in parameter orders = "+ IntsToStr(orders, NULL), ERR_INVALID_PARAMETER));

      // if getriggerte Entry-Order
      if (orders.ticket[i] == -1) {
         if (orders.type[i] != OP_UNDEFINED) return(!catch("ExecuteOrders(3)  "+ OperationTypeDescription(orders.pendingType[i]) +" order at index "+ i +" is already marked as open", ERR_ILLEGAL_STATE));

         if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("ExecuteOrders()", "Do you really want to execute a triggered client-side "+ OperationTypeDescription(orders.pendingType[i]) +" order now?"))
            return(!SetLastError(ERR_CANCELLED_BY_USER));

         int type  = orders.pendingType[i] % 2;
         int level = orders.level[i];
         bool clientSL = false;                                               // zuerst versuchen, server-seitigen StopLoss zu setzen...

         ticket = SubmitMarketOrder(type, level, clientSL, oe);

         // ab dem letzten Level ggf. client-seitige Stop-Verwaltung
         orders.clientsideLimit[i] = (ticket <= 0);

         if (ticket <= 0) {
            if (level != sequence.level)          return(false);
            if (oe.Error(oe) != ERR_INVALID_STOP) return(false);
            // if market violated
            if (ticket == -1) {
               return(!catch("ExecuteOrders(4)  sequence "+ sequence.name +"."+ NumberToStr(level, "+.") +" spread violated ("+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +") by "+ OperationTypeDescription(type) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +", sl="+ NumberToStr(oe.StopLoss(oe), PriceFormat), oe.Error(oe)));
            }
            // if stop distance violated
            else if (ticket == -2) {
               clientSL = true;
               ticket = SubmitMarketOrder(type, level, clientSL, oe);         // danach client-seitige Stop-Verwaltung (ab dem letzten Level)
               if (ticket <= 0) return(false);
               warn("ExecuteOrders(5)  sequence "+ sequence.name +"."+ NumberToStr(level, "+.") +" #"+ ticket +" client-side stoploss at "+ NumberToStr(oe.StopLoss(oe), PriceFormat) +" installed");
            }
            // on all other errors
            else return(!catch("ExecuteOrders(6)  unknown ticket return value "+ ticket, oe.Error(oe)));
         }
         orders.ticket[i] = ticket;
         continue;
      }

      // getriggerter StopLoss
      if (orders.clientsideLimit[i]) {
         if (orders.ticket[i] == -2)         return(!catch("ExecuteOrders(7)  cannot process client-side stoploss of magic ticket #"+ orders.ticket[i], ERR_ILLEGAL_STATE));
         if (orders.type[i] == OP_UNDEFINED) return(!catch("ExecuteOrders(8)  #"+ orders.ticket[i] +" with client-side stoploss still marked as pending", ERR_ILLEGAL_STATE));
         if (orders.closeTime[i] != 0)       return(!catch("ExecuteOrders(9)  #"+ orders.ticket[i] +" with client-side stoploss already marked as closed", ERR_ILLEGAL_STATE));

         if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("ExecuteOrders()", "Do you really want to execute a triggered client-side stoploss now?"))
            return(!SetLastError(ERR_CANCELLED_BY_USER));

         double lots        = NULL;
         double slippage    = 0.1;
         color  markerColor = CLR_NONE;
         int    oeFlags     = NULL;
         if (!OrderCloseEx(orders.ticket[i], lots, slippage, markerColor, oeFlags, oe)) return(!SetLastError(oe.Error(oe)));

         orders.closedBySL[i] = true;
      }
   }
   ArrayResize(oe, 0);

   // Status aktualisieren und speichern
   bool bNull;
   int  iNull[];
   if (!UpdateStatus(bNull, iNull)) return(false);
   if (!SaveSequence()) return(false);

   return(!catch("ExecuteOrders(10)"));
}


/**
 * Trail existing, open missing and delete obsolete pending orders.
 *
 * @return bool - success status
 */
bool UpdatePendingOrders() {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdatePendingOrders(1)  cannot update orders of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int type, limitOrders, level, lastExistingLevel, nextLevel=sequence.level + ifInt(sequence.direction==D_LONG, 1, -1), sizeOfTickets=ArraySize(orders.ticket);
   bool nextStopExists, ordersChanged;
   string sMissedLevels = "";

   // check if the stop order for the next level exists (always at the last index)
   int i = sizeOfTickets - 1;
   if (sizeOfTickets > 0) {
      if (!orders.closeTime[i] && orders.type[i]==OP_UNDEFINED) { // a pending stop or limit order
         if (orders.level[i] == nextLevel) {                      // the next stop order
            nextStopExists = true;
         }
         else if (IsStopOrderType(orders.pendingType[i])) {
            int error = Grid.DeleteOrder(i);                      // delete an obsolete old stop order (always at the last index)
            if (!error) {
               sizeOfTickets--;
               ordersChanged = true;
            }
            else if (error == -1) {                               // TODO: handle the already opened pending order
               if (__LOG()) log("UpdatePendingOrders(2)  sequence "+ sequence.name +"."+ NumberToStr(orders.level[i], "+.") +" pending #"+ orders.ticket[i] +" was already executed");
               return(!catch("UpdatePendingOrders(3)", ERR_INVALID_TRADE_PARAMETERS));
            }
            else return(false);
         }
      }
   }

   // find the last open order of an active level (an open position or a pending limit order)
   if (sequence.level != 0) {
      for (i=sizeOfTickets-1; i >= 0; i--) {
         level = Abs(orders.level[i]);
         if (!orders.closeTime[i]) {
            if (level < Abs(nextLevel)) {
               lastExistingLevel = orders.level[i];
               break;
            }
         }
         if (level == 1) break;
      }
      if (lastExistingLevel != sequence.level) {
         return(!catch("UpdatePendingOrders(4)  lastExistingOrder("+ lastExistingLevel +") != sequence.level("+ sequence.level +")", ERR_ILLEGAL_STATE));
      }
   }

   // trail a first level stop order (always an existing next level order, thus at the last index)
   if (!sequence.level && nextStopExists) {
      i = sizeOfTickets - 1;
      if (NE(gridbase, orders.gridBase[i], Digits)) {
         static double lastTrailed = INT_MIN;                           // Avoid ERR_TOO_MANY_REQUESTS caused by contacting the trade server
         if (IsTesting() || GetTickCount()-lastTrailed > 3000) {        // at each tick. Wait 3 seconds between consecutive trailings.
            type = Grid.TrailPendingOrder(i); if (!type) return(false); //
            if (IsLimitOrderType(type)) {                               // TrailPendingOrder() missed a level
               lastExistingLevel = nextLevel;                           // -1 | +1
               sequence.level    = nextLevel;
               sequence.maxLevel = Max(Abs(sequence.level), Abs(sequence.maxLevel)) * lastExistingLevel;
               nextLevel        += nextLevel;                           // -2 | +2
               nextStopExists    = false;
            }
            ordersChanged = true;
            lastTrailed = GetTickCount();
         }
      }
   }

   // add all missing levels (pending limit or stop orders) up to the next sequence level
   if (!nextStopExists) {
      while (true) {
         if (IsLimitOrderType(type)) {                            // TrailPendingOrder() or AddPendingOrder() missed a level
            limitOrders++;
            ArrayPushInt(sequence.missedLevels, lastExistingLevel);
            sMissedLevels = sMissedLevels +", "+ lastExistingLevel;
         }
         level = lastExistingLevel + Sign(nextLevel);
         type = Grid.AddPendingOrder(level); if (!type) return(false);
         if (level == nextLevel) {
            if (IsLimitOrderType(type)) {                         // a limit order was opened
               sequence.level    = nextLevel;
               sequence.maxLevel = Max(Abs(sequence.level), Abs(sequence.maxLevel)) * Sign(nextLevel);
               nextLevel        += Sign(nextLevel);
            }
            else {
               nextStopExists = true;
               ordersChanged = true;
               break;
            }
         }
         lastExistingLevel = level;
      }
   }

   if (limitOrders > 0) {
      sMissedLevels = StrSubstr(sMissedLevels, 2); SS.MissedLevels();
      if (__LOG()) log("UpdatePendingOrders(5)  sequence "+ sequence.name +" opened "+ limitOrders +" limit order"+ ifString(limitOrders==1, " for missed level", "s for missed levels") +" ["+ sMissedLevels +"]");
   }
   UpdateProfitTargets();
   ShowProfitTargets();
   SS.ProfitPerLevel();

   if (ordersChanged)
      if (!SaveSequence()) return(false);
   return(!catch("UpdatePendingOrders(6)"));
}


/**
 * L�scht alle gespeicherten �nderungen der Gridbasis und initialisiert sie mit dem angegebenen Wert.
 *
 * @param  datetime time  - Zeitpunkt
 * @param  double   value - neue Gridbasis
 *
 * @return double - neue Gridbasis oder 0, falls ein Fehler auftrat
 */
double GridBase.Reset(datetime time, double value) {
   if (IsLastError()) return(0);

   ArrayResize(gridbase.event, 0);
   ArrayResize(gridbase.time,  0);
   ArrayResize(gridbase.price, 0);

   return(GridBase.Change(time, value));
}


/**
 * Speichert eine �nderung der Gridbasis.
 *
 * @param  datetime time  - Zeitpunkt der �nderung
 * @param  double   value - neue Gridbasis
 *
 * @return double - die neue Gridbasis
 */
double GridBase.Change(datetime time, double value) {
   value = NormalizeDouble(value, Digits);

   if (sequence.maxLevel == 0) {                            // vor dem ersten ausgef�hrten Trade werden vorhandene Werte �berschrieben
      ArrayResize(gridbase.event, 0);
      ArrayResize(gridbase.time,  0);
      ArrayResize(gridbase.price, 0);
   }

   int size = ArraySize(gridbase.event);                    // ab dem ersten ausgef�hrten Trade werden neue Werte angef�gt
   if (size == 0) {
      ArrayPushInt   (gridbase.event, CreateEventId());
      ArrayPushInt   (gridbase.time,  time           );
      ArrayPushDouble(gridbase.price, value          );
      size++;
   }
   else {
      datetime lastStartTime = sequence.start.time[ArraySize(sequence.start.time)-1];
      int minute=time/MINUTE, lastMinute=gridbase.time[size-1]/MINUTE;

      if (time<=lastStartTime || minute!=lastMinute) {      // store all events
         ArrayPushInt   (gridbase.event, CreateEventId());
         ArrayPushInt   (gridbase.time,  time           );
         ArrayPushDouble(gridbase.price, value          );
         size++;
      }
      else {                                                // compact redundant events, store only the last one per minute
         gridbase.event[size-1] = CreateEventId();
         gridbase.time [size-1] = time;
         gridbase.price[size-1] = value;
      }
   }

   gridbase = value; SS.GridBase();
   return(value);
}


/**
 * Open a pending entry order for the specified grid level and add it to the order arrays. Depending on the market a stop or
 * a limit order is opened.
 *
 * @param  int level - grid level of the order to open: -n...1 | 1...+n
 *
 * @return int - order type of the openend pending order or NULL in case of errors
 */
int Grid.AddPendingOrder(int level) {
   if (IsLastError())                                                           return(NULL);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(!catch("Grid.AddPendingOrder(1)  cannot add order to "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int pendingType = ifInt(sequence.direction==D_LONG, OP_BUYSTOP, OP_SELLSTOP);

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.AddPendingOrder()", "Do you really want to submit a new "+ OperationTypeDescription(pendingType) +" order now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   double price=gridbase + level*GridSize*Pips, bid=MarketInfo(Symbol(), MODE_BID), ask=MarketInfo(Symbol(), MODE_ASK);
   int counter, ticket, oe[];
   if (sequence.direction == D_LONG) pendingType = ifInt(GT(price, bid, Digits), OP_BUYSTOP, OP_BUYLIMIT);
   else                              pendingType = ifInt(LT(price, ask, Digits), OP_SELLSTOP, OP_SELLLIMIT);

   // loop until a pending order was opened or a non-fixable error occurred
   while (true) {
      if (IsStopOrderType(pendingType)) ticket = SubmitStopOrder(pendingType, level, oe);
      else                              ticket = SubmitLimitOrder(pendingType, level, oe);
      if (ticket > 0) break;
      if (oe.Error(oe) != ERR_INVALID_STOP) return(NULL);
      counter++;
      if (counter > 9) return(!catch("Grid.AddPendingOrder(2)  sequence "+ sequence.name +"."+ NumberToStr(level, "+.") +" stopping trade request loop after "+ counter +" unsuccessful tries, last error", oe.Error(oe)));
                                                               // market violated: switch order type and ignore price, thus preventing
      if (ticket == -1) {                                      // the same pending order type again and again caused by a stalled price feed
         if (__LOG()) log("Grid.AddPendingOrder(3)  sequence "+ sequence.name +"."+ NumberToStr(level, "+.") +" illegal price "+ OperationTypeDescription(pendingType) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +" (market "+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +"), opening "+ ifString(IsStopOrderType(pendingType), "limit", "stop") +" order instead", oe.Error(oe));
         pendingType += ifInt(pendingType <= OP_SELLLIMIT, 2, -2);
      }
      else if (ticket == -2) {                                 // stop distance violated: use client-side stop management
         ticket = -1;
         warn("Grid.AddPendingOrder(4)  sequence "+ sequence.name +"."+ NumberToStr(level, "+.") +" client-side "+ ifString(IsStopOrderType(pendingType), "stop", "limit") +" for "+ OperationTypeDescription(pendingType) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +" installed");
         break;
      }
      else return(!catch("Grid.AddPendingOrder(5)  unknown "+ ifString(IsStopOrderType(pendingType), "SubmitStopOrder", "SubmitLimitOrder") +" return value "+ ticket, oe.Error(oe)));
   }

   // prepare order dataset
   //int    ticket          = ...                  // use as is
   //int    level           = ...                  // ...
   //double gridbase        = ...                  // ...

   //int    pendingType     = ...                  // ...
   datetime pendingTime     = oe.OpenTime(oe); if (ticket < 0) pendingTime = TimeCurrentEx("Grid.AddPendingOrder(6)");
   double   pendingPrice    = oe.OpenPrice(oe);

   int      openType        = OP_UNDEFINED;
   int      openEvent       = NULL;
   datetime openTime        = NULL;
   double   openPrice       = NULL;
   int      closeEvent      = NULL;
   datetime closeTime       = NULL;
   double   closePrice      = NULL;
   double   stopLoss        = oe.StopLoss(oe);
   bool     clientsideLimit = (ticket <= 0);
   bool     closedBySL      = false;

   double   swap            = NULL;
   double   commission      = NULL;
   double   profit          = NULL;

   // store dataset
   if (!Grid.PushData(ticket, level, gridbase, pendingType, pendingTime, pendingPrice, openType, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, clientsideLimit, closedBySL, swap, commission, profit))
      return(NULL);

   if (last_error || catch("Grid.AddPendingOrder(7)"))
      return(NULL);
   return(pendingType);
}


/**
 * Legt die angegebene Position in den Markt und f�gt den Gridarrays deren Daten hinzu. Aufruf nur in RestoreActiveGridLevels().
 *
 * @param  int level - Gridlevel der Position
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.AddPosition(int level) {
   if (IsLastError())                      return( false);
   if (sequence.status != STATUS_STARTING) return(_false(catch("Grid.AddPosition(1)  cannot add position to "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (!level)                             return(_false(catch("Grid.AddPosition(2)  illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   int orderType = ifInt(sequence.direction==D_LONG, OP_BUY, OP_SELL);

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.AddPosition()", "Do you really want to submit a Market "+ OperationTypeDescription(orderType) +" order now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   // Position �ffnen
   bool clientsideSL = false;
   int oe[];
   int ticket = SubmitMarketOrder(orderType, level, clientsideSL, oe);     // zuerst server-seitigen StopLoss setzen (clientsideSL=FALSE)

   if (ticket <= 0) {
      if (oe.Error(oe) != ERR_INVALID_STOP) return(false);
      // if market violated
      if (ticket == -1) {
         ticket = -2;                                                      // assign ticket #-2 for decreased grid level, UpdateStatus() will "close" it with PL=0.00
         clientsideSL = true;
         oe.setOpenTime(oe, TimeCurrentEx("Grid.AddPosition(3)"));
         if (__LOG()) log("Grid.AddPosition(4)  sequence "+ sequence.name +" position at level "+ level +" would be immediately closed by SL="+ NumberToStr(oe.StopLoss(oe), PriceFormat) +" (market: "+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +"), decreasing grid level...");
      }
      // if stop distance violated
      else if (ticket == -2) {
         clientsideSL = true;
         ticket = SubmitMarketOrder(orderType, level, clientsideSL, oe);   // use client-side stop management
         if (ticket <= 0) return(false);
         warn("Grid.AddPosition(5)  sequence "+ sequence.name +" level "+ level +" #"+ ticket +" client-side stoploss installed at "+ NumberToStr(oe.StopLoss(oe), PriceFormat));
      }
      // on all other errors
      else return(_false(catch("Grid.AddPosition(6)  unknown ticket value "+ ticket, oe.Error(oe))));
   }

   // Daten speichern
   //int    ticket       = ...                     // unver�ndert
   //int    level        = ...                     // unver�ndert
   //double gridbase     = ...                     // unver�ndert

   int      pendingType  = OP_UNDEFINED;
   datetime pendingTime  = NULL;
   double   pendingPrice = NULL;

   int      type         = orderType;
   int      openEvent    = CreateEventId();
   datetime openTime     = oe.OpenTime (oe);
   double   openPrice    = oe.OpenPrice(oe);
   int      closeEvent   = NULL;
   datetime closeTime    = NULL;
   double   closePrice   = NULL;
   double   stopLoss     = oe.StopLoss(oe);
   //bool   clientsideSL = ...                     // unver�ndert
   bool     closedBySL   = false;

   double   swap         = oe.Swap      (oe);      // falls Swap bereits bei OrderOpen gesetzt sein sollte
   double   commission   = oe.Commission(oe);
   double   profit       = NULL;

   if (!Grid.PushData(ticket, level, gridbase, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, clientsideSL, closedBySL, swap, commission, profit))
      return(false);

   ArrayResize(oe, 0);
   return(!catch("Grid.AddPosition(7)"));
}


/**
 * Trail pending open price and stoploss of the specified pending order. If modification of an existing order is not allowed
 * (due to market or broker constraints) it may be replaced by a new stop or limit order.
 *
 * @param  int i - order index
 *
 * @return int - order type of the resulting pending order or NULL in case of errors
 */
int Grid.TrailPendingOrder(int i) {
   if (IsLastError())                         return(NULL);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("Grid.TrailPendingOrder(1)  cannot trail order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (orders.type[i] != OP_UNDEFINED)        return(!catch("Grid.TrailPendingOrder(2)  cannot trail "+ OperationTypeDescription(orders.type[i]) +" position #"+ orders.ticket[i], ERR_ILLEGAL_STATE));
   if (orders.closeTime[i] != 0)              return(!catch("Grid.TrailPendingOrder(3)  cannot trail cancelled "+ OperationTypeDescription(orders.type[i]) +" order #"+ orders.ticket[i], ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.TrailPendingOrder()", "Do you really want to modify the "+ OperationTypeDescription(orders.pendingType[i]) +" order #"+ orders.ticket[i] +" now?"))
      return(!SetLastError(ERR_CANCELLED_BY_USER));

   // calculate changing data
   int      ticket       = orders.ticket[i], oe[];
   int      level        = orders.level[i];
   datetime pendingTime;
   double   pendingPrice = NormalizeDouble(gridbase +           level * GridSize * Pips, Digits);
   double   stopLoss     = NormalizeDouble(pendingPrice - Sign(level) * GridSize * Pips, Digits);

   if (!SelectTicket(ticket, "Grid.TrailPendingOrder(4)", true)) return(NULL);
   datetime prevPendingTime  = OrderOpenTime();
   double   prevPendingPrice = OrderOpenPrice();
   double   prevStoploss     = OrderStopLoss();
   OrderPop("Grid.TrailPendingOrder(5)");

   if (ticket < 0) {                                        // client-side managed limit
      // TODO: update chart markers
   }
   else {                                                   // server-side managed limit
      int error = ModifyStopOrder(ticket, pendingPrice, stopLoss, oe);
      pendingTime = oe.OpenTime(oe);

      if (IsError(error)) {
         if (oe.Error(oe) != ERR_INVALID_STOP) return(!SetLastError(oe.Error(oe)));
         if (error == -1) {                                 // market violated: delete stop order and open a limit order instead
            error = Grid.DeleteOrder(i);
            if (!error) return(Grid.AddPendingOrder(level));
            if (error == -1) {                              // the order was already executed
               pendingTime  = prevPendingTime;              // restore the original values
               pendingPrice = prevPendingPrice;
               stopLoss     = prevStoploss;                 // TODO: modify StopLoss of the now open position
               if (__LOG()) log("Grid.TrailPendingOrder(6)  sequence "+ sequence.name +"."+ NumberToStr(level, "+.") +" pending #"+ orders.ticket[i] +" was already executed");
            }
            else return(NULL);
         }
         if (error == -2) {                                 // stop distance violated: use client-side stop management
            return(!catch("Grid.TrailPendingOrder(7)  stop distance violated (TODO: implement client-side stop management)", oe.Error(oe)));
         }
         return(!catch("Grid.TrailPendingOrder(8)  unknown ModifyStopOrder() return value "+ error, oe.Error(oe)));
      }
   }

   // update changed data (ignore current ticket state which may be different)
   orders.gridBase    [i] = gridbase;
   orders.pendingTime [i] = pendingTime;
   orders.pendingPrice[i] = pendingPrice;
   orders.stopLoss    [i] = stopLoss;

   if (!catch("Grid.TrailPendingOrder(9)"))
      return(orders.pendingType[i]);
   return(NULL);
}


/**
 * Cancel the specified order and remove it from the order arrays.
 *
 * @param  int i - order index
 *
 * @return int - NULL on success or another value in case of errors, especially
 *               -1 if the order was already executed and is not pending anymore
 */
int Grid.DeleteOrder(int i) {
   if (IsLastError())                                                           return(last_error);
   if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING) return(catch("Grid.DeleteOrder(1)  cannot delete order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (orders.type[i] != OP_UNDEFINED)                                          return(catch("Grid.DeleteOrder(2)  cannot delete "+ ifString(orders.closeTime[i], "closed", "open") +" "+ OperationTypeDescription(orders.type[i]) +" order", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.DeleteOrder()", "Do you really want to cancel the "+ OperationTypeDescription(orders.pendingType[i]) +" order at level "+ orders.level[i] +" now?"))
      return(SetLastError(ERR_CANCELLED_BY_USER));

   if (orders.ticket[i] > 0) {
      int oe[], oeFlags = F_ERR_INVALID_TRADE_PARAMETERS;            // accept the order already being executed
      if (!OrderDeleteEx(orders.ticket[i], CLR_NONE, oeFlags, oe)) {
         int error = oe.Error(oe);
         if (error == ERR_INVALID_TRADE_PARAMETERS)
            return(-1);
         return(SetLastError(error));
      }
   }
   if (!Grid.DropData(i)) return(last_error);

   ArrayResize(oe, 0);
   return(catch("Grid.DeleteOrder(3)"));
}


/**
 * Cancel the exit limit of the specified order.
 *
 * @param  int i - order index
 *
 * @return int - NULL on success or another value in case of errors, especially
 *               -1 if the limit was already executed
 */
int Grid.DeleteLimit(int i) {
   if (IsLastError())                                                                   return(last_error);
   if (sequence.status != STATUS_STOPPING)                                              return(catch("Grid.DeleteLimit(1)  cannot delete limit of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (orders.type[i]==OP_UNDEFINED || orders.type[i] > OP_SELL || orders.closeTime[i]) return(catch("Grid.DeleteLimit(2)  cannot delete limit of "+ ifString(orders.closeTime[i], "closed", "open") +" "+ OperationTypeDescription(orders.type[i]) +" order", ERR_ILLEGAL_STATE));

   if (Tick==1) /*&&*/ if (!ConfirmFirstTickTrade("Grid.DeleteLimit()", "Do you really want to delete the limit of the position at level "+ orders.level[i] +" now?"))
      return(SetLastError(ERR_CANCELLED_BY_USER));

   int oe[], oeFlags = F_ERR_INVALID_TRADE_PARAMETERS;         // accept the limit already being executed
   if (!OrderModifyEx(orders.ticket[i], orders.openPrice[i], NULL, NULL, NULL, CLR_NONE, oeFlags, oe)) {
      int error = oe.Error(oe);
      if (error == ERR_INVALID_TRADE_PARAMETERS)
         return(-1);
      return(SetLastError(error));
   }
   ArrayResize(oe, 0);
   return(catch("Grid.DeleteLimit(3)"));
}


/**
 * F�gt den Datenarrays der Sequenz die angegebenen Daten hinzu.
 *
 * @param  int      ticket
 * @param  int      level
 * @param  double   gridBase
 *
 * @param  int      pendingType
 * @param  datetime pendingTime
 * @param  double   pendingPrice
 *
 * @param  int      type
 * @param  int      openEvent
 * @param  datetime openTime
 * @param  double   openPrice
 * @param  int      closeEvent
 * @param  datetime closeTime
 * @param  double   closePrice
 * @param  double   stopLoss
 * @param  bool     clientLimit
 * @param  bool     closedBySL
 *
 * @param  double   swap
 * @param  double   commission
 * @param  double   profit
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.PushData(int ticket, int level, double gridBase, int pendingType, datetime pendingTime, double pendingPrice, int type, int openEvent, datetime openTime, double openPrice, int closeEvent, datetime closeTime, double closePrice, double stopLoss, bool clientLimit, bool closedBySL, double swap, double commission, double profit) {
   clientLimit = clientLimit!=0;
   closedBySL  = closedBySL!=0;
   return(Grid.SetData(-1, ticket, level, gridBase, pendingType, pendingTime, pendingPrice, type, openEvent, openTime, openPrice, closeEvent, closeTime, closePrice, stopLoss, clientLimit, closedBySL, swap, commission, profit));
}


/**
 * Schreibt die angegebenen Daten an die angegebene Position der Gridarrays.
 *
 * @param  int      offset - Arrayposition: Ist dieser Wert -1 oder sind die Gridarrays zu klein, werden sie vergr��ert.
 *
 * @param  int      ticket
 * @param  int      level
 * @param  double   gridBase
 *
 * @param  int      pendingType
 * @param  datetime pendingTime
 * @param  double   pendingPrice
 *
 * @param  int      type
 * @param  int      openEvent
 * @param  datetime openTime
 * @param  double   openPrice
 * @param  int      closeEvent
 * @param  datetime closeTime
 * @param  double   closePrice
 * @param  double   stopLoss
 * @param  bool     clientLimit
 * @param  bool     closedBySL
 *
 * @param  double   swap
 * @param  double   commission
 * @param  double   profit
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.SetData(int offset, int ticket, int level, double gridBase, int pendingType, datetime pendingTime, double pendingPrice, int type, int openEvent, datetime openTime, double openPrice, int closeEvent, datetime closeTime, double closePrice, double stopLoss, bool clientLimit, bool closedBySL, double swap, double commission, double profit) {
   clientLimit = clientLimit!=0;
   closedBySL  = closedBySL!=0;

   if (offset < -1)
      return(_false(catch("Grid.SetData(1)  illegal parameter offset = "+ offset, ERR_INVALID_PARAMETER)));

   int i=offset, size=ArraySize(orders.ticket);

   if      (offset ==    -1) i = ResizeArrays(  size+1)-1;
   else if (offset > size-1) i = ResizeArrays(offset+1)-1;

   orders.ticket         [i] = ticket;
   orders.level          [i] = level;
   orders.gridBase       [i] = NormalizeDouble(gridBase, Digits);

   orders.pendingType    [i] = pendingType;
   orders.pendingTime    [i] = pendingTime;
   orders.pendingPrice   [i] = NormalizeDouble(pendingPrice, Digits);

   orders.type           [i] = type;
   orders.openEvent      [i] = openEvent;
   orders.openTime       [i] = openTime;
   orders.openPrice      [i] = NormalizeDouble(openPrice, Digits);
   orders.closeEvent     [i] = closeEvent;
   orders.closeTime      [i] = closeTime;
   orders.closePrice     [i] = NormalizeDouble(closePrice, Digits);
   orders.stopLoss       [i] = NormalizeDouble(stopLoss, Digits);
   orders.clientsideLimit[i] = clientLimit;
   orders.closedBySL     [i] = closedBySL;

   orders.swap           [i] = NormalizeDouble(swap,       2);
   orders.commission     [i] = NormalizeDouble(commission, 2); if (type != OP_UNDEFINED) { sequence.commission = orders.commission[i]; SS.LotSize(); }
   orders.profit         [i] = NormalizeDouble(profit,     2);

   return(!catch("Grid.SetData(2)"));
}


/**
 * Remove order data at the speciefied index from the order arrays.
 *
 * @param  int i - order index
 *
 * @return bool - success status
 */
bool Grid.DropData(int i) {
   if (i < 0 || i >= ArraySize(orders.ticket)) return(!catch("Grid.DropData(1)  illegal parameter i = "+ i, ERR_INVALID_PARAMETER));

   ArraySpliceInts   (orders.ticket,          i, 1);
   ArraySpliceInts   (orders.level,           i, 1);
   ArraySpliceDoubles(orders.gridBase,        i, 1);

   ArraySpliceInts   (orders.pendingType,     i, 1);
   ArraySpliceInts   (orders.pendingTime,     i, 1);
   ArraySpliceDoubles(orders.pendingPrice,    i, 1);

   ArraySpliceInts   (orders.type,            i, 1);
   ArraySpliceInts   (orders.openEvent,       i, 1);
   ArraySpliceInts   (orders.openTime,        i, 1);
   ArraySpliceDoubles(orders.openPrice,       i, 1);
   ArraySpliceInts   (orders.closeEvent,      i, 1);
   ArraySpliceInts   (orders.closeTime,       i, 1);
   ArraySpliceDoubles(orders.closePrice,      i, 1);
   ArraySpliceDoubles(orders.stopLoss,        i, 1);
   ArraySpliceBools  (orders.clientsideLimit, i, 1);
   ArraySpliceBools  (orders.closedBySL,      i, 1);

   ArraySpliceDoubles(orders.swap,            i, 1);
   ArraySpliceDoubles(orders.commission,      i, 1);
   ArraySpliceDoubles(orders.profit,          i, 1);

   return(!catch("Grid.DropData(2)"));
}


/**
 * Sucht eine als offene markierte Position des angegebenen Levels und gibt ihren Index zur�ck. Je Level kann es maximal nur
 * eine offene Position geben.
 *
 * @param  int level - Level der zu suchenden Position
 *
 * @return int - Index der gefundenen Position oder -1 (EMPTY), wenn keine offene Position des angegebenen Levels gefunden wurde
 */
int Grid.FindOpenPosition(int level) {
   if (!level) return(_EMPTY(catch("Grid.FindOpenPosition(1)  illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   int size = ArraySize(orders.ticket);
   for (int i=size-1; i >= 0; i--) {                                 // r�ckw�rts iterieren, um Zeit zu sparen
      if (orders.level[i] != level)       continue;                  // Orderlevel mu� �bereinstimmen
      if (orders.type[i] == OP_UNDEFINED) continue;                  // Order darf nicht pending sein (also Position)
      if (orders.closeTime[i] != 0)       continue;                  // Position darf nicht geschlossen sein
      return(i);
   }
   return(EMPTY);
}


/**
 * �ffnet eine Position zum aktuellen Preis.
 *
 * @param  _In_  int  type         - Ordertyp: OP_BUY | OP_SELL
 * @param  _In_  int  level        - Gridlevel der Order
 * @param  _In_  bool clientsideSL - ob der StopLoss client-seitig verwaltet wird
 * @param  _Out_ int  oe[]         - execution details (struct ORDER_EXECUTION)
 *
 * @return int - Orderticket (positiver Wert) oder ein anderer Wert, falls ein Fehler auftrat
 *
 * Spezielle Return-Codes:
 * -----------------------
 * -1: der StopLoss verletzt den aktuellen Spread
 * -2: der StopLoss verletzt die StopDistance des Brokers
 */
int SubmitMarketOrder(int type, int level, bool clientsideSL, int oe[]) {
   clientsideSL = clientsideSL!=0;
   if (IsLastError())                                                           return(0);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitMarketOrder(1)  cannot submit market order for "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (type!=OP_BUY  && type!=OP_SELL)                                          return(_NULL(catch("SubmitMarketOrder(2)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUY  && level<=0)                                               return(_NULL(catch("SubmitMarketOrder(3)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELL && level>=0)                                               return(_NULL(catch("SubmitMarketOrder(4)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   price       = NULL;
   double   slippage    = 0.1;
   double   stopLoss    = ifDouble(clientsideSL, NULL, gridbase + (level-Sign(level))*GridSize*Pips);
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = ifInt(level > 0, CLR_LONG, CLR_SHORT); if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = NULL;

   if (!clientsideSL) /*&&*/ if (Abs(level) >= Abs(sequence.level))
      oeFlags |= F_ERR_INVALID_STOP;            // ab dem letzten Level bei server-seitigem StopLoss ERR_INVALID_STOP abfangen

   int ticket = OrderSendEx(Symbol(), type, LotSize, price, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (oeFlags & F_ERR_INVALID_STOP && 1) {
      if (error == ERR_INVALID_STOP) {          // Der StopLoss liegt entweder innerhalb des Spreads (-1) oder innerhalb der StopDistance (-2).
         bool insideSpread;
         if (type == OP_BUY) insideSpread = GE(oe.StopLoss(oe), oe.Bid(oe));
         else                insideSpread = LE(oe.StopLoss(oe), oe.Ask(oe));
         if (insideSpread)
            return(-1);
         return(-2);
      }
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Open a pending stop order.
 *
 * @param  _In_  int type  - order type: OP_BUYSTOP | OP_SELLSTOP
 * @param  _In_  int level - order grid level
 * @param  _Out_ int oe[]  - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket (positive value) on success or another value in case of errors, especially
 *               -1 if the limit violates the current market or
 *               -2 if the limit violates the broker's stop distance
 */
int SubmitStopOrder(int type, int level, int oe[]) {
   if (IsLastError())                                                           return(0);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitStopOrder(1)  cannot submit stop order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (type!=OP_BUYSTOP  && type!=OP_SELLSTOP)                                  return(_NULL(catch("SubmitStopOrder(2)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUYSTOP  && level <= 0)                                         return(_NULL(catch("SubmitStopOrder(3)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELLSTOP && level >= 0)                                         return(_NULL(catch("SubmitStopOrder(4)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   stopPrice   = gridbase + level*GridSize*Pips;
   double   slippage    = NULL;
   double   stopLoss    = stopPrice - Sign(level)*GridSize*Pips;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = CLR_PENDING; if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = F_ERR_INVALID_STOP;      // accept ERR_INVALID_STOP

   int ticket = OrderSendEx(Symbol(), type, LotSize, stopPrice, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (error == ERR_INVALID_STOP) {                // either the entry limit violates the market (-1) or the broker's stop distance (-2)
      bool violatedMarket;
      if (!oe.StopDistance(oe))    violatedMarket = true;
      else if (type == OP_BUYSTOP) violatedMarket = LE(oe.OpenPrice(oe), oe.Ask(oe));
      else                         violatedMarket = GE(oe.OpenPrice(oe), oe.Bid(oe));
      return(ifInt(violatedMarket, -1, -2));
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Open a pending limit order.
 *
 * @param  _In_  int type  - order type: OP_BUYLIMIT | OP_SELLLIMIT
 * @param  _In_  int level - order grid level
 * @param  _Out_ int oe[]  - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket (positive value) on success or another value in case of errors, especially
 *               -1 if the limit violates the current market or
 *               -2 the limit violates the broker's stop distance
 */
int SubmitLimitOrder(int type, int level, int oe[]) {
   if (IsLastError())                                                           return(0);
   if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING) return(_NULL(catch("SubmitLimitOrder(1)  cannot submit limit order for "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE)));
   if (type!=OP_BUYLIMIT  && type!=OP_SELLLIMIT)                                return(_NULL(catch("SubmitLimitOrder(2)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER)));
   if (type==OP_BUYLIMIT  && level <= 0)                                        return(_NULL(catch("SubmitLimitOrder(3)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));
   if (type==OP_SELLLIMIT && level >= 0)                                        return(_NULL(catch("SubmitLimitOrder(4)  illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_PARAMETER)));

   double   limitPrice  = gridbase + level*GridSize*Pips;
   double   slippage    = NULL;
   double   stopLoss    = limitPrice - Sign(level)*GridSize*Pips;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = CLR_PENDING; if (!orderDisplayMode) markerColor = CLR_NONE;
   int      oeFlags     = F_ERR_INVALID_STOP;      // accept ERR_INVALID_STOP

   int ticket = OrderSendEx(Symbol(), type, LotSize, limitPrice, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (error == ERR_INVALID_STOP) {                // either the entry limit violates the market (-1) or the broker's stop distance (-2)
      bool violatedMarket;
      if (!oe.StopDistance(oe))     violatedMarket = true;
      else if (type == OP_BUYLIMIT) violatedMarket = GE(oe.OpenPrice(oe), oe.Ask(oe));
      else                          violatedMarket = LE(oe.OpenPrice(oe), oe.Bid(oe));
      return(ifInt(violatedMarket, -1, -2));
   }
   return(_NULL(SetLastError(error)));
}


/**
 * Modify entry price and stoploss of a pending stop order (i.e. trail a first level order).
 *
 * @param  _Out_ int oe[] - order execution details (struct ORDER_EXECUTION)
 *
 * @return int - error status: NULL on success or another value in case of errors, especially
 *               -1 if the new entry price violates the current market or
 *               -2 if the new entry price violates the broker's stop distance
 */
int ModifyStopOrder(int ticket, double stopPrice, double stopLoss, int oe[]) {
   if (IsLastError())                         return(last_error);
   if (sequence.status != STATUS_PROGRESSING) return(catch("ModifyStopOrder(1)  cannot modify order of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int oeFlags = F_ERR_INVALID_STOP;            // accept ERR_INVALID_STOP
   bool success = OrderModifyEx(ticket, stopPrice, stopLoss, NULL, NULL, CLR_PENDING, oeFlags, oe);
   if (success) return(NO_ERROR);

   int error = oe.Error(oe);
   if (error == ERR_INVALID_STOP) {             // either the entry price violates the market (-1) or it violates the broker's stop distance (-2)
      bool violatedMarket;
      if (!oe.StopDistance(oe))           violatedMarket = true;
      else if (oe.Type(oe) == OP_BUYSTOP) violatedMarket = GE(oe.Ask(oe), stopPrice);
      else                                violatedMarket = LE(oe.Bid(oe), stopPrice);
      return(ifInt(violatedMarket, -1, -2));
   }
   return(SetLastError(error));
}


/**
 * Generiert f�r den angegebenen Gridlevel eine MagicNumber.
 *
 * @param  int level - Gridlevel
 *
 * @return int - MagicNumber oder -1 (EMPTY), falls ein Fehler auftrat
 */
int CreateMagicNumber(int level) {
   if (sequence.id < SID_MIN) return(_EMPTY(catch("CreateMagicNumber(1)  illegal sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR)));
   if (!level)                return(_EMPTY(catch("CreateMagicNumber(2)  illegal parameter level = "+ level, ERR_INVALID_PARAMETER)));

   // F�r bessere Obfuscation ist die Reihenfolge der Werte [ea,level,sequence] und nicht [ea,sequence,level], was aufeinander folgende Werte w�ren.
   int ea       = STRATEGY_ID & 0x3FF << 22;                         // 10 bit (Bits gr��er 10 l�schen und auf 32 Bit erweitern)  | Position in MagicNumber: Bits 23-32
       level    = Abs(level);                                        // der Level in MagicNumber ist immer positiv                |
       level    = level & 0xFF << 14;                                //  8 bit (Bits gr��er 8 l�schen und auf 22 Bit erweitern)   | Position in MagicNumber: Bits 15-22
   int sequence = sequence.id & 0x3FFF;                              // 14 bit (Bits gr��er 14 l�schen                            | Position in MagicNumber: Bits  1-14

   return(ea + level + sequence);
}


/**
 * Display the current runtime status.
 *
 * @param  int error [optional] - error to display (default: none)
 *
 * @return int - the same error or the current error status if no error was passed
 */
int ShowStatus(int error = NO_ERROR) {
   if (!__CHART()) return(error);

   string msg, sAtLevel, sError;

   if      (__STATUS_INVALID_INPUT) sError = StringConcatenate("  [",                 ErrorDescription(ERR_INVALID_INPUT_PARAMETER), "]");
   else if (__STATUS_OFF          ) sError = StringConcatenate("  [switched off => ", ErrorDescription(__STATUS_OFF.reason        ), "]");

   switch (sequence.status) {
      case STATUS_UNDEFINED:   msg = " not initialized"; break;
      case STATUS_WAITING:           if (sequence.maxLevel != 0) sAtLevel = StringConcatenate(" at level ", sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")");
                               msg = StringConcatenate("     ", sSequenceDirection, Sequence.ID, " waiting", sAtLevel); break;
      case STATUS_STARTING:    msg = StringConcatenate("     ", sSequenceDirection, Sequence.ID, " starting at level ",    sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      case STATUS_PROGRESSING: msg = StringConcatenate("     ", sSequenceDirection, Sequence.ID, " progressing at level ", sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      case STATUS_STOPPING:    msg = StringConcatenate("     ", sSequenceDirection, Sequence.ID, " stopping at level ",    sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      case STATUS_STOPPED:     msg = StringConcatenate("     ", sSequenceDirection, Sequence.ID, " stopped at level ",     sequence.level, "  (max: ", sequence.maxLevel, sSequenceMissedLevels, ")"); break;
      default:
         return(catch("ShowStatus(1)  illegal sequence status = "+ sequence.status, ERR_RUNTIME_ERROR));
   }

   msg = StringConcatenate(__NAME(), msg, sError,                                    NL,
                                                                                     NL,
                           "Grid:              ", GridSize, " pip", sGridBase,       NL,
                           "LotSize:          ",  sLotSize, sSequenceProfitPerLevel, NL,
                           "Start:             ", sStartConditions,                  NL,
                           "Stop:              ", sStopConditions,                   NL,
                           sAutoResume,                       // if set it ends with NL,
                           sAutoRestart,                      // if set it ends with NL,
                           "Stops:             ", sSequenceStops, sSequenceStopsPL,  NL,
                           "Profit/Loss:    ",   sSequenceTotalPL, sSequencePlStats, NL,
                           sRestartStats
                           );

   // 3 lines margin-top for instrument and indicator legend
   Comment(StringConcatenate(NL, NL, NL, msg));
   if (__WHEREAMI__ == CF_INIT)
      WindowRedraw();

   // f�r Fernbedienung: versteckten Status im Chart speichern
   string label = "SnowRoller.status";
   if (ObjectFind(label) != 0) {
      if (!ObjectCreate(label, OBJ_LABEL, 0, 0, 0))
         return(catch("ShowStatus(2)"));
      ObjectSet(label, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   }
   if (sequence.status == STATUS_UNDEFINED) ObjectDelete(label);
   else                                     ObjectSetText(label, StringConcatenate(Sequence.ID, "|", sequence.status), 1);

   if (!catch("ShowStatus(3)"))
      return(error);
   return(last_error);
}


/**
 * ShowStatus(): Aktualisiert alle in ShowStatus() verwendeten String-Repr�sentationen.
 */
void SS.All() {
   if (!__CHART()) return;

   SS.SequenceId();
   SS.GridBase();
   SS.GridDirection();
   SS.MissedLevels();
   SS.LotSize();
   SS.ProfitPerLevel();
   SS.StartStopConditions();
   SS.AutoResume();
   SS.AutoRestart();
   SS.Stops();
   SS.TotalPL();
   SS.MaxProfit();
   SS.MaxDrawdown();
}


/**
 * ShowStatus(): Aktualisiert die Anzeige der Sequenz-ID in der Titelzeile des Testers.
 */
void SS.SequenceId() {
   if (IsTesting() && IsVisualMode()) {
      SetWindowTextA(FindTesterWindow(), "Tester - SR."+ sequence.id);
   }
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von gridbase.
 */
void SS.GridBase() {
   if (!__CHART()) return;

   if (ArraySize(gridbase.event) > 0) {
      sGridBase = " @ "+ NumberToStr(gridbase, PriceFormat);
   }
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.direction.
 */
void SS.GridDirection() {
   if (!__CHART()) return;

   if (sequence.direction != 0) {
      sSequenceDirection = TradeDirectionDescription(sequence.direction) +" ";
   }
}


/**
 * ShowStatus(): Update the string presentation of sequence.missedLevels.
 */
void SS.MissedLevels() {
   if (!__CHART()) return;

   int size = ArraySize(sequence.missedLevels);
   if (!size) sSequenceMissedLevels = "";
   else       sSequenceMissedLevels = ", missed: "+ JoinInts(sequence.missedLevels);
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von LotSize.
 */
void SS.LotSize() {
   if (!__CHART()) return;

   double stopSize = GridSize * PipValue(LotSize) - sequence.commission;
   if (ShowProfitInPercent) sLotSize = NumberToStr(LotSize, ".+") +" lot = "+ DoubleToStr(MathDiv(stopSize, sequence.startEquity) * 100, 2) +"%/stop";
   else                     sLotSize = NumberToStr(LotSize, ".+") +" lot = "+ DoubleToStr(stopSize, 2) +"/stop";
}


/**
 * ShowStatus(): Update the string representation of the configured start/stop conditions.
 */
void SS.StartStopConditions() {
   if (!__CHART()) return;

   // start conditions, order: [sessionbreak+] trend, time, price
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
      if (sValue != "") sValue = " + "+ sValue;
      sValue = "sessionbreak"+ sValue;
   }
   if (sValue == "") sStartConditions = "-";
   else              sStartConditions = sValue;

   // stop conditions, order: trend, profit, time, price
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
 * ShowStatus(): Update the string representation of input parameter "AutoResume".
 */
void SS.AutoResume() {
   if (!__CHART()) return;

   if (AutoResume) sAutoResume = "AutoResume: On" + NL;
   else            sAutoResume = "AutoResume: Off"+ NL;
}


/**
 * ShowStatus(): Update the string representation of input parameter "AutoRestart".
 */
void SS.AutoRestart() {
   if (!__CHART()) return;

   if (AutoRestart) sAutoRestart = "AutoRestart: On ("+ sequence.cycle +")" + NL;
   else             sAutoRestart = "AutoRestart: Off"+ NL;
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentationen von sequence.stops und sequence.stopsPL.
 */
void SS.Stops() {
   if (!__CHART()) return;
   sSequenceStops = sequence.stops +" stop"+ ifString(sequence.stops==1, "", "s");

   // Anzeige wird nicht vor der ersten ausgestoppten Position gesetzt
   if (sequence.stops > 0) {
      if (ShowProfitInPercent) sSequenceStopsPL = " = "+ DoubleToStr(MathDiv(sequence.stopsPL, sequence.startEquity) * 100, 2) +"%";
      else                     sSequenceStopsPL = " = "+ DoubleToStr(sequence.stopsPL, 2);
   }
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.totalPL.
 */
void SS.TotalPL() {
   if (!__CHART()) return;

   // Anzeige wird nicht vor der ersten offenen Position gesetzt
   if (sequence.maxLevel == 0)   sSequenceTotalPL = "-";
   else if (ShowProfitInPercent) sSequenceTotalPL = NumberToStr(MathDiv(sequence.totalPL, sequence.startEquity) * 100, "+.2") +"%";
   else                          sSequenceTotalPL = NumberToStr(sequence.totalPL, "+.2");
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.maxProfit.
 */
void SS.MaxProfit() {
   if (!__CHART()) return;

   if (ShowProfitInPercent) sSequenceMaxProfit = NumberToStr(MathDiv(sequence.maxProfit, sequence.startEquity) * 100, "+.2") +"%";
   else                     sSequenceMaxProfit = NumberToStr(sequence.maxProfit, "+.2");
   SS.PLStats();
}


/**
 * ShowStatus(): Aktualisiert die String-Repr�sentation von sequence.maxDrawdown.
 */
void SS.MaxDrawdown() {
   if (!__CHART()) return;

   if (ShowProfitInPercent) sSequenceMaxDrawdown = NumberToStr(MathDiv(sequence.maxDrawdown, sequence.startEquity) * 100, "+.2") +"%";
   else                     sSequenceMaxDrawdown = NumberToStr(sequence.maxDrawdown, "+.2");
   SS.PLStats();
}


/**
 * ShowStatus(): Update the string representation of sequence.profitPerLevel.
 */
void SS.ProfitPerLevel() {
   if (!__CHART()) return;

   if (!sequence.level) {
      sSequenceProfitPerLevel = "";                // no display if no position is open
   }
   else {
      double stopSize = GridSize * PipValue(LotSize);
      int    levels   = Abs(sequence.level) - ArraySize(sequence.missedLevels);
      double profit   = levels * stopSize;

      if (ShowProfitInPercent) sSequenceProfitPerLevel = " = "+ DoubleToStr(MathDiv(profit, sequence.startEquity) * 100, 1) +"%/level";
      else                     sSequenceProfitPerLevel = " = "+ DoubleToStr(profit, 2) +"/level";
   }
}


/**
 * ShowStatus(): Aktualisiert die kombinierte String-Repr�sentation der P/L-Statistik.
 */
void SS.PLStats() {
   if (!__CHART()) return;

   if (sequence.maxLevel != 0) {    // no display until a position was opened
      sSequencePlStats = "  ("+ sSequenceMaxProfit +"/"+ sSequenceMaxDrawdown +")";
   }
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
 * Restore sequence id and transient status found in the chart after recompilation or terminal restart.
 *
 * @return bool - whether a sequence id was found and restored
 */
bool RestoreChartStatus() {
   string name = __NAME();
   string key  = name +".runtime.Sequence.ID", sValue = "";

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
         sequence.id     = iValue; SS.SequenceId();
         Sequence.ID     = ifString(IsTestSequence(), "T", "") + sequence.id;
         sequence.name   = StrLeft(TradeDirectionDescription(sequence.direction), 1) +"."+ sequence.id;
         sequence.status = STATUS_WAITING;
         SetCustomLog(sequence.id, NULL);
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
 * L�scht alle im Chart gespeicherten Sequenzdaten.
 *
 * @return int - Fehlerstatus
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
 * Ermittelt die aktuell laufenden Sequenzen.
 *
 * @param  int ids[] - Array zur Aufnahme der gefundenen Sequenz-IDs
 *
 * @return bool - ob mindestens eine laufende Sequenz gefunden wurde
 */
bool GetRunningSequences(int ids[]) {
   ArrayResize(ids, 0);
   int id;

   for (int i=OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))               // FALSE: w�hrend des Auslesens wurde in einem anderen Thread eine offene Order entfernt
         continue;

      if (IsMyOrder()) {
         id = OrderMagicNumber() & 0x3FFF;                           // 14 Bits (Bits 1-14) => sequence.id
         if (!IntInArray(ids, id))
            ArrayPushInt(ids, id);
      }
   }

   if (ArraySize(ids) != 0)
      return(ArraySort(ids));
   return(false);
}


/**
 * Ob die aktuell selektierte Order zu dieser Strategie geh�rt. Wird eine Sequenz-ID angegeben, wird zus�tzlich �berpr�ft,
 * ob die Order zur angegebenen Sequenz geh�rt.
 *
 * @param  int sequenceId - ID einer Sequenz (default: NULL)
 *
 * @return bool
 */
bool IsMyOrder(int sequenceId = NULL) {
   if (OrderSymbol() == Symbol()) {
      if (OrderMagicNumber() >> 22 == STRATEGY_ID) {
         if (sequenceId == NULL)
            return(true);
         return(sequenceId == OrderMagicNumber() & 0x3FFF);          // 14 Bits (Bits 1-14) => sequence.id
      }
   }
   return(false);
}


string   last.Sequence.ID;
string   last.GridDirection;
int      last.GridSize;
double   last.LotSize;
int      last.StartLevel;
string   last.StartConditions;
string   last.StopConditions;
bool     last.AutoResume;
bool     last.AutoRestart;
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
   last.LotSize                = LotSize;
   last.StartLevel             = StartLevel;
   last.StartConditions        = StringConcatenate(StartConditions, "");
   last.StopConditions         = StringConcatenate(StopConditions,  "");
   last.AutoResume             = AutoResume;
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
   LotSize                = last.LotSize;
   StartLevel             = last.StartLevel;
   StartConditions        = last.StartConditions;
   StopConditions         = last.StopConditions;
   AutoResume             = last.AutoResume;
   AutoRestart            = last.AutoRestart;
   ShowProfitInPercent    = last.ShowProfitInPercent;
   Sessionbreak.StartTime = last.Sessionbreak.StartTime;
   Sessionbreak.EndTime   = last.Sessionbreak.EndTime;
}


/**
 * Validiert und setzt nur die in der Konfiguration angegebene Sequenz-ID. Called only from onInitUser().
 *
 * @param  bool interactive - whether parameters have been entered through the input dialog
 *
 * @return bool - ob eine g�ltige Sequenz-ID gefunden und restauriert wurde
 */
bool ValidateInputs.ID(bool interactive) {
   interactive = interactive!=0;

   bool isParameterChange = (ProgramInitReason() == IR_PARAMETERS);  // otherwise inputs have been applied programmatically
   if (isParameterChange)
      interactive = true;

   string sValue = StrToUpper(StrTrim(Sequence.ID));

   if (!StringLen(sValue))
      return(false);

   if (StrLeft(sValue, 1) == "T") {
      sequence.isTest = true;
      sValue = StrSubstr(sValue, 1);
   }
   if (!StrIsDigit(sValue))
      return(_false(ValidateInputs.OnError("ValidateInputs.ID(1)", "Illegal input parameter Sequence.ID = \""+ Sequence.ID +"\"", interactive)));

   int iValue = StrToInteger(sValue);
   if (iValue < SID_MIN || iValue > SID_MAX)
      return(_false(ValidateInputs.OnError("ValidateInputs.ID(2)", "Illegal input parameter Sequence.ID = \""+ Sequence.ID +"\"", interactive)));

   sequence.id = iValue; SS.SequenceId();
   Sequence.ID = ifString(IsTestSequence(), "T", "") + sequence.id;
   SetCustomLog(sequence.id, NULL);

   return(true);
}


/**
 * Validate new or changed input parameters of a sequence. Parameters may have been entered through the input dialog, may
 * have been read and applied from a sequence status file or may have been deserialized and applied programmatically by the
 * terminal (e.g. at terminal restart).
 *
 * @param  bool interactive - whether the parameters have been entered through the input dialog
 *
 * @return bool - whether the input parameters are valid
 */
bool ValidateInputs(bool interactive) {
   interactive = interactive!=0;
   if (IsLastError()) return(false);

   bool isParameterChange = (ProgramInitReason()==IR_PARAMETERS); // otherwise inputs have been applied programmatically
   if (isParameterChange)
      interactive = true;

   // Sequence.ID
   if (isParameterChange) {
      if (sequence.status == STATUS_UNDEFINED) {
         if (Sequence.ID != last.Sequence.ID)                     return(_false(ValidateInputs.OnError("ValidateInputs(1)", "Changing the sequence at runtime is not supported. Unload the EA first.", interactive)));
      }
      else if (!StringLen(StrTrim(Sequence.ID))) {
         Sequence.ID = last.Sequence.ID;                          // apply the existing internal id
      }
      else if (StrTrim(Sequence.ID) != StrTrim(last.Sequence.ID)) return(_false(ValidateInputs.OnError("ValidateInputs(2)", "Changing the sequence at runtime is not supported. Unload the EA first.", interactive)));
   }
   else if (!StringLen(Sequence.ID)) {                            // wir m�ssen im STATUS_UNDEFINED sein (sequence.id = 0)
      if (sequence.id != 0)                                       return(_false(catch("ValidateInputs(3)  illegal Sequence.ID = \""+ Sequence.ID +"\" (sequence.id="+ sequence.id +")", ERR_RUNTIME_ERROR)));
   }
   else {}                                                        // wenn gesetzt, ist die ID schon validiert und die Sequenz geladen (sonst landen wir hier nicht)

   // GridDirection
   string sValue = StrToLower(StrTrim(GridDirection));
   if      (StrStartsWith("long",  sValue)) sValue = "Long";
   else if (StrStartsWith("short", sValue)) sValue = "Short";
   else                                                           return(_false(ValidateInputs.OnError("ValidateInputs(4)", "Invalid GridDirection = \""+ GridDirection +"\"", interactive)));
   if (isParameterChange && !StrCompareI(sValue, last.GridDirection)) {
      if (ArraySize(sequence.start.event) > 0)                    return(_false(ValidateInputs.OnError("ValidateInputs(5)", "Cannot change GridDirection of "+ StatusDescription(sequence.status) +" sequence", interactive)));
   }
   sequence.direction = StrToTradeDirection(sValue);
   GridDirection      = sValue; SS.GridDirection();
   sequence.name      = StrLeft(GridDirection, 1) +"."+ sequence.id;

   // GridSize
   if (isParameterChange) {
      if (GridSize != last.GridSize)
         if (ArraySize(sequence.start.event) > 0)                 return(_false(ValidateInputs.OnError("ValidateInputs(6)", "Cannot change GridSize of "+ StatusDescription(sequence.status) +" sequence", interactive)));
   }
   if (GridSize < 1)                                              return(_false(ValidateInputs.OnError("ValidateInputs(7)", "Invalid GridSize = "+ GridSize, interactive)));

   // LotSize
   if (isParameterChange) {
      if (NE(LotSize, last.LotSize))
         if (ArraySize(sequence.start.event) > 0)                 return(_false(ValidateInputs.OnError("ValidateInputs(8)", "Cannot change LotSize of "+ StatusDescription(sequence.status) +" sequence", interactive)));
   }
   if (LE(LotSize, 0))                                            return(_false(ValidateInputs.OnError("ValidateInputs(9)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+"), interactive)));
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT );
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT );
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   int error = GetLastError();
   if (IsError(error))                                            return(_false(catch("ValidateInputs(10)  symbol=\""+ Symbol() +"\"", error)));
   if (LT(LotSize, minLot))                                       return(_false(ValidateInputs.OnError("ValidateInputs(11)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+") +" (MinLot="+  NumberToStr(minLot, ".+" ) +")", interactive)));
   if (GT(LotSize, maxLot))                                       return(_false(ValidateInputs.OnError("ValidateInputs(12)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+") +" (MaxLot="+  NumberToStr(maxLot, ".+" ) +")", interactive)));
   if (MathModFix(LotSize, lotStep) != 0)                         return(_false(ValidateInputs.OnError("ValidateInputs(13)", "Invalid LotSize = "+ NumberToStr(LotSize, ".+") +" (LotStep="+ NumberToStr(lotStep, ".+") +")", interactive)));
   SS.LotSize();

   // StartLevel
   if (isParameterChange) {
      if (StartLevel != last.StartLevel)
         if (ArraySize(sequence.start.event) > 0)                 return(_false(ValidateInputs.OnError("ValidateInputs(14)", "Cannot change StartLevel of "+ StatusDescription(sequence.status) +" sequence", interactive)));
   }
   if (sequence.direction == D_LONG) {
      if (StartLevel < 0)                                         return(_false(ValidateInputs.OnError("ValidateInputs(15)", "Invalid StartLevel = "+ StartLevel, interactive)));
   }
   StartLevel = Abs(StartLevel);

   string trendIndicators[] = {"ALMA", "MovingAverage", "NonLagMA", "TriEMA", "SuperSmoother", "HalfTrend", "SuperTrend"};


   // StartConditions, AND combined: @trend(<indicator>:<timeframe>:<params>) | @[bid|ask|median|price](double) | @time(datetime)
   // ---------------------------------------------------------------------------------------------------------------------------
   // Bei Parameter�nderung Werte nur �bernehmen, wenn sie sich tats�chlich ge�ndert haben, soda� StartConditions nur bei �nderung (re-)aktiviert werden.
   if (!isParameterChange || StartConditions!=last.StartConditions) {
      start.conditions      = false;
      start.trend.condition = false;
      start.price.condition = false;
      start.time.condition  = false;

      // StartConditions in einzelne Ausdr�cke zerlegen
      string exprs[], expr, elems[], key;
      int    iValue, time, sizeOfElems, sizeOfExprs = Explode(StartConditions, "&&", exprs, NULL);
      double dValue;

      // jeden Ausdruck parsen und validieren
      for (int i=0; i < sizeOfExprs; i++) {
         start.conditions = false;                      // im Fehlerfall ist start.conditions immer deaktiviert

         expr = StrTrim(exprs[i]);
         if (!StringLen(expr)) {
            if (sizeOfExprs > 1)                        return(_false(ValidateInputs.OnError("ValidateInputs(16)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            break;
         }
         if (StringGetChar(expr, 0) != '@')             return(_false(ValidateInputs.OnError("ValidateInputs(17)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
         if (Explode(expr, "(", elems, NULL) != 2)      return(_false(ValidateInputs.OnError("ValidateInputs(18)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
         if (!StrEndsWith(elems[1], ")"))               return(_false(ValidateInputs.OnError("ValidateInputs(19)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
         key = StrTrim(elems[0]);
         sValue = StrTrim(StrLeft(elems[1], -1));
         if (!StringLen(sValue))                        return(_false(ValidateInputs.OnError("ValidateInputs(20)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));

         if (key == "@trend") {
            if (start.trend.condition)                  return(_false(ValidateInputs.OnError("ValidateInputs(21)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (multiple trend conditions)", interactive)));
            if (start.price.condition)                  return(_false(ValidateInputs.OnError("ValidateInputs(22)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (trend and price conditions)", interactive)));
            if (start.time.condition)                   return(_false(ValidateInputs.OnError("ValidateInputs(23)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (trend and time conditions)", interactive)));
            if (Explode(sValue, ":", elems, NULL) != 3) return(_false(ValidateInputs.OnError("ValidateInputs(24)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            sValue = StrTrim(elems[0]);
            int idx = SearchStringArrayI(trendIndicators, sValue);
            if (idx == -1)                              return(_false(ValidateInputs.OnError("ValidateInputs(25)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (unsupported trend indicator "+ DoubleQuoteStr(sValue) +")", interactive)));
            start.trend.indicator = StrToLower(sValue);
            start.trend.timeframe = StrToPeriod(elems[1], F_ERR_INVALID_PARAMETER);
            if (start.trend.timeframe == -1)            return(_false(ValidateInputs.OnError("ValidateInputs(26)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (trend indicator timeframe)", interactive)));
            start.trend.params = StrTrim(elems[2]);
            if (!StringLen(start.trend.params))         return(_false(ValidateInputs.OnError("ValidateInputs(27)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (trend indicator parameters)", interactive)));
            exprs[i] = "trend("+ trendIndicators[idx] +":"+ TimeframeDescription(start.trend.timeframe) +":"+ start.trend.params +")";
            start.trend.description = exprs[i];
            start.trend.condition   = true;
         }

         else if (key=="@bid" || key=="@ask" || key=="@median" || key=="@price") {
            if (start.trend.condition)                  return(_false(ValidateInputs.OnError("ValidateInputs(28)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (trend and price conditions)", interactive)));
            if (start.price.condition)                  return(_false(ValidateInputs.OnError("ValidateInputs(29)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (multiple price conditions)", interactive)));
            sValue = StrReplace(sValue, "'", "");
            if (!StrIsNumeric(sValue))                  return(_false(ValidateInputs.OnError("ValidateInputs(30)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            dValue = StrToDouble(sValue);
            if (dValue <= 0)                            return(_false(ValidateInputs.OnError("ValidateInputs(31)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            start.price.value     = NormalizeDouble(dValue, Digits);
            start.price.lastValue = NULL;
            if      (key == "@bid") start.price.type = PRICE_BID;
            else if (key == "@ask") start.price.type = PRICE_ASK;
            else                    start.price.type = PRICE_MEDIAN;
            exprs[i] = NumberToStr(start.price.value, PriceFormat);
            exprs[i] = StrSubstr(key, 1) +"("+ StrLeftTo(exprs[i], "'0") +")";   // cut "'0" for improved readability
            start.price.description = exprs[i];
            start.price.condition   = true;
         }

         else if (key == "@time") {
            if (start.trend.condition)                  return(_false(ValidateInputs.OnError("ValidateInputs(32)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (trend and time conditions)", interactive)));
            if (start.time.condition)                   return(_false(ValidateInputs.OnError("ValidateInputs(33)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions) +" (multiple time conditions)", interactive)));
            time = StrToTime(sValue);
            if (IsError(GetLastError()))                return(_false(ValidateInputs.OnError("ValidateInputs(34)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));
            // TODO: Validierung von @time ist unzureichend
            start.time.value = time;
            exprs[i]         = "time("+ TimeToStr(time) +")";
            start.time.description = exprs[i];
            start.time.condition   = true;
         }
         else                                           return(_false(ValidateInputs.OnError("ValidateInputs(35)", "Invalid StartConditions = "+ DoubleQuoteStr(StartConditions), interactive)));

         start.conditions = true;                       // im Erfolgsfall ist start.conditions aktiviert
      }
   }

   // StopConditions, OR combined: @trend(<indicator>:<timeframe>:<params>) | @[bid|ask|median|price](1.33) | @time(12:00) | @profit(1234[%])
   // ---------------------------------------------------------------------------------------------------------------------------------------
   // Bei Parameter�nderung Werte nur �bernehmen, wenn sie sich tats�chlich ge�ndert haben, soda� StopConditions nur bei �nderung (re-)aktiviert werden.
   if (!isParameterChange || StopConditions!=last.StopConditions) {
      stop.trend.condition     = false;
      stop.price.condition     = false;
      stop.time.condition      = false;
      stop.profitAbs.condition = false;
      stop.profitPct.condition = false;

      // StopConditions in einzelne Ausdr�cke zerlegen
      sizeOfExprs = Explode(StrTrim(StopConditions), "||", exprs, NULL);

      // jeden Ausdruck parsen und validieren
      for (i=0; i < sizeOfExprs; i++) {
         expr = StrToLower(StrTrim(exprs[i]));
         if (!StringLen(expr)) {
            if (sizeOfExprs > 1)                        return(_false(ValidateInputs.OnError("ValidateInputs(36)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            break;
         }
         if (StringGetChar(expr, 0) != '@')             return(_false(ValidateInputs.OnError("ValidateInputs(37)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
         if (Explode(expr, "(", elems, NULL) != 2)      return(_false(ValidateInputs.OnError("ValidateInputs(38)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
         if (!StrEndsWith(elems[1], ")"))               return(_false(ValidateInputs.OnError("ValidateInputs(39)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
         key = StrTrim(elems[0]);
         sValue = StrTrim(StrLeft(elems[1], -1));
         if (!StringLen(sValue))                        return(_false(ValidateInputs.OnError("ValidateInputs(40)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));

         if (key == "@trend") {
            if (stop.trend.condition)                   return(_false(ValidateInputs.OnError("ValidateInputs(41)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (multiple trend conditions)", interactive)));
            if (Explode(sValue, ":", elems, NULL) != 3) return(_false(ValidateInputs.OnError("ValidateInputs(42)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            sValue = StrTrim(elems[0]);
            idx = SearchStringArrayI(trendIndicators, sValue);
            if (idx == -1)                              return(_false(ValidateInputs.OnError("ValidateInputs(43)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (unsupported trend indicator "+ DoubleQuoteStr(sValue) +")", interactive)));
            stop.trend.indicator = StrToLower(sValue);
            stop.trend.timeframe = StrToPeriod(elems[1], F_ERR_INVALID_PARAMETER);
            if (stop.trend.timeframe == -1)             return(_false(ValidateInputs.OnError("ValidateInputs(44)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (trend indicator timeframe)", interactive)));
            stop.trend.params = StrTrim(elems[2]);
            if (!StringLen(stop.trend.params))          return(_false(ValidateInputs.OnError("ValidateInputs(45)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (trend indicator parameters)", interactive)));
            exprs[i] = "trend("+ trendIndicators[idx] +":"+ TimeframeDescription(stop.trend.timeframe) +":"+ stop.trend.params +")";
            stop.trend.description = exprs[i];
            stop.trend.condition   = true;
         }

         else if (key=="@bid" || key=="@ask" || key=="@median" || key=="@price") {
            if (stop.price.condition)                   return(_false(ValidateInputs.OnError("ValidateInputs(46)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (multiple price conditions)", interactive)));
            sValue = StrReplace(sValue, "'", "");
            if (!StrIsNumeric(sValue))                  return(_false(ValidateInputs.OnError("ValidateInputs(47)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            dValue = StrToDouble(sValue);
            if (dValue <= 0)                            return(_false(ValidateInputs.OnError("ValidateInputs(48)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            stop.price.value     = NormalizeDouble(dValue, Digits);
            stop.price.lastValue = NULL;
            if      (key == "@bid") stop.price.type = PRICE_BID;
            else if (key == "@ask") stop.price.type = PRICE_ASK;
            else                    stop.price.type = PRICE_MEDIAN;
            exprs[i] = NumberToStr(stop.price.value, PriceFormat);
            exprs[i] = StrSubstr(key, 1) +"("+ StrLeftTo(exprs[i], "'0") +")";   // cut "'0" for improved readability
            stop.price.description = exprs[i];
            stop.price.condition   = true;
         }

         else if (key == "@time") {
            if (stop.time.condition)                    return(_false(ValidateInputs.OnError("ValidateInputs(49)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (multiple time conditions)", interactive)));
            time = StrToTime(sValue);
            if (IsError(GetLastError()))                return(_false(ValidateInputs.OnError("ValidateInputs(50)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            // TODO: Validierung von @time ist unzureichend
            stop.time.value       = time;
            exprs[i]              = "time("+ TimeToStr(time) +")";
            stop.time.description = exprs[i];
            stop.time.condition   = true;
         }

         else if (key == "@profit") {
            if (stop.profitAbs.condition || stop.profitPct.condition)
                                                        return(_false(ValidateInputs.OnError("ValidateInputs(51)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions) +" (multiple profit conditions)", interactive)));
            sizeOfElems = Explode(sValue, "%", elems, NULL);
            if (sizeOfElems > 2)                        return(_false(ValidateInputs.OnError("ValidateInputs(52)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            sValue = StrTrim(elems[0]);
            if (!StringLen(sValue))                     return(_false(ValidateInputs.OnError("ValidateInputs(53)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            if (!StrIsNumeric(sValue))                  return(_false(ValidateInputs.OnError("ValidateInputs(54)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
            dValue = StrToDouble(sValue);
            if (sizeOfElems == 1) {
               stop.profitAbs.value       = NormalizeDouble(dValue, 2);
               exprs[i]                   = "profit("+ DoubleToStr(dValue, 2) +")";
               stop.profitAbs.description = exprs[i];
               stop.profitAbs.condition   = true;
            }
            else {
               stop.profitPct.value       = dValue;
               stop.profitPct.absValue    = INT_MAX;
               exprs[i]                   = "profit("+ NumberToStr(dValue, ".+") +"%)";
               stop.profitPct.description = exprs[i];
               stop.profitPct.condition   = true;
            }
         }
         else                                           return(_false(ValidateInputs.OnError("ValidateInputs(55)", "Invalid StopConditions = "+ DoubleQuoteStr(StopConditions), interactive)));
      }
   }

   // AutoResume:          nothing to validate
   // AutoRestart:         nothing to validate
   // ShowProfitInPercent: nothing to validate

   // Sessionbreak.StartTime/EndTime
   if (Sessionbreak.StartTime!=last.Sessionbreak.StartTime || Sessionbreak.EndTime!=last.Sessionbreak.EndTime) {
      sessionbreak.starttime = NULL;
      sessionbreak.endtime   = NULL;                    // real times are updated automatically on next use
   }

   // reset __STATUS_INVALID_INPUT
   if (interactive)
      __STATUS_INVALID_INPUT = false;
   return(!catch("ValidateInputs(56)"));
}


/**
 * Error-Handler f�r ung�ltige Input-Parameter. Je nach Situation wird der Fehler an den Default-Errorhandler �bergeben
 * oder zur Korrektur aufgefordert.
 *
 * @param  string location    - Ort, an dem der Fehler auftrat
 * @param  string message     - Fehlermeldung
 * @param  bool   interactive - ob der Fehler interaktiv behandelt werden kann
 *
 * @return int - der resultierende Fehlerstatus
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
 * Return the full name of the status file.
 *
 * @return string
 */
string GetStatusFileName() {
   string directory, baseName=StrToLower(StdSymbol()) +".SR."+ sequence.id +".set";

   if (IsTestSequence()) directory = "\\presets\\";
   else                  directory = "\\presets\\"+ ShortAccountCompany() +"\\";

   return(GetMqlFilesPath() + directory + baseName);
}


/**
 * Generate and return a new event id.
 *
 * @return int - new event id
 */
int CreateEventId() {
   lastEventId++;
   return(lastEventId);
}


/**
 * Store the current sequence status to a file. The sequence can be reloaded from such a file (e.g. on terminal restart).
 *
 * @return bool - success status
 */
bool SaveSequence() {
   if (IsLastError())                             return(false);
   if (!sequence.id)                              return(!catch("SaveSequence(1)  illegal value of sequence.id = "+ sequence.id, ERR_RUNTIME_ERROR));
   if (IsTestSequence()) /*&&*/ if (!IsTesting()) return(true);

   // In tester skip updating the status file on most calls; except the first call, after sequence stop and at test end.
   if (IsTesting() && tester.reduceStatusWrites) {
      static bool saved = false;
      if (saved && sequence.status!=STATUS_STOPPED && __WHEREAMI__!=CF_DEINIT) {
         return(true);
      }
      saved = true;
   }

   string sCycle         = StrPadLeft(sequence.cycle, 3, "0");
   string sGridDirection = StrCapitalize(TradeDirectionDescription(sequence.direction));
   string sStarts        = SaveSequence.StartStopToStr(sequence.start.event, sequence.start.time, sequence.start.price, sequence.start.profit);
   string sStops         = SaveSequence.StartStopToStr(sequence.stop.event, sequence.stop.time, sequence.stop.price, sequence.stop.profit);
   string sGridBase      = SaveSequence.GridBaseToStr();
   string sActiveStartConditions="", sActiveStopConditions="";
   SaveSequence.ConditionsToStr(sActiveStartConditions, sActiveStopConditions);

   string file = GetStatusFileName();

   string section = "Common";
   WriteIniString(file, section, "Account",                  ShortAccountCompany() +":"+ GetAccountNumber());
   WriteIniString(file, section, "Symbol",                   Symbol());
   WriteIniString(file, section, "Sequence.ID",              Sequence.ID);
   WriteIniString(file, section, "GridDirection",            sGridDirection);

   section = "SnowRoller-"+ sCycle;
   WriteIniString(file, section, "Created",                  sequence.created);
   WriteIniString(file, section, "GridSize",                 GridSize);
   WriteIniString(file, section, "LotSize",                  NumberToStr(LotSize, ".+"));
   WriteIniString(file, section, "StartLevel",               StartLevel);
   WriteIniString(file, section, "StartConditions",          sActiveStartConditions);
   WriteIniString(file, section, "StopConditions",           sActiveStopConditions);
   WriteIniString(file, section, "AutoResume",               AutoResume);
   WriteIniString(file, section, "AutoRestart",              AutoRestart);
   WriteIniString(file, section, "ShowProfitInPercent",      ShowProfitInPercent);
   WriteIniString(file, section, "Sessionbreak.StartTime",   Sessionbreak.StartTime);
   WriteIniString(file, section, "Sessionbreak.EndTime",     Sessionbreak.EndTime);

   WriteIniString(file, section, "rt.sessionbreak.waiting",  sessionbreak.waiting);
   WriteIniString(file, section, "rt.sequence.startEquity",  DoubleToStr(sequence.startEquity, 2));
   WriteIniString(file, section, "rt.sequence.maxProfit",    DoubleToStr(sequence.maxProfit, 2));
   WriteIniString(file, section, "rt.sequence.maxDrawdown",  DoubleToStr(sequence.maxDrawdown, 2));
   WriteIniString(file, section, "rt.sequence.starts",       sStarts);
   WriteIniString(file, section, "rt.sequence.stops",        sStops);
   WriteIniString(file, section, "rt.gridbase",              sGridBase);
   WriteIniString(file, section, "rt.sequence.missedLevels", JoinInts(sequence.missedLevels));
   WriteIniString(file, section, "rt.ignorePendingOrders",   JoinInts(ignorePendingOrders));
   WriteIniString(file, section, "rt.ignoreOpenPositions",   JoinInts(ignoreOpenPositions));
   WriteIniString(file, section, "rt.ignoreClosedPositions", JoinInts(ignoreClosedPositions));

   // TODO: If ArraySize(orders) ever decreases the file will contain orphaned .ini keys and the logic will break.
   //       - empty the section to write to (but don't delete it to keep its position)
   //       - write section entries
   int size = ArraySize(orders.ticket);
   for (int i=0; i < size; i++) {
      WriteIniString(file, section, "rt.order."+ i, SaveSequence.OrderToStr(i));
   }

   return(!catch("SaveSequence(2)"));
}


/**
 * Return a string representation of active start and stop conditions as stored by SaveSequence(). The returned values don't
 * contain inactive conditions.
 *
 * @param  _Out_ string &startConditions - variable to receive active start conditions
 * @param  _Out_ string &stopConditions  - variable to receive active stop conditions
 */
void SaveSequence.ConditionsToStr(string &startConditions, string &stopConditions) {
   string sValue = "";

   // active start conditions (order: trend, time, price)
   if (start.conditions) {
      if (start.time.condition) {
         sValue = "@"+ start.time.description;
      }
      if (start.price.condition) {
         sValue = sValue + ifString(sValue=="", "", " && ") +"@"+ start.price.description;
      }
      if (start.trend.condition) {
         if (start.time.condition && start.price.condition) {
            sValue = "("+ sValue +")";
         }
         if (start.time.condition || start.price.condition) {
            sValue = " || "+ sValue;
         }
         sValue = "@"+ start.trend.description + sValue;
      }
   }
   startConditions = sValue;

   // active stop conditions (order: trend, time, price, profit)
   sValue = "";
   if (stop.trend.condition) {
      sValue = "@"+ stop.trend.description;
   }
   if (stop.time.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.time.description;
   }
   if (stop.price.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.price.description;
   }
   if (stop.profitAbs.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.profitAbs.description;
   }
   if (stop.profitPct.condition) {
      sValue = sValue + ifString(sValue=="", "", " || ") +"@"+ stop.profitPct.description;
   }
   stopConditions = sValue;
}


/**
 * Return a string representation of sequence starts or stops as stored by SaveSequence().
 *
 * @param  int      events [] - sequence start or stop event ids
 * @param  datetime times  [] - sequence start or stop times
 * @param  double   prices [] - sequence start or stop prices
 * @param  double   profits[] - sequence start or stop profit amounts
 *
 * @return string
 */
string SaveSequence.StartStopToStr(int events[], datetime times[], double prices[], double profits[]) {
   string values[]; ArrayResize(values, 0);
   int size = ArraySize(events);

   for (int i=0; i < size; i++) {
      ArrayPushString(values, StringConcatenate(events[i], "|", times[i], "|", DoubleToStr(prices[i], Digits), "|", DoubleToStr(profits[i], 2)));
   }
   if (!size) ArrayPushString(values, "0|0|0|0");

   string result = JoinStrings(values);
   ArrayResize(values, 0);
   return(result);
}


/**
 * Return a string representation of the gridbase history as stored by SaveSequence().
 *
 * @return string
 */
string SaveSequence.GridBaseToStr() {
   string values[]; ArrayResize(values, 0);
   int size = ArraySize(gridbase.event);

   for (int i=0; i < size; i++) {
      ArrayPushString(values, StringConcatenate(gridbase.event[i], "|", gridbase.time[i], "|", DoubleToStr(gridbase.price[i], Digits)));
   }
   if (!size) ArrayPushString(values, "0|0|0");

   string result = JoinStrings(values);
   ArrayResize(values, 0);
   return(result);
}


/**
 * Return a string representation of an order record as stored by SaveSequence().
 *
 * @param int index - index of the order record
 *
 * @return string
 */
string SaveSequence.OrderToStr(int index) {
   int      ticket       = orders.ticket         [index];
   int      level        = orders.level          [index];
   double   gridBase     = orders.gridBase       [index];
   int      pendingType  = orders.pendingType    [index];
   datetime pendingTime  = orders.pendingTime    [index];
   double   pendingPrice = orders.pendingPrice   [index];
   int      orderType    = orders.type           [index];
   int      openEvent    = orders.openEvent      [index];
   datetime openTime     = orders.openTime       [index];
   double   openPrice    = orders.openPrice      [index];
   int      closeEvent   = orders.closeEvent     [index];
   datetime closeTime    = orders.closeTime      [index];
   double   closePrice   = orders.closePrice     [index];
   double   stopLoss     = orders.stopLoss       [index];
   bool     clientLimit  = orders.clientsideLimit[index];
   bool     closedBySL   = orders.closedBySL     [index];
   double   swap         = orders.swap           [index];
   double   commission   = orders.commission     [index];
   double   profit       = orders.profit         [index];
   return(StringConcatenate(ticket, ",", level, ",", DoubleToStr(gridBase, Digits), ",", pendingType, ",", pendingTime, ",", DoubleToStr(pendingPrice, Digits), ",", orderType, ",", openEvent, ",", openTime, ",", DoubleToStr(openPrice, Digits), ",", closeEvent, ",", closeTime, ",", DoubleToStr(closePrice, Digits), ",", DoubleToStr(stopLoss, Digits), ",", clientLimit, ",", closedBySL, ",", DoubleToStr(swap, 2), ",", DoubleToStr(commission, 2), ",", DoubleToStr(profit, 2)));
}


/**
 * Write a configuration value to an .ini file. If the file does not exist an attempt is made to create it.
 *
 * @param  string fileName - name of the file (with any extension)
 * @param  string section  - case-insensitive configuration section name
 * @param  string key      - case-insensitive configuration key
 * @param  string value    - configuration value
 *
 * @return bool - success status
 */
bool WriteIniString(string fileName, string section, string key, string value) {
   if (!WritePrivateProfileStringA(section, key, value, fileName)) {
      int error = GetLastWin32Error();

      if (error == ERROR_PATH_NOT_FOUND) {
         string name = StrReplace(fileName, "\\", "/");
         string directory = StrLeftTo(name, "/", -1);

         if (directory!=name) /*&&*/ if (!IsDirectoryA(directory)) {
            error = CreateDirectoryRecursive(directory);
            if (IsError(error)) return(!catch("WriteIniString(1)  cannot create directory "+ DoubleQuoteStr(directory), ERR_WIN32_ERROR+error));
            return(WriteIniString(fileName, section, key, value));
         }
      }
      return(!catch("WriteIniString(2)->WritePrivateProfileString(fileName="+ DoubleQuoteStr(fileName) +")", ERR_WIN32_ERROR+error));
   }
   return(true);
}


/**
 *
 * @param  bool interactive - whether input parameters have been entered through the input dialog
 *
 * @return bool - success status
 */
bool RestoreSequence(bool interactive) {
   interactive = interactive!=0;
   if (IsLastError())                return(false);

   OutputDebugStringA("RestoreSequence(0.1)->ReadStatus()...");

   bool success = ReadStatus();

   OutputDebugStringA("RestoreSequence(0.2)  OK");

   if (!success)                     return(false);      // read the status file
   if (!ValidateInputs(interactive)) return(false);      // validate restored input parameters
   if (!SynchronizeStatus())         return(false);      // synchronize restored state with trade server state
   return(true);
}


/**
 * Restore the internal state of the current sequence from the sequence's status file. Always part of RestoreSequence().
 *
 * @return bool - success status
 */
bool ReadStatus() {
   string file = "F:\\Projects\\mt4\\mql\\mql4\\files\\presets\\xauusd.SR.5462.set";

   string section = "Common";
   string sAccount       = GetIniStringRawA(file, section, "Account",       "");
   string sSymbol        = GetIniStringRawA(file, section, "Symbol",        "");
   string sSequenceId    = GetIniStringRawA(file, section, "Sequence.ID",   "");
   string sGridDirection = GetIniStringRawA(file, section, "GridDirection", "");

   section = "SnowRoller-001";
   string sCreated               = GetIniStringRawA(file, section, "Created",                "");     // string   Created=Tue, 2019.09.24 01:00:00
   string sGridSize              = GetIniStringRawA(file, section, "GridSize",               "");     // int      GridSize=20
   string sLotSize               = GetIniStringRawA(file, section, "LotSize",                "");     // double   LotSize=0.01
   string sStartLevel            = GetIniStringRawA(file, section, "StartLevel",             "");     // int      StartLevel=0
   string sStartConditions       = GetIniStringRawA(file, section, "StartConditions",        "");     // string   StartConditions=@trend(HalfTrend:H1:3)
   string sStopConditions        = GetIniStringRawA(file, section, "StopConditions",         "");     // string   StopConditions=@trend(HalfTrend:H1:3) || @profit(2%)
   string sAutoResume            = GetIniStringRawA(file, section, "AutoResume",             "");     // bool     AutoResume=1
   string sAutoRestart           = GetIniStringRawA(file, section, "AutoRestart",            "");     // bool     AutoRestart=1
   string sShowProfitInPercent   = GetIniStringRawA(file, section, "ShowProfitInPercent",    "");     // bool     ShowProfitInPercent=1
   string sSessionbreakStartTime = GetIniStringRawA(file, section, "Sessionbreak.StartTime", "");     // datetime Sessionbreak.StartTime=86160
   string sSessionbreakEndTime   = GetIniStringRawA(file, section, "Sessionbreak.EndTime",   "");     // datetime Sessionbreak.EndTime=3730

   string sSessionbreakWaiting   = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string sStartEquity           = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string sMaxProfit             = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string sMaxDrawdown           = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string sStarts                = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string sStops                 = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string sGridBase              = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string sMissedLevels          = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string sPendingOrders         = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string sOpenPositions         = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string sClosedOrders          = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s2SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s2StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s2MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s2MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s2Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s2Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s2GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s2MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s2PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s2OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s2ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s3SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s3StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s3MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s3MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s3Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s3Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s3GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s3MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s3PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s3OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s3ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s4SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s4StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s4MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s4MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s4Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s4Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s4GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s4MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s4PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s4OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s4ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s5SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s5StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s5MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s5MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s5Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s5Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s5GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s5MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s5PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s5OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s5ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s6SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s6StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s6MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s6MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s6Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s6Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s6GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s6MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s6PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s6OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s6ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s7SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s7StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s7MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s7MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s7Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s7Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s7GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s7MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s7PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s7OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s7ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s8SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s8StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s8MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s8MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s8Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s8Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s8GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s8MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s8PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s8OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s8ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s9SessionbreakWaiting  = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s9StartEquity          = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s9MaxProfit            = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s9MaxDrawdown          = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s9Starts               = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s9Stops                = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s9GridBase             = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s9MissedLevels         = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s9PendingOrders        = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s9OpenPositions        = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s9ClosedOrders         = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s10SessionbreakWaiting = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s10StartEquity         = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s10MaxProfit           = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s10MaxDrawdown         = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s10Starts              = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s10Stops               = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s10GridBase            = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s10MissedLevels        = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s10PendingOrders       = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s10OpenPositions       = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s10ClosedOrders        = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s11SessionbreakWaiting = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s11StartEquity         = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s11MaxProfit           = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s11MaxDrawdown         = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s11Starts              = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s11Stops               = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s11GridBase            = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s11MissedLevels        = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s11PendingOrders       = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s11OpenPositions       = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s11ClosedOrders        = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892

   string s12SessionbreakWaiting = GetIniStringRawA(file, section, "rt.sessionbreak.waiting",  "");     // bool    rt.sessionbreak.waiting=1
   string s12StartEquity         = GetIniStringRawA(file, section, "rt.sequence.startEquity",  "");     // double  rt.sequence.startEquity=7801.13
   string s12MaxProfit           = GetIniStringRawA(file, section, "rt.sequence.maxProfit",    "");     // double  rt.sequence.maxProfit=200.13
   string s12MaxDrawdown         = GetIniStringRawA(file, section, "rt.sequence.maxDrawdown",  "");     // double  rt.sequence.maxDrawdown=-127.80
   string s12Starts              = GetIniStringRawA(file, section, "rt.sequence.starts",       "");     // mixed[] rt.sequence.starts=1|1328701713|1.32677|1000.00, 3|1329999999|1.33215|1200.00
   string s12Stops               = GetIniStringRawA(file, section, "rt.sequence.stops",        "");     // mixed[] rt.sequence.stops= 2|1328701999|1.32734|1200.00, 0|0|0.00000|0.00
   string s12GridBase            = GetIniStringRawA(file, section, "rt.gridbase",              "");     // mixed[] rt.gridbase= 4|1331710960|1.56743, 5|1331711010|1.56714
   string s12MissedLevels        = GetIniStringRawA(file, section, "rt.sequence.missedLevels", "");     // int[]   rt.sequence.missedLevels=-6,-7,-8,-14
   string s12PendingOrders       = GetIniStringRawA(file, section, "rt.ignorePendingOrders",   "");     // int[]   rt.ignorePendingOrders=66064890,66064891,66064892
   string s12OpenPositions       = GetIniStringRawA(file, section, "rt.ignoreOpenPositions",   "");     // int[]   rt.ignoreOpenPositions=66064890,66064891,66064892
   string s12ClosedOrders        = GetIniStringRawA(file, section, "rt.ignoreClosedPositions", "");     // int[]   rt.ignoreClosedPositions=66064890,66064891,66064892


   OutputDebugStringA("ReadStatus(0.1)  leave");
   last_error = ERR_CANCELLED_BY_USER;
   return(!last_error);

   ReadStatus.Runtime("rt.{key}", "rt.{value}");
   if (IntInArray(orders.ticket, 0)) return(_false(catch("ReadStatus(19)  one or more order entries missing in file \""+ file +"\"", ERR_RUNTIME_ERROR)));
   return(!catch("ReadStatus(20)"));
}


/**
 * Restauriert eine oder mehrere Laufzeitvariablen.
 *
 * @param  string key   - Schl�ssel der Einstellung
 * @param  string value - Wert der Einstellung
 *
 * @return bool - success status
 */
bool ReadStatus.Runtime(string key, string value) {
   return(false);
}


/**
 * Gleicht den in der Instanz gespeicherten Laufzeitstatus mit den Online-Daten der Sequenz ab.
 * Aufruf nur direkt nach ValidateInputs()
 *
 * @return bool - Erfolgsstatus
 */
bool SynchronizeStatus() {
   if (IsLastError()) return(false);

   bool permanentStatusChange, permanentTicketChange, pendingOrder, openPosition;

   int orphanedPendingOrders  []; ArrayResize(orphanedPendingOrders,   0);
   int orphanedOpenPositions  []; ArrayResize(orphanedOpenPositions,   0);
   int orphanedClosedPositions[]; ArrayResize(orphanedClosedPositions, 0);

   int closed[][2], close[2], sizeOfTickets=ArraySize(orders.ticket); ArrayResize(closed, 0);


   // (1.1) alle offenen Tickets in Datenarrays synchronisieren, gestrichene PendingOrders l�schen
   for (int i=0; i < sizeOfTickets; i++) {
      if (orders.ticket[i] < 0)                                            // client-seitige PendingOrders �berspringen
         continue;

      if (!IsTestSequence() || !IsTesting()) {                             // keine Synchronization f�r abgeschlossene Tests
         if (orders.closeTime[i] == 0) {
            if (!IsTicket(orders.ticket[i])) {                             // bei fehlender History zur Erweiterung auffordern
               PlaySoundEx("Windows Notify.wav");
               int button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", "Ticket #"+ orders.ticket[i] +" not found.\nPlease expand the available trade history.", MB_ICONERROR|MB_RETRYCANCEL);
               if (button != IDRETRY)
                  return(!SetLastError(ERR_CANCELLED_BY_USER));
               return(SynchronizeStatus());
            }
            if (!SelectTicket(orders.ticket[i], "SynchronizeStatus(1)  cannot synchronize "+ OperationTypeDescription(ifInt(orders.type[i]==OP_UNDEFINED, orders.pendingType[i], orders.type[i])) +" order (#"+ orders.ticket[i] +" not found)"))
               return(false);
            if (!Sync.UpdateOrder(i, permanentTicketChange))
               return(false);
            permanentStatusChange = permanentStatusChange || permanentTicketChange;
         }
      }

      if (orders.closeTime[i] != 0) {
         if (orders.type[i] == OP_UNDEFINED) {
            if (!Grid.DropData(i))                                         // geschlossene PendingOrders l�schen
               return(false);
            sizeOfTickets--; i--;
            permanentStatusChange = true;
         }
         else if (!orders.closedBySL[i]) /*&&*/ if (!orders.closeEvent[i]) {
            close[0] = orders.closeTime[i];                                // bei StopSequence() geschlossene Position: Ticket zur sp�teren Vergabe der Event-ID zwichenspeichern
            close[1] = orders.ticket   [i];
            ArrayPushInts(closed, close);
         }
      }
   }

   // (1.2) Event-IDs geschlossener Positionen setzen (IDs f�r ausgestoppte Positionen wurden vorher in Sync.UpdateOrder() vergeben)
   int sizeOfClosed = ArrayRange(closed, 0);
   if (sizeOfClosed > 0) {
      ArraySort(closed);
      for (i=0; i < sizeOfClosed; i++) {
         int n = SearchIntArray(orders.ticket, closed[i][1]);
         if (n == -1)
            return(_false(catch("SynchronizeStatus(2)  closed ticket #"+ closed[i][1] +" not found in order arrays", ERR_RUNTIME_ERROR)));
         orders.closeEvent[n] = CreateEventId();
      }
      ArrayResize(closed, 0);
      ArrayResize(close,  0);
   }

   // (1.3) alle erreichbaren Tickets der Sequenz auf lokale Referenz �berpr�fen (au�er f�r abgeschlossene Tests)
   if (!IsTestSequence() || IsTesting()) {
      for (i=OrdersTotal()-1; i >= 0; i--) {                               // offene Tickets
         if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))                  // FALSE: w�hrend des Auslesens wurde in einem anderen Thread eine offene Order entfernt
            continue;
         if (IsMyOrder(sequence.id)) /*&&*/ if (!IntInArray(orders.ticket, OrderTicket())) {
            pendingOrder = IsPendingOrderType(OrderType());                // kann PendingOrder oder offene Position sein
            openPosition = !pendingOrder;
            if (pendingOrder) /*&&*/ if (!IntInArray(ignorePendingOrders, OrderTicket())) ArrayPushInt(orphanedPendingOrders, OrderTicket());
            if (openPosition) /*&&*/ if (!IntInArray(ignoreOpenPositions, OrderTicket())) ArrayPushInt(orphanedOpenPositions, OrderTicket());
         }
      }

      for (i=OrdersHistoryTotal()-1; i >= 0; i--) {                        // geschlossene Tickets
         if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))                 // FALSE: w�hrend des Auslesens wurde der Anzeigezeitraum der History verk�rzt
            continue;
         if (IsPendingOrderType(OrderType()))                              // gestrichene PendingOrders ignorieren
            continue;
         if (IsMyOrder(sequence.id)) /*&&*/ if (!IntInArray(orders.ticket, OrderTicket())) {
            if (!IntInArray(ignoreClosedPositions, OrderTicket()))         // kann nur geschlossene Position sein
               ArrayPushInt(orphanedClosedPositions, OrderTicket());
         }
      }
   }

   // (1.4) Vorgehensweise f�r verwaiste Tickets erfragen
   int size = ArraySize(orphanedPendingOrders);                            // TODO: Ignorieren nicht m�glich; wenn die Tickets �bernommen werden sollen,
   if (size > 0) {                                                         //       m�ssen sie richtig einsortiert werden.
      return(_false(catch("SynchronizeStatus(3)  unknown pending orders found: #"+ JoinInts(orphanedPendingOrders, ", #"), ERR_RUNTIME_ERROR)));
      //ArraySort(orphanedPendingOrders);
      //PlaySoundEx("Windows Notify.wav");
      //int button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Orphaned pending order"+ ifString(size==1, "", "s") +" found: #"+ JoinInts(orphanedPendingOrders, ", #") +"\nDo you want to ignore "+ ifString(size==1, "it", "them") +"?", MB_ICONWARNING|MB_OKCANCEL);
      //if (button != IDOK) {
      //   SetLastError(ERR_CANCELLED_BY_USER);
      //   return(_false(catch("SynchronizeStatus(4)")));
      //}
      ArrayResize(orphanedPendingOrders, 0);
   }
   size = ArraySize(orphanedOpenPositions);                                // TODO: Ignorieren nicht m�glich; wenn die Tickets �bernommen werden sollen,
   if (size > 0) {                                                         //       m�ssen sie richtig einsortiert werden.
      return(_false(catch("SynchronizeStatus(5)  unknown open positions found: #"+ JoinInts(orphanedOpenPositions, ", #"), ERR_RUNTIME_ERROR)));
      //ArraySort(orphanedOpenPositions);
      //PlaySoundEx("Windows Notify.wav");
      //button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Orphaned open position"+ ifString(size==1, "", "s") +" found: #"+ JoinInts(orphanedOpenPositions, ", #") +"\nDo you want to ignore "+ ifString(size==1, "it", "them") +"?", MB_ICONWARNING|MB_OKCANCEL);
      //if (button != IDOK) {
      //   SetLastError(ERR_CANCELLED_BY_USER);
      //   return(_false(catch("SynchronizeStatus(6)")));
      //}
      ArrayResize(orphanedOpenPositions, 0);
   }
   size = ArraySize(orphanedClosedPositions);
   if (size > 0) {
      ArraySort(orphanedClosedPositions);
      PlaySoundEx("Windows Notify.wav");
      button = MessageBoxEx(__NAME() +" - SynchronizeStatus()", ifString(IsDemoFix(), "", "- Real Account -\n\n") +"Orphaned closed position"+ ifString(size==1, "", "s") +" found: #"+ JoinInts(orphanedClosedPositions, ", #") +"\nDo you want to ignore "+ ifString(size==1, "it", "them") +"?", MB_ICONWARNING|MB_OKCANCEL);
      if (button != IDOK) {
         SetLastError(ERR_CANCELLED_BY_USER);
         return(_false(catch("SynchronizeStatus(7)")));
      }
      MergeIntArrays(ignoreClosedPositions, orphanedClosedPositions, ignoreClosedPositions);
      ArraySort(ignoreClosedPositions);
      permanentStatusChange = true;
      ArrayResize(orphanedClosedPositions, 0);
   }

   if (ArraySize(sequence.start.event) > 0) /*&&*/ if (ArraySize(gridbase.event)==0)
      return(_false(catch("SynchronizeStatus(8)  illegal number of gridbase events = "+ 0, ERR_RUNTIME_ERROR)));


   // Status und Variablen synchronisieren
   /*int   */ lastEventId         = 0;
   /*int   */ sequence.status     = STATUS_WAITING;
   /*int   */ sequence.level      = 0;
   /*int   */ sequence.maxLevel   = 0;
   /*int   */ sequence.stops      = 0;
   /*double*/ sequence.stopsPL    = 0;
   /*double*/ sequence.closedPL   = 0;
   /*double*/ sequence.floatingPL = 0;
   /*double*/ sequence.totalPL    = 0;

   datetime   stopTime;
   double     stopPrice;

   if (!Sync.ProcessEvents(stopTime, stopPrice))
      return(false);

   // Wurde die Sequenz au�erhalb gestoppt, EV_SEQUENCE_STOP erzeugen
   if (sequence.status == STATUS_STOPPING) {
      i = ArraySize(sequence.stop.event) - 1;
      if (sequence.stop.time[i] != 0)
         return(_false(catch("SynchronizeStatus(9)  unexpected sequence.stop.time = "+ IntsToStr(sequence.stop.time, NULL), ERR_RUNTIME_ERROR)));

      sequence.stop.event [i] = CreateEventId();
      sequence.stop.time  [i] = stopTime;
      sequence.stop.price [i] = NormalizeDouble(stopPrice, Digits);
      sequence.stop.profit[i] = sequence.totalPL;

      sequence.status       = STATUS_STOPPED;
      permanentStatusChange = true;
   }

   // update status
   if (sequence.status == STATUS_STOPPED) {
      if (start.conditions) sequence.status = STATUS_WAITING;
   }
   if (sessionbreak.waiting) {
      if (sequence.status == STATUS_STOPPED) sequence.status = STATUS_WAITING;
      if (sequence.status != STATUS_WAITING) return(_false(catch("SynchronizeStatus(10)  sessionbreak.waiting="+ sessionbreak.waiting +" / sequence.status="+ StatusToStr(sequence.status)+ " mis-match", ERR_RUNTIME_ERROR)));
   }

   // store status changes
   if (permanentStatusChange)
      if (!SaveSequence()) return(false);

   // update chart displays, ShowStatus() is called at the end of EA::init()
   RedrawStartStop();
   RedrawOrders();

   return(!catch("SynchronizeStatus(11)"));
}


/**
 * Aktualisiert die Daten des lokal als offen markierten Tickets mit dem Online-Status. Wird nur in SynchronizeStatus() verwendet.
 *
 * @param  int   i                 - Ticketindex
 * @param  bool &lpPermanentChange - Zeiger auf Variable, die anzeigt, ob dauerhafte Ticket�nderungen vorliegen
 *
 * @return bool - success status
 */
bool Sync.UpdateOrder(int i, bool &lpPermanentChange) {
   lpPermanentChange = lpPermanentChange!=0;

   if (i < 0 || i > ArraySize(orders.ticket)-1) return(!catch("Sync.UpdateOrder(1)  illegal parameter i = "+ i, ERR_INVALID_PARAMETER));
   if (orders.closeTime[i] != 0)                return(!catch("Sync.UpdateOrder(2)  cannot update ticket #"+ orders.ticket[i] +" (marked as closed in grid arrays)", ERR_ILLEGAL_STATE));

   // das Ticket ist selektiert
   bool   wasPending = orders.type[i] == OP_UNDEFINED;               // vormals PendingOrder
   bool   wasOpen    = !wasPending;                                  // vormals offene Position
   bool   isPending  = IsPendingOrderType(OrderType());              // jetzt PendingOrder
   bool   isClosed   = OrderCloseTime() != 0;                        // jetzt geschlossen oder gestrichen
   bool   isOpen     = !isPending && !isClosed;                      // jetzt offene Position
   double lastSwap   = orders.swap[i];

   // Ticketdaten aktualisieren
   //orders.ticket       [i]                                         // unver�ndert
   //orders.level        [i]                                         // unver�ndert
   //orders.gridBase     [i]                                         // unver�ndert

   if (isPending) {
    //orders.pendingType [i]                                         // unver�ndert
    //orders.pendingTime [i]                                         // unver�ndert
      orders.pendingPrice[i] = OrderOpenPrice();
   }
   else if (wasPending) {
      orders.type        [i] = OrderType();
      orders.openEvent   [i] = CreateEventId();
      orders.openTime    [i] = OrderOpenTime();
      orders.openPrice   [i] = OrderOpenPrice();
   }

   if (EQ(OrderStopLoss(), 0)) {
      if (!orders.clientsideLimit[i]) {
         orders.stopLoss       [i] = NormalizeDouble(gridbase + (orders.level[i]-Sign(orders.level[i]))*GridSize*Pips, Digits);
         orders.clientsideLimit[i] = true;
         lpPermanentChange         = true;
      }
   }
   else {
      orders.stopLoss[i] = OrderStopLoss();
      if (orders.clientsideLimit[i]) {
         orders.clientsideLimit[i] = false;
         lpPermanentChange         = true;
      }
   }

   if (isClosed) {
      orders.closeTime   [i] = OrderCloseTime();
      orders.closePrice  [i] = OrderClosePrice();
      orders.closedBySL  [i] = IsOrderClosedBySL();
      if (orders.closedBySL[i])
         orders.closeEvent[i] = CreateEventId();                     // Event-IDs f�r ausgestoppte Positionen werden sofort, f�r geschlossene Positionen erst sp�ter vergeben.
   }

   if (!isPending) {
      orders.swap        [i] = OrderSwap();
      orders.commission  [i] = OrderCommission(); sequence.commission = OrderCommission(); SS.LotSize();
      orders.profit      [i] = OrderProfit();
   }

   // lpPermanentChange aktualisieren
   if      (wasPending) lpPermanentChange = lpPermanentChange || isOpen || isClosed;
   else if (  isClosed) lpPermanentChange = true;
   else                 lpPermanentChange = lpPermanentChange || NE(lastSwap, OrderSwap());

   return(!catch("Sync.UpdateOrder(3)"));
}


/**
 * F�gt den Breakeven-relevanten Events ein weiteres hinzu.
 *
 * @param  double   events[] - Event-Array
 * @param  int      id       - Event-ID
 * @param  datetime time     - Zeitpunkt des Events
 * @param  int      type     - Event-Typ
 * @param  double   gridBase - Gridbasis des Events
 * @param  int      index    - Index des origin�ren Datensatzes innerhalb des entsprechenden Arrays
 */
void Sync.PushEvent(double &events[][], int id, datetime time, int type, double gridBase, int index) {
   if (type==EV_SEQUENCE_STOP) /*&&*/ if (!time)
      return;                                                        // nicht initialisierte Sequenz-Stops ignorieren (ggf. immer der letzte Stop)

   int size = ArrayRange(events, 0);
   ArrayResize(events, size+1);

   events[size][0] = id;
   events[size][1] = time;
   events[size][2] = type;
   events[size][3] = gridBase;
   events[size][4] = index;
}


/**
 *
 * @param  datetime &sequenceStopTime  - Variable, die die Sequenz-StopTime aufnimmt (falls die Stopdaten fehlen)
 * @param  double   &sequenceStopPrice - Variable, die den Sequenz-StopPrice aufnimmt (falls die Stopdaten fehlen)
 *
 * @return bool - success status
 */
bool Sync.ProcessEvents(datetime &sequenceStopTime, double &sequenceStopPrice) {
   int    sizeOfTickets = ArraySize(orders.ticket);
   int    openLevels[]; ArrayResize(openLevels, 0);
   double events[][5];  ArrayResize(events,     0);
   bool   pendingOrder, openPosition, closedPosition, closedBySL;


   // (1) Breakeven-relevante Events zusammenstellen
   // (1.1) Sequenzstarts und -stops
   int sizeOfStarts = ArraySize(sequence.start.event);
   for (int i=0; i < sizeOfStarts; i++) {
    //Sync.PushEvent(events, id, time, type, gridBase, index);
      Sync.PushEvent(events, sequence.start.event[i], sequence.start.time[i], EV_SEQUENCE_START, NULL, i);
      Sync.PushEvent(events, sequence.stop.event [i], sequence.stop.time [i], EV_SEQUENCE_STOP,  NULL, i);
   }

   // (1.2) GridBase-�nderungen
   int sizeOfGridBase = ArraySize(gridbase.event);
   for (i=0; i < sizeOfGridBase; i++) {
      Sync.PushEvent(events, gridbase.event[i], gridbase.time[i], EV_GRIDBASE_CHANGE, gridbase.price[i], i);
   }

   // (1.3) Tickets
   for (i=0; i < sizeOfTickets; i++) {
      pendingOrder   = orders.type[i]  == OP_UNDEFINED;
      openPosition   = !pendingOrder   && orders.closeTime[i]==0;
      closedPosition = !pendingOrder   && !openPosition;
      closedBySL     =  closedPosition && orders.closedBySL[i];

      // nach offenen Levels darf keine geschlossene Position folgen
      if (closedPosition && !closedBySL)
         if (ArraySize(openLevels) > 0)                  return(_false(catch("Sync.ProcessEvents(1)  illegal sequence status, both open (#?) and closed (#"+ orders.ticket[i] +") positions found", ERR_RUNTIME_ERROR)));

      if (!pendingOrder) {
         Sync.PushEvent(events, orders.openEvent[i], orders.openTime[i], EV_POSITION_OPEN, NULL, i);

         if (openPosition) {
            if (IntInArray(openLevels, orders.level[i])) return(_false(catch("Sync.ProcessEvents(2)  duplicate order level "+ orders.level[i] +" of open position #"+ orders.ticket[i], ERR_RUNTIME_ERROR)));
            ArrayPushInt(openLevels, orders.level[i]);
            sequence.floatingPL = NormalizeDouble(sequence.floatingPL + orders.swap[i] + orders.commission[i] + orders.profit[i], 2);
         }
         else if (closedBySL) {
            Sync.PushEvent(events, orders.closeEvent[i], orders.closeTime[i], EV_POSITION_STOPOUT, NULL, i);
         }
         else /*(closed)*/ {
            Sync.PushEvent(events, orders.closeEvent[i], orders.closeTime[i], EV_POSITION_CLOSE, NULL, i);
         }
      }
      if (IsLastError()) return(false);
   }
   if (ArraySize(openLevels) != 0) {
      int min = openLevels[ArrayMinimum(openLevels)];
      int max = openLevels[ArrayMaximum(openLevels)];
      int maxLevel = Max(Abs(min), Abs(max));
      if (ArraySize(openLevels) != maxLevel) return(_false(catch("Sync.ProcessEvents(3)  illegal sequence status, missing one or more open positions", ERR_RUNTIME_ERROR)));
      ArrayResize(openLevels, 0);
   }


   // (2) Laufzeitvariablen restaurieren
   int      id, lastId, nextId, minute, lastMinute, type, lastType, nextType, index, nextIndex, iPositionMax, ticket, lastTicket, nextTicket, closedPositions, reopenedPositions;
   datetime time, lastTime, nextTime;
   double   gridBase;
   int      orderEvents[] = {EV_POSITION_OPEN, EV_POSITION_STOPOUT, EV_POSITION_CLOSE};
   int      sizeOfEvents = ArrayRange(events, 0);

   // (2.1) Events sortieren
   if (sizeOfEvents > 0) {
      ArraySort(events);
      int firstType = MathRound(events[0][2]);
      if (firstType != EV_SEQUENCE_START) return(_false(catch("Sync.ProcessEvents(4)  illegal first status event "+ StatusEventToStr(firstType) +" (id="+ Round(events[0][0]) +"   time='"+ TimeToStr(events[0][1], TIME_FULL) +"')", ERR_RUNTIME_ERROR)));
   }

   for (i=0; i < sizeOfEvents; i++) {
      id       = events[i][0];
      time     = events[i][1];
      type     = events[i][2];
      gridBase = events[i][3];
      index    = events[i][4];

      ticket     = 0; if (IntInArray(orderEvents, type)) { ticket = orders.ticket[index]; iPositionMax = Max(iPositionMax, index); }
      nextTicket = 0;
      if (i < sizeOfEvents-1) { nextId = events[i+1][0]; nextTime = events[i+1][1]; nextType = events[i+1][2]; nextIndex = events[i+1][4]; if (IntInArray(orderEvents, nextType)) nextTicket = orders.ticket[nextIndex]; }
      else                    { nextId = 0;              nextTime = 0;              nextType = 0;                                                                                               nextTicket = 0;                        }

      // (2.2) Events auswerten
      // -- EV_SEQUENCE_START --------------
      if (type == EV_SEQUENCE_START) {
         if (i && sequence.status!=STATUS_STARTING && sequence.status!=STATUS_STOPPED)   return(_false(catch("Sync.ProcessEvents(5)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (sequence.status==STATUS_STARTING && reopenedPositions!=Abs(sequence.level)) return(_false(catch("Sync.ProcessEvents(6)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") and before "+ StatusEventToStr(nextType) +" ("+ nextId +", "+ ifString(nextTicket, "#"+ nextTicket +", ", "") +"time="+ nextTime +", "+ TimeToStr(nextTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         reopenedPositions = 0;
         sequence.status   = STATUS_PROGRESSING;
         sequence.start.event[index] = id;
      }
      // -- EV_GRIDBASE_CHANGE -------------
      else if (type == EV_GRIDBASE_CHANGE) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPED)     return(_false(catch("Sync.ProcessEvents(7)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         gridbase = gridBase;
         if (sequence.status == STATUS_PROGRESSING) {
            if (sequence.level != 0)                                                     return(_false(catch("Sync.ProcessEvents(8)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         }
         else { // STATUS_STOPPED
            reopenedPositions = 0;
            sequence.status   = STATUS_STARTING;
         }
         gridbase.event[index] = id;
      }
      // -- EV_POSITION_OPEN ---------------
      else if (type == EV_POSITION_OPEN) {
         if (sequence.status!=STATUS_STARTING && sequence.status!=STATUS_PROGRESSING)    return(_false(catch("Sync.ProcessEvents(9)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (sequence.status == STATUS_PROGRESSING) {                                    // nicht bei PositionReopen
            sequence.level   += Sign(orders.level[index]);
            sequence.maxLevel = ifInt(sequence.direction==D_LONG, Max(sequence.level, sequence.maxLevel), Min(sequence.level, sequence.maxLevel));
         }
         else {
            reopenedPositions++;
         }
         orders.openEvent[index] = id;
      }
      // -- EV_POSITION_STOPOUT ------------
      else if (type == EV_POSITION_STOPOUT) {
         if (sequence.status != STATUS_PROGRESSING)                                      return(_false(catch("Sync.ProcessEvents(10)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         sequence.level  -= Sign(orders.level[index]);
         sequence.stops++;
         sequence.stopsPL = NormalizeDouble(sequence.stopsPL + orders.swap[index] + orders.commission[index] + orders.profit[index], 2);
         orders.closeEvent[index] = id;
      }
      // -- EV_POSITION_CLOSE --------------
      else if (type == EV_POSITION_CLOSE) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING)    return(_false(catch("Sync.ProcessEvents(11)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         sequence.closedPL = NormalizeDouble(sequence.closedPL + orders.swap[index] + orders.commission[index] + orders.profit[index], 2);
         if (sequence.status == STATUS_PROGRESSING)
            closedPositions = 0;
         closedPositions++;
         sequence.status = STATUS_STOPPING;
         orders.closeEvent[index] = id;
      }
      // -- EV_SEQUENCE_STOP ---------------
      else if (type == EV_SEQUENCE_STOP) {
         if (sequence.status!=STATUS_PROGRESSING && sequence.status!=STATUS_STOPPING)    return(_false(catch("Sync.ProcessEvents(12)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         if (closedPositions != Abs(sequence.level))                                     return(_false(catch("Sync.ProcessEvents(13)  illegal status event "+ StatusEventToStr(type) +" ("+ id +", "+ ifString(ticket, "#"+ ticket +", ", "") +"time="+ TimeToStr(time, TIME_FULL) +") after "+ StatusEventToStr(lastType) +" ("+ lastId +", "+ ifString(lastTicket, "#"+ lastTicket +", ", "") +"time="+ TimeToStr(lastTime, TIME_FULL) +") and before "+ StatusEventToStr(nextType) +" ("+ nextId +", "+ ifString(nextTicket, "#"+ nextTicket +", ", "") +"time="+ nextTime +", "+ TimeToStr(nextTime, TIME_FULL) +") in "+ StatusToStr(sequence.status) +" at level "+ sequence.level, ERR_RUNTIME_ERROR)));
         closedPositions = 0;
         sequence.status = STATUS_STOPPED;
         sequence.stop.event[index] = id;
      }
      // -----------------------------------
      sequence.totalPL = NormalizeDouble(sequence.stopsPL + sequence.closedPL + sequence.floatingPL, 2);

      lastId     = id;
      lastTime   = time;
      lastType   = type;
      lastTicket = ticket;
   }
   lastEventId = id;


   // (4) Wurde die Sequenz au�erhalb gestoppt, fehlende Stop-Daten ermitteln
   if (sequence.status == STATUS_STOPPING) {
      if (closedPositions != Abs(sequence.level)) return(_false(catch("Sync.ProcessEvents(14)  unexpected number of closed positions in "+ StatusDescription(sequence.status) +" sequence", ERR_RUNTIME_ERROR)));

      // (4.1) Stopdaten ermitteln
      int level = Abs(sequence.level);
      double stopPrice;
      for (i=sizeOfEvents-level; i < sizeOfEvents; i++) {
         time  = events[i][1];
         type  = events[i][2];
         index = events[i][4];
         if (type != EV_POSITION_CLOSE)
            return(_false(catch("Sync.ProcessEvents(15)  unexpected "+ StatusEventToStr(type) +" at index "+ i, ERR_RUNTIME_ERROR)));
         stopPrice += orders.closePrice[index];
      }
      stopPrice /= level;

      // (4.2) Stopdaten zur�ckgeben
      sequenceStopTime  = time;
      sequenceStopPrice = NormalizeDouble(stopPrice, Digits);
   }

   ArrayResize(events,      0);
   ArrayResize(orderEvents, 0);
   return(!catch("Sync.ProcessEvents(16)"));
}


/**
 * Redraw the sequence's start/stop marker.
 */
void RedrawStartStop() {
   if (!__CHART()) return;

   datetime time;
   double   price;
   double   profit;
   string   label;
   int starts = ArraySize(sequence.start.event);

   // start
   for (int i=0; i < starts; i++) {
      time   = sequence.start.time  [i];
      price  = sequence.start.price [i];
      profit = sequence.start.profit[i];

      label = "SR."+ sequence.id +".start."+ (i+1);
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

   // stop
   for (i=0; i < starts; i++) {
      if (sequence.stop.time[i] > 0) {
         time   = sequence.stop.time [i];
         price  = sequence.stop.price[i];
         profit = sequence.stop.profit[i];

         label = "SR."+ sequence.id +".stop."+ (i+1);
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
 * Zeichnet die ChartMarker aller Orders neu.
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
      else /*openPosition || closedPosition*/ {                                  // openPosition ist Folge einer
         if (wasPending)                        Chart.MarkOrderFilled(i);        // ...ausgef�hrten Pending-Order
         else                                   Chart.MarkOrderSent(i);          // ...oder Market-Order
         if (closedPosition)                    Chart.MarkPositionClosed(i);
      }
   }
}


/**
 * Wechselt den Modus der Start/Stopanzeige.
 *
 * @return int - Fehlerstatus
 */
int ToggleStartStopDisplayMode() {
   // Mode wechseln
   int i = SearchIntArray(startStopDisplayModes, startStopDisplayMode);    // #define SDM_NONE        - keine Anzeige -
   if (i == -1) {                                                          // #define SDM_PRICE       Markierung mit Preisangabe
      startStopDisplayMode = SDM_PRICE;           // default
   }
   else {
      int size = ArraySize(startStopDisplayModes);
      startStopDisplayMode = startStopDisplayModes[(i+1) % size];
   }

   // Anzeige aktualisieren
   RedrawStartStop();

   return(catch("ToggleStartStopDisplayMode()"));
}


/**
 * Wechselt den Modus der Orderanzeige.
 *
 * @return int - Fehlerstatus
 */
int ToggleOrderDisplayMode() {
   int pendings   = CountPendingOrders();
   int open       = CountOpenPositions();
   int stoppedOut = CountStoppedOutPositions();
   int closed     = CountClosedPositions();

   // Modus wechseln, dabei Modes ohne entsprechende Orders �berspringen
   int oldMode      = orderDisplayMode;
   int size         = ArraySize(orderDisplayModes);
   orderDisplayMode = (orderDisplayMode+1) % size;

   while (orderDisplayMode != oldMode) {                                   // #define ODM_NONE        - keine Anzeige -
      if (orderDisplayMode == ODM_NONE) {                                  // #define ODM_STOPS       Pending,       StoppedOut
         break;                                                            // #define ODM_PYRAMID     Pending, Open,             Closed
      }                                                                    // #define ODM_ALL         Pending, Open, StoppedOut, Closed
      else if (orderDisplayMode == ODM_STOPS) {
         if (pendings+stoppedOut > 0)
            break;
      }
      else if (orderDisplayMode == ODM_PYRAMID) {
         if (pendings+open+closed > 0)
            if (open+stoppedOut+closed > 0)                                // ansonsten ist Anzeige identisch zu vorherigem Mode
               break;
      }
      else if (orderDisplayMode == ODM_ALL) {
         if (pendings+open+stoppedOut+closed > 0)
            if (stoppedOut > 0)                                            // ansonsten ist Anzeige identisch zu vorherigem Mode
               break;
      }
      orderDisplayMode = (orderDisplayMode+1) % size;
   }


   // Anzeige aktualisieren
   if (orderDisplayMode != oldMode) {
      RedrawOrders();
   }
   else {
      // nothing to change, Anzeige bleibt unver�ndert
      PlaySoundEx("Plonk.wav");
   }
   return(catch("ToggleOrderDisplayMode()"));
}


/**
 * Gibt die Anzahl der Pending-Orders der Sequenz zur�ck.
 *
 * @return int
 */
int CountPendingOrders() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]==OP_UNDEFINED) /*&&*/ if (orders.closeTime[i]==0)
         count++;
   }
   return(count);
}


/**
 * Gibt die Anzahl der offenen Positionen der Sequenz zur�ck.
 *
 * @return int
 */
int CountOpenPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]!=OP_UNDEFINED) /*&&*/ if (orders.closeTime[i]==0)
         count++;
   }
   return(count);
}


/**
 * Gibt die Anzahl der ausgestoppten Positionen der Sequenz zur�ck.
 *
 * @return int
 */
int CountStoppedOutPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.closedBySL[i])
         count++;
   }
   return(count);
}


/**
 * Gibt die Anzahl der durch StopSequence() geschlossenen Positionen der Sequenz zur�ck.
 *
 * @return int
 */
int CountClosedPositions() {
   int count, size=ArraySize(orders.ticket);

   for (int i=0; i < size; i++) {
      if (orders.type[i]!=OP_UNDEFINED) /*&&*/ if (orders.closeTime[i]!=0) /*&&*/ if (!orders.closedBySL[i])
         count++;
   }
   return(count);
}


/**
 * Korrigiert die vom Terminal beim Abschicken einer Pending- oder Market-Order gesetzten oder nicht gesetzten Chart-Marker.
 *
 * @param  int i - Orderindex
 *
 * @return bool - success status
 */
bool Chart.MarkOrderSent(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - keine Anzeige -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   bool pending = orders.pendingType[i] != OP_UNDEFINED;

   int      type        =    ifInt(pending, orders.pendingType [i], orders.type     [i]);
   datetime openTime    =    ifInt(pending, orders.pendingTime [i], orders.openTime [i]);
   double   openPrice   = ifDouble(pending, orders.pendingPrice[i], orders.openPrice[i]);
   string   comment     = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   color    markerColor = CLR_NONE;

   if (orderDisplayMode != ODM_NONE) {
      if      (pending)                         markerColor = CLR_PENDING;
      else if (orderDisplayMode >= ODM_PYRAMID) markerColor = ifInt(IsLongOrderType(type), CLR_LONG, CLR_SHORT);
   }
   return(ChartMarker.OrderSent_B(orders.ticket[i], Digits, markerColor, type, LotSize, Symbol(), openTime, openPrice, orders.stopLoss[i], 0, comment));
}


/**
 * Korrigiert die vom Terminal beim Ausf�hren einer Pending-Order gesetzten oder nicht gesetzten Chart-Marker.
 *
 * @param  int i - Orderindex
 *
 * @return bool - success status
 */
bool Chart.MarkOrderFilled(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - keine Anzeige -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   string comment     = "SR."+ sequence.id +"."+ NumberToStr(orders.level[i], "+.");
   color  markerColor = CLR_NONE;

   if (orderDisplayMode >= ODM_PYRAMID)
      markerColor = ifInt(orders.type[i]==OP_BUY, CLR_LONG, CLR_SHORT);

   return(ChartMarker.OrderFilled_B(orders.ticket[i], orders.pendingType[i], orders.pendingPrice[i], Digits, markerColor, LotSize, Symbol(), orders.openTime[i], orders.openPrice[i], comment));
}


/**
 * Korrigiert den vom Terminal beim Schlie�en einer Position gesetzten oder nicht gesetzten Chart-Marker.
 *
 * @param  int i - Orderindex
 *
 * @return bool - success status
 */
bool Chart.MarkPositionClosed(int i) {
   if (!__CHART()) return(true);
   /*
   #define ODM_NONE     0     // - keine Anzeige -
   #define ODM_STOPS    1     // Pending,       ClosedBySL
   #define ODM_PYRAMID  2     // Pending, Open,             Closed
   #define ODM_ALL      3     // Pending, Open, ClosedBySL, Closed
   */
   color markerColor = CLR_NONE;

   if (orderDisplayMode != ODM_NONE) {
      if ( orders.closedBySL[i]) /*&&*/ if (orderDisplayMode != ODM_PYRAMID) markerColor = CLR_CLOSE;
      if (!orders.closedBySL[i]) /*&&*/ if (orderDisplayMode >= ODM_PYRAMID) markerColor = CLR_CLOSE;
   }
   return(ChartMarker.PositionClosed_B(orders.ticket[i], Digits, markerColor, orders.type[i], LotSize, Symbol(), orders.openTime[i], orders.openPrice[i], orders.closeTime[i], orders.closePrice[i]));
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
 * Setzt die Gr��e der Datenarrays auf den angegebenen Wert.
 *
 * @param  int  size  - neue Gr��e
 * @param  bool reset - ob die Arrays komplett zur�ckgesetzt werden sollen
 *                      (default: nur neu hinzugef�gte Felder werden initialisiert)
 *
 * @return int - neue Gr��e der Arrays
 */
int ResizeArrays(int size, bool reset=false) {
   reset = reset!=0;

   int oldSize = ArraySize(orders.ticket);

   if (size != oldSize) {
      ArrayResize(orders.ticket,          size);
      ArrayResize(orders.level,           size);
      ArrayResize(orders.gridBase,        size);
      ArrayResize(orders.pendingType,     size);
      ArrayResize(orders.pendingTime,     size);
      ArrayResize(orders.pendingPrice,    size);
      ArrayResize(orders.type,            size);
      ArrayResize(orders.openEvent,       size);
      ArrayResize(orders.openTime,        size);
      ArrayResize(orders.openPrice,       size);
      ArrayResize(orders.closeEvent,      size);
      ArrayResize(orders.closeTime,       size);
      ArrayResize(orders.closePrice,      size);
      ArrayResize(orders.stopLoss,        size);
      ArrayResize(orders.clientsideLimit, size);
      ArrayResize(orders.closedBySL,      size);
      ArrayResize(orders.swap,            size);
      ArrayResize(orders.commission,      size);
      ArrayResize(orders.profit,          size);
   }

   if (reset) {                                                      // alle Felder zur�cksetzen
      if (size != 0) {
         ArrayInitialize(orders.ticket,                 0);
         ArrayInitialize(orders.level,                  0);
         ArrayInitialize(orders.gridBase,               0);
         ArrayInitialize(orders.pendingType, OP_UNDEFINED);
         ArrayInitialize(orders.pendingTime,            0);
         ArrayInitialize(orders.pendingPrice,           0);
         ArrayInitialize(orders.type,        OP_UNDEFINED);
         ArrayInitialize(orders.openEvent,              0);
         ArrayInitialize(orders.openTime,               0);
         ArrayInitialize(orders.openPrice,              0);
         ArrayInitialize(orders.closeEvent,             0);
         ArrayInitialize(orders.closeTime,              0);
         ArrayInitialize(orders.closePrice,             0);
         ArrayInitialize(orders.stopLoss,               0);
         ArrayInitialize(orders.clientsideLimit,    false);
         ArrayInitialize(orders.closedBySL,         false);
         ArrayInitialize(orders.swap,                   0);
         ArrayInitialize(orders.commission,             0);
         ArrayInitialize(orders.profit,                 0);
      }
   }
   else {
      for (int i=oldSize; i < size; i++) {
         orders.pendingType[i] = OP_UNDEFINED;                       // Hinzugef�gte pendingType- und type-Felder immer re-initialisieren,
         orders.type       [i] = OP_UNDEFINED;                       // 0 ist ein g�ltiger Wert und daher als Default unzul�ssig.
      }
   }
   return(size);
}


/**
 * Return a readable version of a status event identifier.
 *
 * @param  int event
 *
 * @return string
 */
string StatusEventToStr(int event) {
   switch (event) {
      case EV_SEQUENCE_START  : return("EV_SEQUENCE_START"  );
      case EV_SEQUENCE_STOP   : return("EV_SEQUENCE_STOP"   );
      case EV_GRIDBASE_CHANGE : return("EV_GRIDBASE_CHANGE" );
      case EV_POSITION_OPEN   : return("EV_POSITION_OPEN"   );
      case EV_POSITION_STOPOUT: return("EV_POSITION_STOPOUT");
      case EV_POSITION_CLOSE  : return("EV_POSITION_CLOSE"  );
   }
   return(_EMPTY_STR(catch("StatusEventToStr(1)  illegal parameter event = "+ event, ERR_INVALID_PARAMETER)));
}


/**
 * Generiert eine neue Sequenz-ID.
 *
 * @return int - Sequenz-ID im Bereich 1000-16383 (mindestens 4-stellig, maximal 14 bit)
 */
int CreateSequenceId() {
   MathSrand(GetTickCount());
   int id;                                               // TODO: Im Tester m�ssen fortlaufende IDs generiert werden.
   while (id < SID_MIN || id > SID_MAX) {
      id = MathRand();
   }
   return(id);                                           // TODO: ID auf Eindeutigkeit pr�fen
}


/**
 * Holt eine Best�tigung f�r einen Trade-Request beim ersten Tick ein (um Programmfehlern vorzubeugen).
 *
 * @param  string location - Ort der Best�tigung
 * @param  string message  - Meldung
 *
 * @return bool - Ergebnis
 */
bool ConfirmFirstTickTrade(string location, string message) {
   static bool done, confirmed;
   if (!done) {
      if (Tick > 1 || IsTesting()) {
         confirmed = true;
      }
      else {
         PlaySoundEx("Windows Notify.wav");
         confirmed = (IDOK == MessageBoxEx(__NAME() + ifString(!StringLen(location), "", " - "+ location), ifString(IsDemoFix(), "", "- Real Account -\n\n") + message, MB_ICONQUESTION|MB_OKCANCEL));
         if (Tick > 0) RefreshRates();                   // bei Tick==0, also Aufruf in init(), ist RefreshRates() unn�tig
      }
      done = true;
   }
   return(confirmed);
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
   return(_EMPTY_STR(catch("StatusToStr(1)  invalid parameter status = "+ status, ERR_INVALID_PARAMETER)));
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
   return(_EMPTY_STR(catch("StatusDescription(1)  invalid parameter status = "+ status, ERR_INVALID_PARAMETER)));
}


/**
 * Ob der angegebene StopPrice erreicht wurde.
 *
 * @param  int    type  - stop or limit type: OP_BUY | OP_SELL | OP_BUYSTOP | OP_SELLSTOP | OP_BUYLIMIT | OP_SELLLIMIT
 * @param  double price - price
 *
 * @return bool
 */
bool IsStopTriggered(int type, double price) {
   if (type == OP_BUYSTOP )  return(Ask >= price);       // pending Buy Stop
   if (type == OP_SELLSTOP)  return(Bid <= price);       // pending Sell Stop

   if (type == OP_BUYLIMIT)  return(Ask <= price);       // pending Buy Limit
   if (type == OP_SELLLIMIT) return(Bid >= price);       // pending Sell Limit

   if (type == OP_BUY )      return(Bid <= price);       // stoploss Long
   if (type == OP_SELL)      return(Ask >= price);       // stoploss Short

   return(!catch("IsStopTriggered(1)  illegal parameter type = "+ type, ERR_INVALID_PARAMETER));

   // prevent compiler warnings
   datetime dNulls[];
   ReadTradeSessions(NULL, dNulls);
   ReadSessionBreaks(NULL, dNulls);
}


/**
 * Read the trade session configuration for the specified server time and copy it to the passed array.
 *
 * @param  _In_  datetime  time       - server time
 * @param  _Out_ datetime &config[][] - array receiving the trade session configuration
 *
 * @return bool - success status
 */
bool ReadTradeSessions(datetime time, datetime &config[][2]) {
   string section  = "TradeSessions";
   string symbol   = Symbol();
   string sDate    = TimeToStr(time, TIME_DATE);
   string sWeekday = GmtTimeFormat(time, "%A");
   string value;

   if      (IsConfigKey(section, symbol +"."+ sDate))    value = GetConfigString(section, symbol +"."+ sDate);
   else if (IsConfigKey(section, sDate))                 value = GetConfigString(section, sDate);
   else if (IsConfigKey(section, symbol +"."+ sWeekday)) value = GetConfigString(section, symbol +"."+ sWeekday);
   else if (IsConfigKey(section, sWeekday))              value = GetConfigString(section, sWeekday);
   else                                                  return(_false(debug("ReadTradeSessions(1)  no trade session configuration found")));

   // Monday    =                                  // no trade session
   // Tuesday   = 00:00-24:00                      // a full trade session
   // Wednesday = 01:02-20:00                      // a limited trade session
   // Thursday  = 03:00-12:10, 13:30-19:00         // multiple trade sessions

   ArrayResize(config, 0);
   if (value == "")
      return(true);

   string values[], sTimes[], sSession, sSessionStart, sSessionEnd;
   int sizeOfValues = Explode(value, ",", values, NULL);
   for (int i=0; i < sizeOfValues; i++) {
      sSession = StrTrim(values[i]);
      if (Explode(sSession, "-", sTimes, NULL) != 2) return(_false(catch("ReadTradeSessions(2)  illegal trade session configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sSessionStart = StrTrim(sTimes[0]);
      sSessionEnd   = StrTrim(sTimes[1]);
      debug("ReadTradeSessions(3)  start="+ sSessionStart +"  end="+ sSessionEnd);
   }
   return(true);
}


/**
 * Read the SnowRoller session break configuration for the specified server time and copy it to the passed array. SnowRoller
 * session breaks are symbol-specific. The configured times are applied session times, i.e. a session break will be enforced
 * if the current time is not in the configured time window.
 *
 * @param  _In_  datetime  time       - server time
 * @param  _Out_ datetime &config[][] - array receiving the session break configuration
 *
 * @return bool - success status
 */
bool ReadSessionBreaks(datetime time, datetime &config[][2]) {
   string section  = "SnowRoller.SessionBreaks";
   string symbol   = Symbol();
   string sDate    = TimeToStr(time, TIME_DATE);
   string sWeekday = GmtTimeFormat(time, "%A");
   string value;

   if      (IsConfigKey(section, symbol +"."+ sDate))    value = GetConfigString(section, symbol +"."+ sDate);
   else if (IsConfigKey(section, symbol +"."+ sWeekday)) value = GetConfigString(section, symbol +"."+ sWeekday);
   else                                                  return(_false(debug("ReadSessionBreaks(1)  no session break configuration found"))); // TODO: fall-back to auto-adjusted trade sessions

   // Tuesday   = 00:00-24:00                      // a full trade session:    no session breaks
   // Wednesday = 01:02-19:57                      // a limited trade session: session breaks before and after
   // Thursday  = 03:00-12:10, 13:30-19:00         // multiple trade sessions: session breaks before, after and in between
   // Saturday  =                                  // no trade session:        a 24 h session break
   // Sunday    =                                  //

   ArrayResize(config, 0);
   if (value == "")
      return(true);                                // TODO: fall-back to auto-adjusted trade sessions

   string   values[], sTimes[], sTime, sHours, sMinutes, sSession, sStartTime, sEndTime;
   datetime dStartTime, dEndTime, dSessionStart, dSessionEnd;
   int      sizeOfValues = Explode(value, ",", values, NULL), iHours, iMinutes;

   for (int i=0; i < sizeOfValues; i++) {
      sSession = StrTrim(values[i]);
      if (Explode(sSession, "-", sTimes, NULL) != 2) return(_false(catch("ReadSessionBreaks(2)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));

      sTime = StrTrim(sTimes[0]);
      if (StringLen(sTime) != 5)                     return(_false(catch("ReadSessionBreaks(3)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      if (StringGetChar(sTime, 2) != ':')            return(_false(catch("ReadSessionBreaks(4)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sHours = StringSubstr(sTime, 0, 2);
      if (!StrIsDigit(sHours))                       return(_false(catch("ReadSessionBreaks(5)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iHours = StrToInteger(sHours);
      if (iHours > 24)                               return(_false(catch("ReadSessionBreaks(6)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sMinutes = StringSubstr(sTime, 3, 2);
      if (!StrIsDigit(sMinutes))                     return(_false(catch("ReadSessionBreaks(7)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iMinutes = StrToInteger(sMinutes);
      if (iMinutes > 59)                             return(_false(catch("ReadSessionBreaks(8)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      dStartTime = DateTime(1970, 1, 1, iHours, iMinutes);

      sTime = StrTrim(sTimes[1]);
      if (StringLen(sTime) != 5)                     return(_false(catch("ReadSessionBreaks(9)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      if (StringGetChar(sTime, 2) != ':')            return(_false(catch("ReadSessionBreaks(10)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sHours = StringSubstr(sTime, 0, 2);
      if (!StrIsDigit(sHours))                       return(_false(catch("ReadSessionBreaks(11)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iHours = StrToInteger(sHours);
      if (iHours > 24)                               return(_false(catch("ReadSessionBreaks(12)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      sMinutes = StringSubstr(sTime, 3, 2);
      if (!StrIsDigit(sMinutes))                     return(_false(catch("ReadSessionBreaks(13)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      iMinutes = StrToInteger(sMinutes);
      if (iMinutes > 59)                             return(_false(catch("ReadSessionBreaks(14)  illegal session break configuration \""+ value +"\"", ERR_INVALID_CONFIG_VALUE)));
      dEndTime = DateTime(1970, 1, 1, iHours, iMinutes);

      debug("ReadSessionBreaks(15)  start="+ TimeToStr(dStartTime, TIME_FULL) +"  end="+ TimeToStr(dEndTime, TIME_FULL));
   }
   return(true);
}


/**
 * Update breakeven and profit targets.
 *
 * @return bool - success status
 */
bool UpdateProfitTargets() {
   if (IsLastError()) return(false);
   // 7bit:
   // double loss = currentPL - PotentialProfit(gridbaseDistance);
   // double be   = gridbase + RequiredDistance(loss);

   // calculate breakeven price (profit = losses)
   double price            = ifDouble(sequence.direction==D_LONG, Bid, Ask);
   double gridbaseDistance = MathAbs(price - gridbase)/Pip;
   double potentialProfit  = PotentialProfit(gridbaseDistance);
   double losses           = sequence.totalPL - potentialProfit;
   double beDistance       = RequiredDistance(MathAbs(losses));
   double bePrice          = gridbase + ifDouble(sequence.direction==D_LONG, beDistance, -beDistance)*Pip;
   sequence.breakeven      = NormalizeDouble(bePrice, Digits);
   //debug("UpdateProfitTargets(1)  level="+ sequence.level +"  gridbaseDist="+ DoubleToStr(gridbaseDistance, 1) +"  potential="+ DoubleToStr(potentialProfit, 2) +"  beDist="+ DoubleToStr(beDistance, 1) +" => "+ NumberToStr(bePrice, PriceFormat));

   // calculate TP price
   return(!catch("UpdateProfitTargets(2)"));
}


/**
 * Show the current profit targets.
 *
 * @return bool - success status
 */
bool ShowProfitTargets() {
   if (IsLastError())       return(false);
   if (!sequence.breakeven) return(true);

   datetime time = TimeCurrent(); time -= time % MINUTES;
   string label = "arrow_"+ time;
   double price = sequence.breakeven;

   if (ObjectFind(label) < 0) {
      ObjectCreate(label, OBJ_ARROW, 0, time, price);
   }
   else {
      ObjectSet(label, OBJPROP_TIME1,  time);
      ObjectSet(label, OBJPROP_PRICE1, price);
   }
   ObjectSet(label, OBJPROP_ARROWCODE, 4);
   ObjectSet(label, OBJPROP_SCALE,     1);
   ObjectSet(label, OBJPROP_COLOR,  Blue);
   ObjectSet(label, OBJPROP_BACK,   true);

   return(!catch("ShowProfitTargets(1)"));
}


/**
 * Calculate the theoretically possible maximum profit at the specified distance away from the gridbase. The calculation
 * assumes a perfect grid. It considers commissions but ignores missed grid levels and slippage.
 *
 * @param  double distance - distance from the gridbase in pip
 *
 * @return double - profit value
 */
double PotentialProfit(double distance) {
   // P = L * (L-1)/2 + partialP
   distance = NormalizeDouble(distance, 1);
   int    level = distance/GridSize;
   double partialLevel = MathModFix(distance/GridSize, 1);

   double units = (level-1)/2.*level + partialLevel*level;
   double unitSize = GridSize * PipValue(LotSize) + sequence.commission;

   double maxProfit = units * unitSize;
   if (partialLevel > 0) {
      maxProfit += (1-partialLevel)*level*sequence.commission;    // a partial level pays full commission
   }
   return(NormalizeDouble(maxProfit, 2));
}


/**
 * Calculate the minimum distance price has to move away from the gridbase to theoretically generate the specified floating
 * profit. The calculation assumes a perfect grid. It considers commissions but ignores missed grid levels and slippage.
 *
 * @param  double profit
 *
 * @return double - distance in pip
 */
double RequiredDistance(double profit) {
   // L = -0.5 + (0.25 + 2*units) ^ 1/2                           // quadratic equation solved with pq-formula
   double unitSize = GridSize * PipValue(LotSize) + sequence.commission;
   double units = MathAbs(profit)/unitSize;
   double level = MathPow(2*units + 0.25, 0.5) - 0.5;
   double distance = level * GridSize;
   return(RoundCeil(distance, 1));
}


/**
 * Return the trend value of a start condition's trend indicator.
 *
 * @param  int bar - bar index of the value to return
 *
 * @return int - trend value or NULL in case of errors
 */
int GetStartTrendValue(int bar) {
   if (start.trend.indicator == "alma"         ) return(GetALMA         (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "halftrend"    ) return(GetHalfTrend    (start.trend.timeframe, start.trend.params, HalfTrend.MODE_TREND,     bar));
   if (start.trend.indicator == "movingaverage") return(GetMovingAverage(start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "nonlagma"     ) return(GetNonLagMA     (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "supersmoother") return(GetSuperSmoother(start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));
   if (start.trend.indicator == "supertrend"   ) return(GetSuperTrend   (start.trend.timeframe, start.trend.params, SuperTrend.MODE_TREND,    bar));
   if (start.trend.indicator == "triema"       ) return(GetTriEMA       (start.trend.timeframe, start.trend.params, MovingAverage.MODE_TREND, bar));

   return(!catch("GetStartTrendValue(1)  unsupported trend indicator "+ DoubleQuoteStr(start.trend.indicator), ERR_INVALID_CONFIG_VALUE));
}


/**
 * Return the trend value of a stop condition's trend indicator.
 *
 * @param  int bar - bar index of the value to return
 *
 * @return int - trend value or NULL in case of errors
 */
int GetStopTrendValue(int bar) {
   if (stop.trend.indicator == "alma"         ) return(GetALMA         (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "halftrend"    ) return(GetHalfTrend    (stop.trend.timeframe, stop.trend.params, HalfTrend.MODE_TREND,     bar));
   if (stop.trend.indicator == "movingaverage") return(GetMovingAverage(stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "nonlagma"     ) return(GetNonLagMA     (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "supersmoother") return(GetSuperSmoother(stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));
   if (stop.trend.indicator == "supertrend"   ) return(GetSuperTrend   (stop.trend.timeframe, stop.trend.params, SuperTrend.MODE_TREND,    bar));
   if (stop.trend.indicator == "triema"       ) return(GetTriEMA       (stop.trend.timeframe, stop.trend.params, MovingAverage.MODE_TREND, bar));

   return(!catch("GetStopTrendValue(1)  unsupported trend indicator "+ DoubleQuoteStr(stop.trend.indicator), ERR_INVALID_CONFIG_VALUE));
}


/**
 * Return an ALMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetALMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetALMA(1)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    maPeriods;
   static string maAppliedPrice;
   static double distributionOffset;
   static double distributionSigma;

   static string lastParams = "", elems[], sValue;
   if (params != lastParams) {
      if (Explode(params, ",", elems, NULL) != 4) return(!catch("GetALMA(2)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))                    return(!catch("GetALMA(3)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      maPeriods = StrToInteger(sValue);
      sValue = StrTrim(elems[1]);
      if (!StringLen(sValue))                     return(!catch("GetALMA(4)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      maAppliedPrice = sValue;
      sValue = StrTrim(elems[2]);
      if (!StrIsNumeric(sValue))                  return(!catch("GetALMA(5)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      distributionOffset = StrToDouble(sValue);
      sValue = StrTrim(elems[3]);
      if (!StrIsNumeric(sValue))                  return(!catch("GetALMA(6)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      distributionSigma = StrToDouble(sValue);
      lastParams        = params;
   }
   return(icALMA(timeframe, maPeriods, maAppliedPrice, distributionOffset, distributionSigma, iBuffer, iBar));
}


/**
 * Return a HalfTrend indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetHalfTrend(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetHalfTrend(1)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int periods;

   static string lastParams = "";
   if (params != lastParams) {
      if (!StrIsDigit(params)) return(!catch("GetHalfTrend(2)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods    = StrToInteger(params);
      lastParams = params;
   }
   return(icHalfTrend(timeframe, periods, iBuffer, iBar));
}


/**
 * Return a Moving Average indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetMovingAverage(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetMovingAverage(1)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string method;
   static string appliedPrice;

   static string lastParams = "", elems[], sValue;
   if (params != lastParams) {
      if (Explode(params, ",", elems, NULL) != 3) return(!catch("GetMovingAverage(2)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))                    return(!catch("GetMovingAverage(3)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);
      sValue = StrTrim(elems[1]);
      if (!StringLen(sValue))                     return(!catch("GetMovingAverage(4)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      method = sValue;
      sValue = StrTrim(elems[2]);
      if (!StringLen(sValue))                     return(!catch("GetMovingAverage(5)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      appliedPrice = sValue;
      lastParams   = params;
   }
   return(icMovingAverage(timeframe, periods, method, appliedPrice, iBuffer, iBar));
}


/**
 * Return a NonLagMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetNonLagMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetNonLagMA(1)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int cycleLength;

   static string lastParams = "";
   if (params != lastParams) {
      if (!StrIsDigit(params)) return(!catch("GetNonLagMA(2)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      cycleLength = StrToInteger(params);
      lastParams  = params;
   }
   return(icNonLagMA(timeframe, cycleLength, iBuffer, iBar));
}


/**
 * Return an indicator value from "Ehler's 2-Pole-SuperSmoother Filter".
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetSuperSmoother(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetSuperSmoother(1)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string appliedPrice;

   static string lastParams = "", elems[], sValue;
   if (params != lastParams) {
      if (Explode(params, ",", elems, NULL) != 2) return(!catch("GetSuperSmoother(2)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))                    return(!catch("GetSuperSmoother(3)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);
      sValue = StrTrim(elems[2]);
      if (!StringLen(sValue))                     return(!catch("GetSuperSmoother(4)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      appliedPrice = sValue;
      lastParams   = params;
   }
   return(icSuperSmoother(timeframe, periods, appliedPrice, iBuffer, iBar));
}


/**
 * Return a SuperTrend indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetSuperTrend(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetSuperTrend(1)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int atrPeriods;
   static int smaPeriods;

   static string lastParams = "", elems[], sValue;
   if (params != lastParams) {
      if (Explode(params, ",", elems, NULL) != 2) return(!catch("GetSuperTrend(2)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))                    return(!catch("GetSuperTrend(3)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      atrPeriods = StrToInteger(sValue);
      sValue = StrTrim(elems[1]);
      if (!StrIsDigit(sValue))                    return(!catch("GetSuperTrend(4)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      smaPeriods = StrToInteger(sValue);
      lastParams = params;
   }
   return(icSuperTrend(timeframe, atrPeriods, smaPeriods, iBuffer, iBar));
}


/**
 * Return a TriEMA indicator value.
 *
 * @param  int    timeframe - timeframe to load the indicator (NULL: the current timeframe)
 * @param  string params    - additional comma-separated indicator parameters
 * @param  int    iBuffer   - buffer index of the value to return
 * @param  int    iBar      - bar index of the value to return
 *
 * @return double - indicator value or NULL in case of errors
 */
double GetTriEMA(int timeframe, string params, int iBuffer, int iBar) {
   if (!StringLen(params)) return(!catch("GetTriEMA(1)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));

   static int    periods;
   static string appliedPrice;

   static string lastParams = "", elems[], sValue;
   if (params != lastParams) {
      if (Explode(params, ",", elems, NULL) != 2) return(!catch("GetTriEMA(2)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      sValue = StrTrim(elems[0]);
      if (!StrIsDigit(sValue))                    return(!catch("GetTriEMA(3)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      periods = StrToInteger(sValue);
      sValue = StrTrim(elems[1]);
      if (!StringLen(sValue))                     return(!catch("GetTriEMA(4)  invalid parameter params: "+ DoubleQuoteStr(params), ERR_INVALID_PARAMETER));
      appliedPrice = sValue;
      lastParams   = params;
   }
   return(icTriEMA(timeframe, periods, appliedPrice, iBuffer, iBar));
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
                            "LotSize=",                NumberToStr(LotSize, ".1+"),                  ";", NL,
                            "StartLevel=",             StartLevel,                                   ";", NL,
                            "StartConditions=",        DoubleQuoteStr(StartConditions),              ";", NL,
                            "StopConditions=",         DoubleQuoteStr(StopConditions),               ";", NL,
                            "AutoResume=",             BoolToStr(AutoResume),                        ";", NL,
                            "AutoRestart=",            BoolToStr(AutoRestart),                       ";", NL,
                            "ShowProfitInPercent=",    BoolToStr(ShowProfitInPercent),               ";", NL,
                            "Sessionbreak.StartTime=", TimeToStr(Sessionbreak.StartTime, TIME_FULL), ";", NL,
                            "Sessionbreak.EndTime=",   TimeToStr(Sessionbreak.EndTime, TIME_FULL),   ";")
   );
}
