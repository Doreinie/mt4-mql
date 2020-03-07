/**
 * Functions shared by SnowRoller and Sisyphus
 */


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
}
