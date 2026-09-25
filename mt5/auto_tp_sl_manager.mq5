//+------------------------------------------------------------------+
//|                                          AutoTP_SL_Exness.mq5    |
//|                        Senior MQL5 Developer & Quant Trader      |
//|                     Optimized for Exness High-Speed Trading      |
//+------------------------------------------------------------------+
#property copyright "Senior MQL5 Developer"
#property link      ""
#property version   "1.20"
#property strict

//--- Input Parameters (mudah diatur dari Properties EA)
input group "=== Pengaturan Take Profit & Stop Loss ==="
input int      TP_Points          = 1000;     // Jarak Take Profit dalam Points (default 1000)
input bool     Use_SL             = false;    // Aktifkan Stop Loss?
input int      SL_Points          = 500;      // Jarak Stop Loss dalam Points (jika aktif)

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
   Print("=== Auto TP/SL Exness v1.20 berhasil dijalankan ===");
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
//| Trade Transaction Handler - DETEKSI PALING CEPAT                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // Kita hanya peduli dengan transaksi penambahan deal (posisi baru)
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   
   // Ambil detail deal
   ulong deal_ticket = trans.deal;
   if(deal_ticket == 0) return;
   
   // Filter hanya deal yang membuka posisi (entry in)
   if(!HistoryDealSelect(deal_ticket)) return;
   
   long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   if(deal_entry != DEAL_ENTRY_IN) return;   // Hanya posisi baru
   
   long deal_type = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   if(deal_type != DEAL_TYPE_BUY && deal_type != DEAL_TYPE_SELL) return;
   
   // Ambil ticket posisi yang baru saja dibuka
   ulong position_ticket = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
   if(position_ticket == 0) return;
   
   // Proses posisi baru
   ProcessNewPosition(position_ticket);
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
   
   string symbol     = PositionGetString(POSITION_SYMBOL);
   long   magic      = PositionGetInteger(POSITION_MAGIC);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   long   pos_type   = PositionGetInteger(POSITION_TYPE);
   double current_tp = PositionGetDouble(POSITION_TP);
   double current_sl = PositionGetDouble(POSITION_SL);
   
   // Filter Magic Number
   if(Magic_Number != 0 && magic != Magic_Number) return;
   
   // Filter hanya simbol chart (jika diaktifkan)
   if(Only_Current_Symbol && symbol != _Symbol) return;
   
   // Jika sudah ada TP yang valid, skip (hindari overwrite)
   if(current_tp > 0)
   {
      // Opsional: uncomment baris di bawah jika ingin selalu overwrite
      // Print("Posisi #", position_ticket, " sudah memiliki TP. Dilewati.");
      // return;
   }
   
   // Hitung nilai point yang benar untuk simbol ini (penting untuk XAUUSD 3 digit)
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   // Hitung harga TP
   double tp_price = 0.0;
   if(pos_type == POSITION_TYPE_BUY)
      tp_price = NormalizeDouble(open_price + TP_Points * point, digits);
   else // SELL
      tp_price = NormalizeDouble(open_price - TP_Points * point, digits);
   
   // Hitung harga SL (jika diaktifkan)
   double sl_price = 0.0;
   if(Use_SL)
   {
      if(pos_type == POSITION_TYPE_BUY)
         sl_price = NormalizeDouble(open_price - SL_Points * point, digits);
      else
         sl_price = NormalizeDouble(open_price + SL_Points * point, digits);
   }
   
   // Lakukan modifikasi dengan retry
   bool success = false;
   for(int attempt = 1; attempt <= Max_Retry; attempt++)
   {
      if(ModifyPosition(position_ticket, sl_price, tp_price, symbol))
      {
         success = true;
         break;
      }
      
      // Jika gagal, tunggu sebentar lalu retry
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
   
   // Kirim request
   bool sent = OrderSend(request, result);
   
   if(!sent || result.retcode != TRADE_RETCODE_DONE)
   {
      // Log error detail
      // Print("Modify gagal | Retcode: ", result.retcode, " | Error: ", GetLastError());
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Optional: OnTick sebagai cadangan (biasanya tidak diperlukan)    |
//+------------------------------------------------------------------+
void OnTick()
{
   // Kosongkan - OnTradeTransaction sudah sangat cepat dan efisien.
   // Jangan taruh logic berat di sini agar latency tetap rendah.
}
