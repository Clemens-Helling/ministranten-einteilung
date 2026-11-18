-- Confirmed assignment snapshots for statistics and fair future scheduling.
-- No foreign key to gottesdienste: deleting a service must not delete its history.
-- Run once in the Supabase SQL editor. Safe to run again.

create table if not exists public.einteilung_statistik (
  gottesdienst_id text primary key,
  service_date date not null,
  service_title text not null,
  seniors jsonb not null default '[]'::jsonb,
  juniors jsonb not null default '[]'::jsonb,
  confirmed_at timestamptz not null default now()
);

alter table public.einteilung_statistik enable row level security;
drop policy if exists "leiter verwalten einteilungsstatistik" on public.einteilung_statistik;
create policy "leiter verwalten einteilungsstatistik"
  on public.einteilung_statistik for all to authenticated
  using (true) with check (true);

revoke all on public.einteilung_statistik from anon;
grant select, insert, update, delete on public.einteilung_statistik to authenticated;
