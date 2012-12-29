/**
 * MQL-Fehlercodes
 *
 *
 * NOTE: Dieser Datei ist kompatibel zur Original-MetaQuotes-Version.
 */

#define ERR_NO_ERROR                                                  0
#define NO_ERROR                                           ERR_NO_ERROR

// Trading errors
#define ERR_NO_RESULT                                                 1    // Tradeserver-Wechsel w�hrend OrderModify()
#define ERR_COMMON_ERROR                                              2    // trade denied
#define ERR_INVALID_TRADE_PARAMETERS                                  3
#define ERR_SERVER_BUSY                                               4
#define ERR_OLD_VERSION                                               5
#define ERR_NO_CONNECTION                                             6
#define ERR_NOT_ENOUGH_RIGHTS                                         7
#define ERR_TOO_FREQUENT_REQUESTS                                     8
#define ERR_MALFUNCTIONAL_TRADE                                       9
#define ERR_ACCOUNT_DISABLED                                         64
#define ERR_INVALID_ACCOUNT                                          65
#define ERR_TRADE_TIMEOUT                                           128
#define ERR_INVALID_PRICE                                           129    // Kurs bewegt sich zu schnell (aus dem Fenster)
#define ERR_INVALID_STOP                                            130
#define ERR_INVALID_STOPS                              ERR_INVALID_STOP
#define ERR_INVALID_TRADE_VOLUME                                    131
#define ERR_MARKET_CLOSED                                           132
#define ERR_TRADE_DISABLED                                          133
#define ERR_NOT_ENOUGH_MONEY                                        134
#define ERR_PRICE_CHANGED                                           135
#define ERR_OFF_QUOTES                                              136
#define ERR_BROKER_BUSY                                             137
#define ERR_REQUOTE                                                 138
#define ERR_ORDER_LOCKED                                            139
#define ERR_LONG_POSITIONS_ONLY_ALLOWED                             140
#define ERR_TOO_MANY_REQUESTS                                       141
// 142   The order has been enqueued. It is not an error but an interaction code between the client terminal and the trade server.
//       This code can be got rarely, when the disconnection and the reconnection happen during the execution of a trade operation.
//       This code should be processed in the same way as error 128.
//
// 143   The order was accepted by the broker for execution. It is an interaction code between the client terminal and the trade server.
//       It can appear for the same reason as code 142. This code should be processed in the same way as error 128.
//
// 144   The order was discarded by the broker during manual confirmation. It is an interaction code between the client terminal and
//       the trade server.
#define ERR_TRADE_MODIFY_DENIED                                     145
#define ERR_TRADE_CONTEXT_BUSY                                      146
#define ERR_TRADE_EXPIRATION_DENIED                                 147
#define ERR_TRADE_TOO_MANY_ORDERS                                   148
#define ERR_TRADE_HEDGE_PROHIBITED                                  149
#define ERR_TRADE_PROHIBITED_BY_FIFO                                150

// Errors causing a temporary execution stop
#define ERR_WRONG_FUNCTION_POINTER                                 4001    // the error code is available at the next call of start() or deinit()
#define ERR_NO_MEMORY_FOR_CALL_STACK                               4003
#define ERR_RECURSIVE_STACK_OVERFLOW                               4004
#define ERR_NO_MEMORY_FOR_PARAM_STRING                             4006
#define ERR_NO_MEMORY_FOR_TEMP_STRING                              4007
#define ERR_NO_MEMORY_FOR_ARRAYSTRING                              4010
#define ERR_TOO_LONG_STRING                                        4011
#define ERR_REMAINDER_FROM_ZERO_DIVIDE                             4012
#define ERR_UNKNOWN_COMMAND                                        4014

// Errors causing a complete execution stop until the program is re-initialized; start() or deinit() will not get called again
#define ERR_ZERO_DIVIDE                                            4013
#define ERR_CANNOT_LOAD_LIBRARY                                    4018
#define ERR_CANNOT_CALL_FUNCTION                                   4019
#define ERR_DLL_CALLS_NOT_ALLOWED                                  4017    // DLL imports
#define ERR_EXTERNAL_CALLS_NOT_ALLOWED                             4020    // ex4 library imports

// Runtime errors
#define ERR_RUNTIME_ERROR                                          4000    // user runtime error (never generated by the terminal)
#define ERR_ARRAY_INDEX_OUT_OF_RANGE                               4002
#define ERR_NOT_ENOUGH_STACK_FOR_PARAM                             4005
#define ERR_NOT_INITIALIZED_STRING                                 4008
#define ERR_NOT_INITIALIZED_ARRAYSTRING                            4009
#define ERR_WRONG_JUMP                                             4015
#define ERR_NOT_INITIALIZED_ARRAY                                  4016
#define ERR_NO_MEMORY_FOR_RETURNED_STR                             4021
#define ERR_SYSTEM_BUSY                                            4022
//                                                                 4023    // ???
#define ERR_INVALID_FUNCTION_PARAMSCNT                             4050    // invalid parameters count
#define ERR_INVALID_FUNCTION_PARAMVALUE                            4051    // invalid parameter value
#define ERR_STRING_FUNCTION_INTERNAL                               4052
#define ERR_SOME_ARRAY_ERROR                                       4053    // some array error
#define ERR_TIMEFRAME_NOT_AVAILABLE                                4054    // accessed timeframe not available
#define ERR_INCORRECT_SERIESARRAY_USING     ERR_TIMEFRAME_NOT_AVAILABLE
#define ERR_CUSTOM_INDICATOR_ERROR                                 4055    // custom indicator error
#define ERR_INCOMPATIBLE_ARRAYS                                    4056    // incompatible arrays
#define ERR_GLOBAL_VARIABLES_PROCESSING                            4057
#define ERR_GLOBAL_VARIABLE_NOT_FOUND                              4058
#define ERR_FUNC_NOT_ALLOWED_IN_TESTER                             4059
#define ERR_FUNC_NOT_ALLOWED_IN_TESTING  ERR_FUNC_NOT_ALLOWED_IN_TESTER
#define ERR_FUNCTION_NOT_CONFIRMED                                 4060
#define ERR_SEND_MAIL_ERROR                                        4061
#define ERR_STRING_PARAMETER_EXPECTED                              4062
#define ERR_INTEGER_PARAMETER_EXPECTED                             4063
#define ERR_DOUBLE_PARAMETER_EXPECTED                              4064
#define ERR_ARRAY_AS_PARAMETER_EXPECTED                            4065
#define ERS_HISTORY_UPDATE                                         4066    // history update                         // Status
#define ERR_HISTORY_WILL_UPDATED                     ERS_HISTORY_UPDATE
#define ERR_TRADE_ERROR                                            4067    // error in trade function
#define ERR_END_OF_FILE                                            4099    // end of file
#define ERR_SOME_FILE_ERROR                                        4100    // some file error
#define ERR_WRONG_FILE_NAME                                        4101
#define ERR_TOO_MANY_OPENED_FILES                                  4102
#define ERR_CANNOT_OPEN_FILE                                       4103
#define ERR_INCOMPATIBLE_FILEACCESS                                4104
#define ERR_NO_ORDER_SELECTED                                      4105    // no order selected
#define ERR_UNKNOWN_SYMBOL                                         4106    // unknown symbol
#define ERR_INVALID_PRICE_PARAM                                    4107    // invalid price parameter
#define ERR_INVALID_TICKET                                         4108    // invalid ticket
#define ERR_TRADE_NOT_ALLOWED                                      4109
#define ERR_LONGS_NOT_ALLOWED                                      4110
#define ERR_SHORTS_NOT_ALLOWED                                     4111
#define ERR_OBJECT_ALREADY_EXISTS                                  4200
#define ERR_UNKNOWN_OBJECT_PROPERTY                                4201
#define ERR_OBJECT_DOES_NOT_EXIST                                  4202
#define ERR_UNKNOWN_OBJECT_TYPE                                    4203
#define ERR_NO_OBJECT_NAME                                         4204
#define ERR_OBJECT_COORDINATES_ERROR                               4205
#define ERR_NO_SPECIFIED_SUBWINDOW                                 4206
#define ERR_SOME_OBJECT_ERROR                                      4207

// Custom errors
#define ERR_WIN32_ERROR                                            5000    // win32 api error
#define ERR_FUNCTION_NOT_IMPLEMENTED                               5001    // function not implemented
#define ERR_INVALID_INPUT                                          5002    // invalid input parameter
#define ERR_INVALID_CONFIG_PARAMVALUE                              5003    // invalid configuration parameter
#define ERS_TERMINAL_NOT_READY                                     5004    // terminal not yet ready                 // in Scripten Fehler, sonst Status
#define ERR_INVALID_TIMEZONE_CONFIG                                5005    // invalid or missing timezone configuration
#define ERR_INVALID_MARKET_DATA                                    5006    // invalid market data
#define ERR_FILE_NOT_FOUND                                         5007    // file not found
#define ERR_CANCELLED_BY_USER                                      5008    // execution cancelled by user
#define ERR_FUNC_NOT_ALLOWED                                       5009    // function not allowed
#define ERR_INVALID_COMMAND                                        5010    // invalid or unknown command
#define ERR_ILLEGAL_STATE                                          5011    // illegal state
#define ERS_EXECUTION_STOPPING                                     5012    // IsStopped() returned TRUE              // Status
#define ERR_ORDER_CHANGED                                          5013    // order status changed
#define ERR_HISTORY_INSUFFICIENT                                   5014    // history insufficient for calculation
