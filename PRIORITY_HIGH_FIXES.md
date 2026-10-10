# MakGambreng — Perbaikan Prioritas Tinggi (10 Oktober 2026)

## Backend Supabase — sudah diterapkan
- Edge Function `monitoring-ingest-sale` versi 10 aktif, `verify_jwt=true`.
- Transaksi baru menyimpan `created_by_spg_id` dari profil SPG yang sudah diverifikasi.
- Edit/hapus hanya diizinkan untuk pembuat transaksi dalam jendela edit yang berlaku. Transaksi lama tanpa identitas pembuat ditolak untuk edit/hapus, bukan diberi pemilik berdasarkan tebakan.
- Harga transaksi dihitung dari riwayat `menu_price_history` yang berlaku pada `occurred_at`, sehingga perubahan harga setelah transaksi tidak otomatis mengubah total transaksi offline.
- Pengiriman ulang ID yang sama hanya dianggap duplikat sukses bila waktu, metode pembayaran, total, dan item cocok. Payload berbeda ditolak dengan `idempotency_key_conflict`.
- Kolom `created_by_spg_id` dan indeksnya ditambahkan di database produksi.

## Frontend PWA — file sudah diperbaiki, belum dipublikasikan
- `gerai/index.html` menambahkan antrean cadangan `localStorage` jika IndexedDB gagal, menggabungkannya saat antrean dibaca, dan menghapus cadangan setelah sinkronisasi sukses.
- Penolakan server dan kegagalan antrean tidak lagi menghapus transaksi dari tampilan lokal secara diam-diam; UI menandai transaksi perlu ditinjau dan memberi peringatan.
- Sintaks JavaScript inline sudah diperiksa dengan `node --check`; arsip ZIP lulus pemeriksaan integritas.

## Catatan operasi
- Arsip ini belum dipublikasikan ke hosting. Deploy frontend setelah meninjau perubahan.
- Ada 3 transaksi lama pada tabel saat pemeriksaan dan semuanya belum memiliki `created_by_spg_id`; transaksi lama tersebut sengaja tidak bisa diedit/dihapus melalui endpoint SPG sampai Owner melakukan rekonsiliasi yang terverifikasi.
- Uji end-to-end dengan akun SPG sungguhan belum dijalankan dalam sesi ini. Sebelum dipakai untuk operasional penuh, tes: transaksi baru, retry identik, retry ID sama dengan isi berbeda, edit/hapus oleh SPG lain, perubahan harga ketika offline, dan IndexedDB gagal.
