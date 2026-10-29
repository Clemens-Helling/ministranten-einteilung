-- =====================================================================
-- Kalender-Abo für Minis: persönlicher Link, der die eigenen Dienste im Handykalender zeigt.
-- Voraussetzung: abwesenheiten.sql wurde schon ausgeführt (PIN-Prüfung).
-- Im Supabase SQL-Editor einmal komplett ausführen. Mehrfaches Ausführen ist unkritisch.
-- Danach die Edge Function "kalender" bereitstellen (siehe supabase/functions/kalender/index.ts).
-- =====================================================================

create table if not exists public.kalender_tokens (
  messdiener_id text primary key,
  token text not null unique default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);
alter table public.kalender_tokens enable row level security;
revoke all on public.kalender_tokens from anon, authenticated;

-- Link-Schlüssel abrufen (nach PIN-Prüfung); wird beim ersten Mal angelegt
create or replace function public.calendar_link(p_id text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text; t text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  insert into public.kalender_tokens (messdiener_id) values (p_id) on conflict do nothing;
  select token into t from public.kalender_tokens where messdiener_id = p_id;
  return jsonb_build_object('ok', true, 'token', t);
end;
$$;

-- Neuen Link erzeugen (alter Link funktioniert dann nicht mehr), z. B. wenn er weitergegeben wurde
create or replace function public.calendar_link_reset(p_id text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  delete from public.kalender_tokens where messdiener_id = p_id;
  return public.calendar_link(p_id, p_pin);
end;
$$;

-- ICS-Text für einen Link-Schlüssel (wird von der Edge Function abgerufen)
create or replace function public.calendar_feed(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text;
  v_name text;
  crlf text := E'\r\n';
  out text;
  r record;
  esc text;
  d date;
  t time;
  team text;
begin
  select messdiener_id into v_id from public.kalender_tokens where token = p_token;
  if v_id is null then return null; end if;
  select name into v_name from public.messdiener where id::text = v_id;

  out := 'BEGIN:VCALENDAR' || crlf || 'VERSION:2.0' || crlf
      || 'PRODID:-//Messdiener-Manager//DE' || crlf || 'CALSCALE:GREGORIAN' || crlf || 'METHOD:PUBLISH' || crlf
      || 'X-WR-CALNAME:Messdienst' || crlf || 'X-WR-TIMEZONE:Europe/Berlin' || crlf
      || 'REFRESH-INTERVAL;VALUE=DURATION:PT6H' || crlf || 'X-PUBLISHED-TTL:PT6H' || crlf
      || 'BEGIN:VTIMEZONE' || crlf || 'TZID:Europe/Berlin' || crlf
      || 'BEGIN:DAYLIGHT' || crlf || 'TZOFFSETFROM:+0100' || crlf || 'TZOFFSETTO:+0200' || crlf || 'TZNAME:CEST' || crlf
      || 'DTSTART:19700329T020000' || crlf || 'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU' || crlf || 'END:DAYLIGHT' || crlf
      || 'BEGIN:STANDARD' || crlf || 'TZOFFSETFROM:+0200' || crlf || 'TZOFFSETTO:+0100' || crlf || 'TZNAME:CET' || crlf
      || 'DTSTART:19701025T030000' || crlf || 'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU' || crlf || 'END:STANDARD' || crlf
      || 'END:VTIMEZONE' || crlf;

  for r in
    select g.id::text as gid, g.title, g.date::text as gdate, nullif(g.time::text, '') as gtime, a.seniors, a.juniors
      from public.gottesdienste g
      join public.assignments a on a.gottesdienst_id::text = g.id::text
     where g.date::date >= current_date - 14
       and exists (
         select 1 from jsonb_array_elements(coalesce(a.seniors, '[]'::jsonb) || coalesce(a.juniors, '[]'::jsonb)) e
          where e ->> 'id' = v_id)
     order by g.date::date, g.time
  loop
    d := r.gdate::date;
    team := (select string_agg(e ->> 'name', ', ')
               from jsonb_array_elements(coalesce(r.seniors, '[]'::jsonb) || coalesce(r.juniors, '[]'::jsonb)) e
              where e ->> 'id' <> v_id);
    esc := regexp_replace(trim(coalesce(r.title, 'Gottesdienst')), '\s*\(.*\)$', '');
    esc := replace(replace(replace(replace(esc, '\', '\\'), ';', '\;'), ',', '\,'), E'\n', ' ');
    out := out || 'BEGIN:VEVENT' || crlf
        || 'UID:gd-' || r.gid || '-' || v_id || '@messdiener-manager' || crlf
        || 'DTSTAMP:' || to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"') || crlf;
    if r.gtime is not null then
      t := r.gtime::time;
      out := out || 'DTSTART;TZID=Europe/Berlin:' || to_char(d + t, 'YYYYMMDD"T"HH24MISS') || crlf
                 || 'DTEND;TZID=Europe/Berlin:' || to_char(d + t + interval '1 hour', 'YYYYMMDD"T"HH24MISS') || crlf;
    else
      out := out || 'DTSTART;VALUE=DATE:' || to_char(d, 'YYYYMMDD') || crlf
                 || 'DTEND;VALUE=DATE:' || to_char(d + 1, 'YYYYMMDD') || crlf;
    end if;
    out := out || 'SUMMARY:Messdienst: ' || esc || crlf;
    if team is not null then
      out := out || 'DESCRIPTION:Mit ' || replace(replace(replace(team, '\', '\\'), ';', '\;'), ',', '\,') || crlf;
    end if;
    out := out || 'END:VEVENT' || crlf;
  end loop;

  return out || 'END:VCALENDAR' || crlf;
end;
$$;

revoke all on function public.calendar_link(text, text) from public;
revoke all on function public.calendar_link_reset(text, text) from public;
revoke all on function public.calendar_feed(text) from public;
grant execute on function public.calendar_link(text, text) to anon, authenticated;
grant execute on function public.calendar_link_reset(text, text) to anon, authenticated;
grant execute on function public.calendar_feed(text) to anon, authenticated;
