-- =====================================================================
-- Mini-Seite (mini.html): Liste der eigenen kommenden Dienste.
-- Voraussetzung: abwesenheiten.sql wurde schon ausgeführt (PIN-Prüfung).
-- Im Supabase SQL-Editor einmal ausführen. Mehrfaches Ausführen ist unkritisch.
-- =====================================================================
create or replace function public.my_services(p_id text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  return jsonb_build_object('ok', true, 'dienste', (
    select coalesce(jsonb_agg(x order by x ->> 'datum', x ->> 'zeit'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'id', g.id::text,
                 'titel', g.title,
                 'datum', g.date::text,
                 'zeit', nullif(g.time::text, ''),
                 'team', (select string_agg(e ->> 'name', ', ')
                            from jsonb_array_elements(coalesce(a.seniors, '[]'::jsonb) || coalesce(a.juniors, '[]'::jsonb)) e
                           where e ->> 'id' <> p_id)) as x
          from public.gottesdienste g
          join public.assignments a on a.gottesdienst_id::text = g.id::text
         where g.date::date >= (now() at time zone 'Europe/Berlin')::date
           and exists (select 1 from jsonb_array_elements(coalesce(a.seniors, '[]'::jsonb) || coalesce(a.juniors, '[]'::jsonb)) e
                        where e ->> 'id' = p_id)
         order by g.date::date, g.time
         limit 30) t));
end;
$$;
revoke all on function public.my_services(text, text) from public;
grant execute on function public.my_services(text, text) to anon, authenticated;
