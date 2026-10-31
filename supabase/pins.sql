-- =====================================================================
-- Minis ändern ihre PIN selbst (mini.html). Die neue PIN wird nur als Hash gespeichert,
-- Leiter sehen sie nie. Leiter können eine PIN jederzeit zurücksetzen.
-- Voraussetzung: abwesenheiten.sql wurde irgendwann ausgeführt (egal in welcher Version).
-- Diese Datei bringt alles Nötige selbst mit und ist mehrfach ausführbar.
-- =====================================================================
-- 1) Voraussetzungen ---------------------------------------------------
create extension if not exists pgcrypto with schema extensions;
-- Hat der Mini seine PIN selbst geändert, steht hier nur noch ein Hash (für Leiter unlesbar)
alter table public.mini_pins add column if not exists pin_geaendert boolean not null default false;
alter table public.mini_pins drop constraint if exists mini_pins_pin_check;
alter table public.mini_pins drop constraint if exists mini_pins_pin_format;
alter table public.mini_pins add constraint mini_pins_pin_format check (pin_geaendert or pin ~ '^[0-9]{4}$');

-- 2) PIN-Prüfung (mit Unterstützung für selbst geänderte PINs) --------
create or replace function public._mini_pin_check(p_id text, p_pin text)
returns text
language plpgsql
security definer
set search_path = public, extensions
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

  if (case when r.pin_geaendert then r.pin = crypt(coalesce(p_pin, ''), r.pin) else r.pin = coalesce(p_pin, '') end) then
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

-- 3) absence_get liefert zusätzlich, ob die PIN selbst geändert wurde -----
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
  return jsonb_build_object('ok', true,
    'pin_geaendert', (select pin_geaendert from public.mini_pins where messdiener_id = p_id),
    'abwesenheiten', (
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'von', a.von, 'bis', a.bis, 'grund', a.grund) order by a.von), '[]'::jsonb)
      from public.abwesenheiten a
     where a.messdiener_id = p_id and a.bis >= current_date));
end;
$$;

revoke all on function public.absence_get(text, text) from public;
grant execute on function public.absence_get(text, text) to anon, authenticated;

-- 4) PIN ändern ----------------------------------------------------------
create or replace function public.pin_change(p_id text, p_pin text, p_neu text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare status text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  if p_neu is null or p_neu !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', 'format'); end if;
  if p_neu = p_pin then return jsonb_build_object('ok', false, 'error', 'same'); end if;
  update public.mini_pins
     set pin = crypt(p_neu, gen_salt('bf')), pin_geaendert = true, failed_attempts = 0, locked_until = null
   where messdiener_id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.pin_change(text, text, text) from public;
grant execute on function public.pin_change(text, text, text) to anon, authenticated;
