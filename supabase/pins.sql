-- =====================================================================
-- Minis ändern ihre PIN selbst (mini.html). Die neue PIN wird nur als Hash gespeichert,
-- Leiter sehen sie nie. Leiter können eine PIN jederzeit zurücksetzen.
-- Reihenfolge: zuerst supabase/abwesenheiten.sql (aktuelle Version) ausführen, dann diese Datei.
-- Mehrfaches Ausführen ist unkritisch.
-- =====================================================================
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
