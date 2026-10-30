-- =====================================================================
-- Tatsächliche Anwesenheit: Minis scannen in der Sakristei einen QR-Code (anwesenheit.html, mit PIN).
-- Leiter können Anwesenheit im Nachhinein in der App nachtragen.
-- Voraussetzung: abwesenheiten.sql wurde schon ausgeführt (PIN-Prüfung).
-- Im Supabase SQL-Editor einmal komplett ausführen. Mehrfaches Ausführen ist unkritisch.
-- =====================================================================

create table if not exists public.anwesenheit (
  gottesdienst_id text not null,
  messdiener_id text not null,
  zeit timestamptz not null default now(),
  quelle text not null default 'qr' check (quelle in ('qr', 'leiter')),
  primary key (gottesdienst_id, messdiener_id)
);
alter table public.anwesenheit enable row level security;
drop policy if exists "leiter alles" on public.anwesenheit;
create policy "leiter alles" on public.anwesenheit for all to authenticated using (true) with check (true);
revoke all on public.anwesenheit from anon;
grant select, insert, update, delete on public.anwesenheit to authenticated;

-- Geheimer Schlüssel im QR-Code (kann bei Bedarf erneuert werden)
create table if not exists public.einstellungen (
  schluessel text primary key,
  wert text not null
);
alter table public.einstellungen enable row level security;
drop policy if exists "leiter lesen" on public.einstellungen;
create policy "leiter lesen" on public.einstellungen for select to authenticated using (true);
revoke all on public.einstellungen from anon;
revoke all on public.einstellungen from authenticated;
grant select on public.einstellungen to authenticated;
insert into public.einstellungen (schluessel, wert)
values ('sakristei_key', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict do nothing;

-- Neuen QR-Schlüssel erzeugen (nur Admins, falls rollen.sql eingerichtet ist)
create or replace function public.attendance_key_reset()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare k text;
begin
  if auth.uid() is null then raise exception 'nicht angemeldet'; end if;
  if to_regprocedure('public.is_admin()') is not null then
    if not public.is_admin() then raise exception 'nur Admins'; end if;
  end if;
  k := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.einstellungen (schluessel, wert) values ('sakristei_key', k)
  on conflict (schluessel) do update set wert = excluded.wert;
  return k;
end;
$$;
revoke all on function public.attendance_key_reset() from public, anon;
grant execute on function public.attendance_key_reset() to authenticated;

-- Gottesdienste, bei denen man gerade einchecken kann: 90 Min. vor bis 150 Min. nach Beginn
create or replace function public._checkin_list(p_id text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id::text,
           'titel', g.title,
           'zeit', nullif(g.time::text, ''),
           'eingeteilt', exists (
              select 1 from public.assignments a
               where a.gottesdienst_id::text = g.id::text
                 and exists (select 1 from jsonb_array_elements(coalesce(a.seniors, '[]'::jsonb) || coalesce(a.juniors, '[]'::jsonb)) e
                              where e ->> 'id' = p_id)),
           'eingetragen', (select to_char(w.zeit at time zone 'Europe/Berlin', 'HH24:MI') from public.anwesenheit w
                            where w.gottesdienst_id = g.id::text and w.messdiener_id = p_id)
         ) order by g.date, g.time), '[]'::jsonb)
    from public.gottesdienste g
   where g.date::date between (now() at time zone 'Europe/Berlin')::date - 1 and (now() at time zone 'Europe/Berlin')::date + 1
     and now() between ((g.date::date + coalesce(nullif(g.time::text, '')::time, time '00:00')) at time zone 'Europe/Berlin') - interval '90 minutes'
                   and ((g.date::date + coalesce(nullif(g.time::text, '')::time, time '00:00')) at time zone 'Europe/Berlin')
                       + case when nullif(g.time::text, '') is null then interval '24 hours' else interval '150 minutes' end;
$$;
revoke all on function public._checkin_list(text) from public, anon, authenticated;

create or replace function public.checkin_list(p_key text, p_id text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text;
begin
  if p_key is null or p_key <> (select wert from public.einstellungen where schluessel = 'sakristei_key') then
    return jsonb_build_object('ok', false, 'error', 'badkey');
  end if;
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  return jsonb_build_object('ok', true, 'dienste', public._checkin_list(p_id));
end;
$$;

create or replace function public.checkin_set(p_key text, p_id text, p_pin text, p_gid text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text;
begin
  if p_key is null or p_key <> (select wert from public.einstellungen where schluessel = 'sakristei_key') then
    return jsonb_build_object('ok', false, 'error', 'badkey');
  end if;
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  if not exists (select 1 from jsonb_array_elements(public._checkin_list(p_id)) e where e ->> 'id' = p_gid) then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;
  insert into public.anwesenheit (gottesdienst_id, messdiener_id, quelle) values (p_gid, p_id, 'qr') on conflict do nothing;
  return jsonb_build_object('ok', true, 'dienste', public._checkin_list(p_id));
end;
$$;

revoke all on function public.checkin_list(text, text, text) from public;
revoke all on function public.checkin_set(text, text, text, text) from public;
grant execute on function public.checkin_list(text, text, text) to anon, authenticated;
grant execute on function public.checkin_set(text, text, text, text) to anon, authenticated;
