//+------------------------------------------------------------------+
//|                                     AutoTP_SL_Exness_Alert.mq5   |
//|                          Senior MQL5 Developer & Quant Trader    |
//|                   Optimized for Exness High-Speed Trading        |
//+------------------------------------------------------------------+
#property copyright "Senior MQL5 Developer"
#property link      ""
#property version   "1.21"
#property strict

//--- Input Parameters (mudah diatur dari Properties EA)
input group "=== Pengaturan Take Profit & Stop Loss ==="
input int      TP_Points          = 1000;     // Jarak Take Profit dalam Points (default 1000)
input bool     Use_SL             = false;    // Aktifkan Stop Loss?
input int      SL_Points          = 500;      // Jarak Stop Loss dalam Points (jika aktif)

input group "=== Pengaturan Notifikasi / Alert ==="
input bool     Enable_Alert       = true;     // Aktifkan Popup Alert di layar?
input bool     Enable_Notification= false;    // Aktifkan Push Notification ke HP (MetaQuotes ID)?
input bool     Enable_Email       = false;    // Aktifkan Email Notification?

input group "=== Pengaturan Lanjutan ==="
input int      Max_Retry          = 3;        // Jumlah maksimal retry jika gagal
input int      Retry_Delay_ms     = 50;       // Delay antar retry (milidetik)
input bool     Only_Current_Symbol = false;   // true = hanya simbol chart ini, false = semua simbol
input long     Magic_Number       = 0;        // 0 = proses semua posisi (manual + EA lain)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== Auto TP/SL Exness v1.21 (with Alert) berhasil dijalankan ===");
   Print("TP Points : ", TP_Points);
   Print("SL Aktif  : ", Use_SL ? "Ya" : "Tidak");
   if(Use_SL) Print("SL Points : ", SL_Points);
   Print("Mode      : ", Only_Current_Symbol ? "Hanya simbol chart" : "Semua simbol");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== Auto TP/SL Exness dihentikan ===");
}

//+------------------------------------------------------------------+
//| Trade Transaction Handler - DETEKSI POSISI MASUK & KELUAR (TP/SL)|
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   
   ulong deal_ticket = trans.deal;
   if(deal_ticket == 0) return;
   
   if(!HistoryDealSelect(deal_ticket)) return;
   
   long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   long deal_type  = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   string symbol   = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   long magic      = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   
   // Filter Magic Number & Simbol
   if(Magic_Number != 0 && magic != Magic_Number) return;
   if(Only_Current_Symbol && symbol != _Symbol) return;

   // 1. KASUS POSISI BARU MASUK (DEAL_ENTRY_IN) -> Set TP/SL
   if(deal_entry == DEAL_ENTRY_IN && (deal_type == DEAL_TYPE_BUY || deal_type == DEAL_TYPE_SELL))
   {
      ulong position_ticket = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      if(position_ticket != 0)
         ProcessNewPosition(position_ticket);
   }
   
   // 2. KASUS POSISI KELUAR (DEAL_ENTRY_OUT) -> Deteksi TP / SL tersentuh
   if(deal_entry == DEAL_ENTRY_OUT)
   {
      long deal_reason = HistoryDealGetInteger(deal_ticket, DEAL_REASON);
      
      if(deal_reason == DEAL_REASON_TP || deal_reason == DEAL_REASON_SL)
      {
         double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) + 
                         HistoryDealGetDouble(deal_ticket, DEAL_SWAP) + 
                         HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
         
         string status_type = (deal_reason == DEAL_REASON_TP) ? "🎯 TAKE PROFIT (TP)" : "❌ STOP LOSS (SL)";
         string pos_str     = (deal_type == DEAL_TYPE_BUY) ? "BUY" : "SELL";
         double price_close = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
         ulong pos_id       = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
         
         // Buat Pesan Notifikasi
         string message = StringFormat("%s Tersentuh! [%s %s] | Ticket: %I64d | Harga: %.5f | Profit: $%.2f",
                           status_type, pos_str, symbol, pos_id, price_close, profit);
         
         // Eksekusi Log & Alert
         Print(message);
         
         if(Enable_Alert)
            Alert(message);
            
         if(Enable_Notification)
            SendNotification(message);
            
         if(Enable_Email)
            SendMail("AutoTP_SL Alert: " + symbol, message);
      }
   }
}

//+------------------------------------------------------------------+
//| Fungsi utama memproses posisi baru                               |
//+------------------------------------------------------------------+
void ProcessNewPosition(ulong position_ticket)
{
   if(!PositionSelectByTicket(position_ticket))
   {
      Print("Gagal select posisi #", position_ticket, " | Error: ", GetLastError());
      return;
   }
   
   string symbol      = PositionGetString(POSITION_SYMBOL);
   long   magic       = PositionGetInteger(POSITION_MAGIC);
   double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
   long   pos_type    = PositionGetInteger(POSITION_TYPE);
   double current_tp  = PositionGetDouble(POSITION_TP);
   
   if(Magic_Number != 0 && magic != Magic_Number) return;
   if(Only_Current_Symbol && symbol != _Symbol) return;
   
   if(current_tp > 0)
   {
      // Sudah ada TP, dilewati
      return;
   }
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   double tp_price = 0.0;
   if(pos_type == POSITION_TYPE_BUY)
      tp_price = NormalizeDouble(open_price + TP_Points * point, digits);
   else 
      tp_price = NormalizeDouble(open_price - TP_Points * point, digits);
   
   double sl_price = 0.0;
   if(Use_SL)
   {
      if(pos_type == POSITION_TYPE_BUY)
         sl_price = NormalizeDouble(open_price - SL_Points * point, digits);
      else
         sl_price = NormalizeDouble(open_price + SL_Points * point, digits);
   }
   
   bool success = false;
   for(int attempt = 1; attempt <= Max_Retry; attempt++)
   {
      if(ModifyPosition(position_ticket, sl_price, tp_price, symbol))
      {
         success = true;
         break;
      }
      if(attempt < Max_Retry)
         Sleep(Retry_Delay_ms);
   }
   
   if(success)
   {
      string type_str = (pos_type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      Print("✅ Berhasil set TP/SL | ", type_str, " ", symbol, 
            " | Ticket: ", position_ticket,
            " | Open: ", DoubleToString(open_price, digits),
            " | TP: ", DoubleToString(tp_price, digits),
            (Use_SL ? " | SL: " + DoubleToString(sl_price, digits) : ""));
   }
   else
   {
      Print("❌ Gagal set TP/SL setelah ", Max_Retry, " percobaan | Ticket: ", position_ticket, 
            " | LastError: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Fungsi memodifikasi posisi (dengan error handling)               |
//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double sl, double tp, string symbol)
{
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   
   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol   = symbol;
   request.sl       = sl;
   request.tp       = tp;
   request.magic    = Magic_Number;
   
   bool sent = OrderSend(request, result);
   
   if(!sent || result.retcode != TRADE_RETCODE_DONE)
   {
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // Kosongkan - efisiensi tinggi terjaga via OnTradeTransaction.
}
