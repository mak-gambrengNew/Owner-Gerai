# MakGambreng — Perbaikan Prioritas Menengah

Tanggal: 2026-10-10

## Perubahan

1. **Sinkronisasi penjualan lintas-tab**
   - `gerai/index.html` memakai Web Locks API bila tersedia agar dua tab tidak mengirim antrean penjualan secara bersamaan.
   - Browser yang belum mendukung Web Locks memakai lease `localStorage` yang kedaluwarsa otomatis.
   - Idempotensi server tetap menjadi perlindungan utama; lock browser adalah perlindungan tambahan.

2. **Indeks query operasional**
   - `idx_menu_price_history_business_menu_changed` mendukung pencarian riwayat harga menurut bisnis, menu, dan waktu perubahan.
   - `idx_store_operation_sessions_store_business_opened` mendukung pencarian sesi operasi berdasarkan gerai, bisnis, dan waktu buka.
   - Migration sudah diterapkan ke Supabase dan kedua indeks telah diverifikasi ada.

3. **Validasi file**
   - JavaScript inline pada `gerai/index.html` lulus `node --check`.

## Catatan deploy

Perubahan database sudah aktif di Supabase. Perubahan frontend masih berupa sumber lokal dalam arsip ini; deploy ke hosting diperlukan sebelum lock lintas-tab berlaku pada perangkat pengguna.

## Batasan

Ini belum menggantikan pengujian perangkat nyata untuk dua tab, jaringan putus-sambung, token kedaluwarsa, serta transaksi offline. Lease localStorage pada browser lama merupakan best-effort; server dan idempotensi tetap harus dianggap sebagai sumber kebenaran.
