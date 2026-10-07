# Supabase integration contract

## Authentication
Supabase Auth email/password. The legacy `verify_owner_access` RPC is not used for production session creation because it only validates a code and returns an owner id; it does not mint an Auth session. The existing Owner RPCs require `auth.uid()`.

## Source of truth
All operational values displayed by the PWA are loaded from Supabase after authentication.

## CRUD mapping
- Gerai → `owner_upsert_store`
- Menu → `owner_upsert_menu`
- Inventory → `owner_create_inventory_item` / `owner_update_inventory_item`
- SPG / Checker → `owner_update_member` + `owner_set_member_status`
- WhatsApp Es Kristal → `owner_upsert_whatsapp_contact`

Deletes are implemented as server-side deactivation where the backend contract exposes status, preserving operational history.

## Realtime
Subscriptions refresh the dashboard when stores, menus, inventory, monitoring transactions, operation sessions, notifications, or audit logs change.

## Owner access code

The public login page intentionally does not ask for email. The `owner_get_login_identity` RPC resolves the active Owner from `businesses.owner_id` and returns the current Auth email needed for sign-in. The browser then calls `signInWithPassword()` with that email and the entered access code. All existing Owner RPCs continue to use `auth.uid()` and RLS.

## Hapus permanen + Arsip Riwayat
Hapus oleh Owner adalah **hapus permanen** (bukan nonaktif). Sebelum data dihapus, riwayatnya disalin ke `owner_history_archive`
(tanpa foreign key ke data yang dihapus) dan dicatat di `owner_deletion_log`, sehingga riwayat/log tetap ada.

| Data | RPC |
| --- | --- |
| Gerai | `owner_remove_store` |
| Menu | `owner_remove_menu` |
| Logistik | `owner_remove_inventory_item` |
| SPG / Checker | `owner_remove_member` |
| Kontak WhatsApp Es Kristal | `owner_remove_whatsapp_contact` |

Semua berjalan dalam satu transaksi: jika ada sisa data yang tidak bisa dibersihkan, seluruh penghapusan dibatalkan.
Owner melihat arsip di Pengaturan > Arsip Riwayat Terhapus. Migrasi: `supabase/migrations/owner_hard_delete_with_history_archive.sql`.

## Revisi Owner CRUD (v11)
Migrasi wajib diterapkan: `supabase/migrations/owner_audit_append_only_snapshot_atomic_crud.sql`.
- `audit_logs` append-only (trigger + tanpa hak tulis dari browser), berisi snapshot `entity_name`, `actor_name`, `before_data`, `after_data`; tidak bergantung pada record operasional.
- Hapus Owner hanya lewat `owner_remove_*` (atomik: arsip -> hapus -> audit). Jalur DELETE langsung dan fungsi hapus lama dinonaktifkan.
- Edit SPG/Checker atomik lewat `owner_save_member`.
- Jika tombol hapus tidak menambah baris di `owner_deletion_log`, aplikasi yang berjalan adalah build lama: deploy ulang.

## Laporan Penjualan harian (tab Laporan)
Migrasi wajib: `supabase/migrations/owner_sales_daily_report.sql`.

Alur data: semua gerai tutup (`checker_close_store_session`) → Checker menjalankan `finalize_monitoring_day` → snapshot final `monitoring_daily_*` dibuat dan `monitoring_daily_closures.status='closed'` → trigger mengirim notifikasi ke Owner → tab Laporan memuat laporan terbaru.

| RPC | Fungsi |
| --- | --- |
| `owner_get_sales_report(p_sales_date date default null)` | `null` = laporan final terakhir. Status: `FINAL`, `NO_REPORT` (tanggal tanpa laporan; berisi tanggal terdekat), `NONE_AVAILABLE` (belum ada laporan sama sekali). |
| `owner_list_sales_report_dates(p_limit int default 60)` | Daftar tanggal yang punya laporan final (untuk chip tanggal). |

- "Total penjualan" = jumlah porsi terjual, **bukan** nominal rupiah. Ditampilkan total, per gerai, dan per menu (dengan rincian per gerai).
- Kedua RPC `SECURITY DEFINER`, read-only, memvalidasi Owner lewat `auth.uid()`. Role `authenticated` tidak punya SELECT langsung pada `monitoring_daily_closures`, `monitoring_daily_store_closures`, dan `monitoring_daily_menu_sales`, sehingga `owner_get_report` (invoker) tidak bisa dipakai untuk halaman ini.
- Halaman yang terbuka ikut diperbarui saat notifikasi/polling masuk; bila Owner sedang melihat "laporan terakhir" dan laporan baru tiba, tampilan berpindah otomatis.
