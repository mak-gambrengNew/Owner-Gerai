Migrasi ini sudah diterapkan ke project bhdnkvjktznkdwoqrvlb (qr_drop_every_submit_recorded_in_owner_bills):
- owner_bills: kolom baru payment_option, depo_name, quantity, unit, reception_id (+ indeks, unique per reception)
- receive_ice_by_qr: SETIAP submit (pay_now & bill) membuat 1 baris owner_bills secara atomik
    bill    -> status 'open'
    pay_now -> status 'paid' (paid_at terisi)
- owner_bills ditambahkan ke publikasi supabase_realtime
