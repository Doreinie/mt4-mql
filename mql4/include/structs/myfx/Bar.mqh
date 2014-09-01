/**
 * MQL-Structure BAR. MQL-Darstellung der MT4-Structure RATE_INFO. Der Datentyp der Elemente ist einheitlich, die Kursreihenfolge ist wie in RATE_INFO OLHC.
 *
 *                          size          offset
 * struct BAR {             ----          ------
 *   double time;             8        double[0]      // BarOpen-Time, immer Ganzzahl
 *   double open;             8        double[1]
 *   double low;              8        double[2]
 *   double high;             8        double[3]
 *   double close;            8        double[4]
 *   double volume;           8        double[5]      // immer Ganzzahl
 * };                      = 48 byte = double[6]
 *
 *
 * @see  Importdeklarationen der entsprechenden Library am Ende dieser Datei
 */

// Getter
datetime bar.Time      (/*BAR*/double bar[]         ) { return(bar[0]);                                       BAR.toStr(bar); }
double   bar.Open      (/*BAR*/double bar[]         ) { return(bar[1]);                                       BAR.toStr(bar); }
double   bar.Low       (/*BAR*/double bar[]         ) { return(bar[2]);                                       BAR.toStr(bar); }
double   bar.High      (/*BAR*/double bar[]         ) { return(bar[3]);                                       BAR.toStr(bar); }
double   bar.Close     (/*BAR*/double bar[]         ) { return(bar[4]);                                       BAR.toStr(bar); }
int      bar.Volume    (/*BAR*/double bar[]         ) { return(bar[5]);                                       BAR.toStr(bar); }

datetime bars.Time     (/*BAR*/double bar[][], int i) { return(bar[i][0]);                                    BAR.toStr(bar); }
double   bars.Open     (/*BAR*/double bar[][], int i) { return(bar[i][1]);                                    BAR.toStr(bar); }
double   bars.Low      (/*BAR*/double bar[][], int i) { return(bar[i][2]);                                    BAR.toStr(bar); }
double   bars.High     (/*BAR*/double bar[][], int i) { return(bar[i][3]);                                    BAR.toStr(bar); }
double   bars.Close    (/*BAR*/double bar[][], int i) { return(bar[i][4]);                                    BAR.toStr(bar); }
int      bars.Volume   (/*BAR*/double bar[][], int i) { return(bar[i][5]);                                    BAR.toStr(bar); }


// Setter
datetime bar.setTime   (/*BAR*/double &bar[],          datetime time  ) {    bar[0] = time;   return(time  ); BAR.toStr(bar); }
double   bar.setOpen   (/*BAR*/double &bar[],          double   open  ) {    bar[1] = open;   return(open  ); BAR.toStr(bar); }
double   bar.setLow    (/*BAR*/double &bar[],          double   low   ) {    bar[2] = low;    return(low   ); BAR.toStr(bar); }
double   bar.setHigh   (/*BAR*/double &bar[],          double   high  ) {    bar[3] = high;   return(high  ); BAR.toStr(bar); }
double   bar.setClose  (/*BAR*/double &bar[],          double   close ) {    bar[4] = close;  return(close ); BAR.toStr(bar); }
int      bar.setVolume (/*BAR*/double &bar[],          int      volume) {    bar[5] = volume; return(volume); BAR.toStr(bar); }

datetime bars.setTime  (/*BAR*/double &bar[][], int i, datetime time  ) { bar[i][0] = time;   return(time  ); BAR.toStr(bar); }
double   bars.setOpen  (/*BAR*/double &bar[][], int i, double   open  ) { bar[i][1] = open;   return(open  ); BAR.toStr(bar); }
double   bars.setLow   (/*BAR*/double &bar[][], int i, double   low   ) { bar[i][2] = low;    return(low   ); BAR.toStr(bar); }
double   bars.setHigh  (/*BAR*/double &bar[][], int i, double   high  ) { bar[i][3] = high;   return(high  ); BAR.toStr(bar); }
double   bars.setClose (/*BAR*/double &bar[][], int i, double   close ) { bar[i][4] = close;  return(close ); BAR.toStr(bar); }
int      bars.setVolume(/*BAR*/double &bar[][], int i, int      volume) { bar[i][5] = volume; return(volume); BAR.toStr(bar); }


/**
 * Gibt die lesbare Repr�sentation ein oder mehrerer BAR-Strukturen zur�ck.
 *
 * @param  double bar[]    - BAR
 * @param  bool   debugger - ob die Ausgabe zus�tzlich zum Debugger geschickt werden soll (default: nein)
 *
 * @return string - lesbarer String oder Leerstring, falls ein Fehler auftrat
 */
string BAR.toStr(/*BAR*/double bar[], bool debugger=false) {
   debugger = debugger!=0;

   int dimensions = ArrayDimension(bar);
   if (dimensions > 2)                                  return(_emptyStr(catch("BAR.toStr(1)   too many dimensions of parameter bar = "+ dimensions, ERR_INVALID_FUNCTION_PARAMVALUE)));
   if (ArrayRange(bar, dimensions-1) != BAR.doubleSize) return(_emptyStr(catch("BAR.toStr(2)   invalid size of parameter bar ("+ ArrayRange(bar, dimensions-1) +")", ERR_INVALID_FUNCTION_PARAMVALUE)));

   string line, lines[]; ArrayResize(lines, 0);


   if (dimensions == 1) {
      // bar ist einzelnes Struct BAR (eine Dimension)
      line = StringConcatenate("{time="  ,   ifString(!bar.Time  (bar), "0", "'"+ TimeToStr(bar.Time(bar), TIME_FULL) +"'"),
                              ", open="  , NumberToStr(bar.Open  (bar), ".+"),
                              ", high="  , NumberToStr(bar.High  (bar), ".+"),
                              ", low="   , NumberToStr(bar.Low   (bar), ".+"),
                              ", close=" , NumberToStr(bar.Close (bar), ".+"),
                              ", volume=",             bar.Volume(bar), "}");
      if (debugger)
         debug("BAR.toStr()   "+ line);
      ArrayPushString(lines, line);
   }
   else {
      // bar ist Struct-Array BAR[] (zwei Dimensionen)
      int size = ArrayRange(bar, 0);

      for (int i=0; i < size; i++) {
         line = StringConcatenate("[", i, "]={time="  ,   ifString(!bars.Time  (bar, i), "0", "'"+ TimeToStr(bars.Time(bar, i), TIME_FULL) +"'"),
                                           ", open="  , NumberToStr(bars.Open  (bar, i), ".+"),
                                           ", high="  , NumberToStr(bars.High  (bar, i), ".+"),
                                           ", low="   , NumberToStr(bars.Low   (bar, i), ".+"),
                                           ", close=" , NumberToStr(bars.Close (bar, i), ".+"),
                                           ", volume=",             bars.Volume(bar, i), "}");
         if (debugger)
            debug("BAR.toStr()   "+ line);
         ArrayPushString(lines, line);
      }
   }

   string output = JoinStrings(lines, NL);
   ArrayResize(lines, 0);

   catch("BAR.toStr(3)");
   return(output);


   // Dummy-Calls: unterdr�cken unn�tze Compilerwarnungen
   bar.Time     (bar);       bars.Time     (bar, NULL);
   bar.Open     (bar);       bars.Open     (bar, NULL);
   bar.Low      (bar);       bars.Low      (bar, NULL);
   bar.High     (bar);       bars.High     (bar, NULL);
   bar.Close    (bar);       bars.Close    (bar, NULL);
   bar.Volume   (bar);       bars.Volume   (bar, NULL);

   bar.setTime  (bar, NULL); bars.setTime  (bar, NULL, NULL);
   bar.setOpen  (bar, NULL); bars.setOpen  (bar, NULL, NULL);
   bar.setLow   (bar, NULL); bars.setLow   (bar, NULL, NULL);
   bar.setHigh  (bar, NULL); bars.setHigh  (bar, NULL, NULL);
   bar.setClose (bar, NULL); bars.setClose (bar, NULL, NULL);
   bar.setVolume(bar, NULL); bars.setVolume(bar, NULL, NULL);
}


// --------------------------------------------------------------------------------------------------------------------------------------------------


#import "stdlib1.ex4"
   string JoinStrings(string array[], string separator);
   string NumberToStr(double number, string format);
#import


// --------------------------------------------------------------------------------------------------------------------------------------------------


//#import "struct.BAR.ex4"
//   // Getter
//   datetime bar.Time      (/*BAR*/double bar[]);
//   double   bar.Open      (/*BAR*/double bar[]);
//   double   bar.Low       (/*BAR*/double bar[]);
//   double   bar.High      (/*BAR*/double bar[]);
//   double   bar.Close     (/*BAR*/double bar[]);
//   int      bar.Volume    (/*BAR*/double bar[]);

//   datetime bars.Time     (/*BAR*/double bar[][], int i);
//   double   bars.Open     (/*BAR*/double bar[][], int i);
//   double   bars.Low      (/*BAR*/double bar[][], int i);
//   double   bars.High     (/*BAR*/double bar[][], int i);
//   double   bars.Close    (/*BAR*/double bar[][], int i);
//   int      bars.Volume   (/*BAR*/double bar[][], int i);

//   // Setter
//   datetime bar.setTime   (/*BAR*/double bar[], datetime time  );
//   double   bar.setOpen   (/*BAR*/double bar[], double   open  );
//   double   bar.setLow    (/*BAR*/double bar[], double   low   );
//   double   bar.setHigh   (/*BAR*/double bar[], double   high  );
//   double   bar.setClose  (/*BAR*/double bar[], double   close );
//   int      bar.setVolume (/*BAR*/double bar[], int      volume);

//   datetime bars.setTime  (/*BAR*/double bar[][], int i, datetime time  );
//   double   bars.setOpen  (/*BAR*/double bar[][], int i, double   open  );
//   double   bars.setLow   (/*BAR*/double bar[][], int i, double   low   );
//   double   bars.setHigh  (/*BAR*/double bar[][], int i, double   high  );
//   double   bars.setClose (/*BAR*/double bar[][], int i, double   close );
//   int      bars.setVolume(/*BAR*/double bar[][], int i, int      volume);
//#import