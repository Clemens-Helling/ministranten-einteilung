-- =====================================================================
-- Abwesenheiten der Minis (Eintragung über abwesenheit.html mit PIN)
-- Im Supabase SQL-Editor einmal komplett ausführen. Mehrfaches Ausführen ist unkritisch.
-- =====================================================================

-- 1) Tabellen -----------------------------------------------------------
create table if not exists public.abwesenheiten (
  id bigint generated always as identity primary key,
  messdiener_id text not null,
  von date not null,
  bis date not null,
  created_at timestamptz not null default now(),
  constraint abwesenheit_zeitraum check (bis >= von)
);
create index if not exists abwesenheiten_mini_idx on public.abwesenheiten (messdiener_id, von);

create table if not exists public.mini_pins (
  messdiener_id text primary key,
  pin text not null check (pin ~ '^[0-9]{4}$'),
  failed_attempts int not null default 0,
  locked_until timestamptz
);

-- 2) Zugriff: Tabellen nur für angemeldete Leiter, Minis nur über die Funktionen unten
alter table public.abwesenheiten enable row level security;
alter table public.mini_pins enable row level security;

drop policy if exists "leiter alles" on public.abwesenheiten;
create policy "leiter alles" on public.abwesenheiten for all to authenticated using (true) with check (true);
drop policy if exists "leiter alles" on public.mini_pins;
create policy "leiter alles" on public.mini_pins for all to authenticated using (true) with check (true);

revoke all on public.abwesenheiten from anon;
revoke all on public.mini_pins from anon;
grant select, insert, update, delete on public.abwesenheiten to authenticated;
grant select, insert, update, delete on public.mini_pins to authenticated;

-- 3) Interne PIN-Prüfung mit Sperre nach 5 Fehlversuchen (15 Minuten) -----
create or replace function public._mini_pin_check(p_id text, p_pin text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare r public.mini_pins%rowtype;
begin
  select * into r from public.mini_pins where messdiener_id = p_id for update;
  if not found then return 'nopin'; end if;

  if r.locked_until is not null and r.locked_until > now() then
    return 'locked';
  end if;
  if r.locked_until is not null then  -- Sperre abgelaufen
    update public.mini_pins set failed_attempts = 0, locked_until = null where messdiener_id = p_id;
    r.failed_attempts := 0;
  end if;

  if r.pin = coalesce(p_pin, '') then
    if r.failed_attempts > 0 then
      update public.mini_pins set failed_attempts = 0 where messdiener_id = p_id;
    end if;
    return 'ok';
  end if;

  update public.mini_pins
     set failed_attempts = failed_attempts + 1,
         locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' end
   where messdiener_id = p_id;
  return 'wrong';
end;
$$;
revoke all on function public._mini_pin_check(text, text) from public, anon, authenticated;

-- 4) Funktionen für die Abwesenheits-Seite --------------------------------
-- Namensliste (gekürzt: "Lukas G."), nur Minis mit PIN
create or replace function public.absence_names()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id::text,
           'name', case when position(' ' in trim(m.name)) > 0
                        then split_part(trim(m.name), ' ', 1) || ' ' || upper(left(regexp_replace(trim(m.name), '^.*\s', ''), 1)) || '.'
                        else trim(m.name) end
         ) order by m.name), '[]'::jsonb)
    from public.messdiener m
    join public.mini_pins p on p.messdiener_id = m.id::text;
$$;

-- Eigene Abwesenheiten (ab heute) abrufen
create or replace function public.absence_get(p_id text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  return jsonb_build_object('ok', true, 'abwesenheiten', (
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'von', a.von, 'bis', a.bis) order by a.von), '[]'::jsonb)
      from public.abwesenheiten a
     where a.messdiener_id = p_id and a.bis >= current_date));
end;
$$;

-- Abwesenheit eintragen
create or replace function public.absence_add(p_id text, p_pin text, p_von date, p_bis date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;

  if p_von is null or p_bis is null or p_bis < p_von then
    return jsonb_build_object('ok', false, 'error', 'dates');
  end if;
  if p_bis < current_date or p_bis - p_von > 366 then
    return jsonb_build_object('ok', false, 'error', 'dates');
  end if;
  if (select count(*) from public.abwesenheiten where messdiener_id = p_id and bis >= current_date) >= 50 then
    return jsonb_build_object('ok', false, 'error', 'limit');
  end if;

  insert into public.abwesenheiten (messdiener_id, von, bis) values (p_id, p_von, p_bis);
  return public.absence_get(p_id, p_pin);
end;
$$;

-- Abwesenheit löschen
create or replace function public.absence_delete(p_id text, p_pin text, p_abs_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  delete from public.abwesenheiten where id = p_abs_id and messdiener_id = p_id;
  return public.absence_get(p_id, p_pin);
end;
$$;

revoke all on function public.absence_names() from public;
revoke all on function public.absence_get(text, text) from public;
revoke all on function public.absence_add(text, text, date, date) from public;
revoke all on function public.absence_delete(text, text, bigint) from public;
grant execute on function public.absence_names() to anon, authenticated;
grant execute on function public.absence_get(text, text) to anon, authenticated;
grant execute on function public.absence_add(text, text, date, date) to anon, authenticated;
grant execute on function public.absence_delete(text, text, bigint) to anon, authenticated;
