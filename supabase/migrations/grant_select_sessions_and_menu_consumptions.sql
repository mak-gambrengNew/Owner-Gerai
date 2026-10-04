-- Sudah diterapkan ke proyek bhdnkvjktznkdwoqrvlb.
-- Owner membaca sesi operasi gerai (status BUKA/TUTUP) dan komposisi menu lewat REST.
-- Policy RLS Owner/Checker/SPG sudah ada; tanpa GRANT dasar query ditolak "permission denied".
grant select on public.store_operation_sessions to authenticated;
grant select on public.menu_inventory_consumptions to authenticated;
