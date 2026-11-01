-- =====================================================================
-- Vertretung suchen: Minis fragen andere Minis an, diese nehmen an oder lehnen ab.
-- Bei Annahme wird die Einteilung automatisch getauscht.
-- Voraussetzung: abwesenheiten.sql (PIN-Prüfung) und mini.sql wurden schon ausgeführt.
-- Im Supabase SQL-Editor einmal ausführen. Mehrfaches Ausführen ist unkritisch.
-- =====================================================================

-- 1) Tabellen -----------------------------------------------------------
create table if not exists public.vertretungen (
  id bigint generated always as identity primary key,
  gottesdienst_id text not null,
  von_id text not null,           -- wer eine Vertretung sucht
  an_id text not null,            -- wer angefragt wurde
  status text not null default 'offen'
    check (status in ('offen', 'angenommen', 'abgelehnt', 'vergeben', 'zurueckgezogen')),
  gepusht boolean not null default false,          -- Push "Anfrage" an an_id verschickt
  antwort_gepusht boolean not null default false,  -- Push "Antwort" an von_id verschickt
  created_at timestamptz not null default now(),
  beantwortet_am timestamptz,
  unique (gottesdienst_id, von_id, an_id)
);
alter table public.vertretungen enable row level security;
drop policy if exists "Leiter lesen Vertretungen" on public.vertretungen;
create policy "Leiter lesen Vertretungen" on public.vertretungen for select to authenticated using (true);

-- Push-Abos der Geräte (nur über die Funktionen unten und die Edge Function erreichbar)
create table if not exists public.push_abos (
  endpoint text primary key,
  messdiener_id text not null,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_abos enable row level security;
create index if not exists push_abos_mini_idx on public.push_abos (messdiener_id);

-- 2) Hilfsfunktionen (nicht öffentlich aufrufbar) --------------------------
create or replace function public._sv_kurz(n text) returns text
language sql immutable as $$
  select case when position(' ' in trim(n)) > 0
              then split_part(trim(n), ' ', 1) || ' ' || upper(left(regexp_replace(trim(n), '^.*\s', ''), 1)) || '.'
              else trim(n) end
$$;

-- In welcher Liste steht die Person bei diesem Gottesdienst? 'seniors' | 'juniors' | null
create or replace function public._sv_slot(gid text, pid text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.assignments a, jsonb_array_elements(coalesce(a.seniors, '[]'::jsonb)) e
                  where a.gottesdienst_id::text = gid and e ->> 'id' = pid) then 'seniors'
    when exists (select 1 from public.assignments a, jsonb_array_elements(coalesce(a.juniors, '[]'::jsonb)) e
                  where a.gottesdienst_id::text = gid and e ->> 'id' = pid) then 'juniors'
  end
$$;

create or replace function public._sv_absent(pid text, d date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.abwesenheiten where messdiener_id = pid and d between von and bis)
$$;

-- Datum des Gottesdienstes, wenn er noch bevorsteht, sonst null
create or replace function public._sv_datum(gid text) returns date
language sql stable security definer set search_path = public as $$
  select g.date::date from public.gottesdienste g
   where g.id::text = gid and g.date::date >= (now() at time zone 'Europe/Berlin')::date
$$;

-- Darf diese Person für diese Liste einspringen? (richtige Rolle, nicht schon eingeteilt, nicht abwesend)
create or replace function public._sv_eligible(gid text, pid text, slot text, d date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.messdiener m
                  where m.id::text = pid
                    and ((slot = 'seniors' and m.type = 'Senior') or (slot = 'juniors' and m.type = 'Junior')))
     and public._sv_slot(gid, pid) is null
     and not public._sv_absent(pid, d)
$$;

revoke all on function public._sv_slot(text, text), public._sv_absent(text, date),
  public._sv_datum(text), public._sv_eligible(text, text, text, date) from public, anon, authenticated;

-- 3) Wer kommt als Vertretung in Frage? ----------------------------------
create or replace function public.sub_candidates(p_id text, p_pin text, p_gid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; d date; slot text; dow int;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  d := public._sv_datum(p_gid);
  slot := public._sv_slot(p_gid, p_id);
  if d is null or slot is null then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  dow := extract(dow from d)::int;
  return jsonb_build_object('ok', true, 'kandidaten', (
    select coalesce(jsonb_agg(x order by (x ->> 'passt')::boolean desc, x ->> 'name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'id', m.id::text,
                 'name', public._sv_kurz(m.name),
                 'passt', (coalesce(jsonb_array_length(to_jsonb(m.days)), 0) = 0 or to_jsonb(m.days) @> to_jsonb(dow)),
                 'status', (select v.status from public.vertretungen v
                             where v.gottesdienst_id = p_gid and v.von_id = p_id and v.an_id = m.id::text)) as x
          from public.messdiener m
         where m.id::text <> p_id and public._sv_eligible(p_gid, m.id::text, slot, d)) t));
end $$;

-- 4) Anfrage verschicken ---------------------------------------------------
create or replace function public.sub_request(p_id text, p_pin text, p_gid text, p_an_ids jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; d date; slot text; one text; n int := 0;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  d := public._sv_datum(p_gid);
  slot := public._sv_slot(p_gid, p_id);
  if d is null or slot is null then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if jsonb_typeof(p_an_ids) <> 'array' then return jsonb_build_object('ok', false, 'error', 'empty'); end if;
  for one in select distinct value from jsonb_array_elements_text(p_an_ids) limit 10 loop
    if one <> p_id and public._sv_eligible(p_gid, one, slot, d) then
      insert into public.vertretungen (gottesdienst_id, von_id, an_id) values (p_gid, p_id, one)
      on conflict (gottesdienst_id, von_id, an_id) do update
        set status = 'offen', gepusht = false, antwort_gepusht = false, created_at = now(), beantwortet_am = null
        where public.vertretungen.status in ('abgelehnt', 'vergeben', 'zurueckgezogen');
      n := n + 1;
    end if;
  end loop;
  if n = 0 then return jsonb_build_object('ok', false, 'error', 'empty'); end if;
  return jsonb_build_object('ok', true, 'angefragt', n);
end $$;

-- 5) Eingang (an mich) und Ausgang (von mir) ------------------------------
create or replace function public.sub_inbox(p_id text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  return jsonb_build_object('ok', true,
    'eingang', (select coalesce(jsonb_agg(x order by x ->> 'datum', x ->> 'zeit'), '[]'::jsonb) from (
        select jsonb_build_object('id', v.id, 'gottesdienst_id', v.gottesdienst_id, 'von', public._sv_kurz(m.name), 'titel', g.title,
                                  'datum', g.date::text, 'zeit', nullif(g.time::text, '')) as x
          from public.vertretungen v
          join public.gottesdienste g on g.id::text = v.gottesdienst_id
          join public.messdiener m on m.id::text = v.von_id
         where v.an_id = p_id and v.status = 'offen'
           and g.date::date >= (now() at time zone 'Europe/Berlin')::date) t),
    'ausgang', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_build_object('gottesdienst_id', v.gottesdienst_id, 'an', public._sv_kurz(m.name), 'status', v.status,
                                  'titel', g.title, 'datum', g.date::text, 'zeit', nullif(g.time::text, '')) as x
          from public.vertretungen v
          join public.gottesdienste g on g.id::text = v.gottesdienst_id
          join public.messdiener m on m.id::text = v.an_id
         where v.von_id = p_id and v.status <> 'zurueckgezogen'
           and g.date::date >= (now() at time zone 'Europe/Berlin')::date
         order by m.name) t));
end $$;

-- 6) Annehmen / Ablehnen -----------------------------------------------------
create or replace function public.sub_answer(p_id text, p_pin text, p_req bigint, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; v public.vertretungen; d date; slot text; newp jsonb;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  select * into v from public.vertretungen where id = p_req and an_id = p_id for update;
  if not found or v.status <> 'offen' then return jsonb_build_object('ok', false, 'error', 'gone'); end if;

  if not p_accept then
    update public.vertretungen set status = 'abgelehnt', beantwortet_am = now() where id = v.id;
    return jsonb_build_object('ok', true, 'status', 'abgelehnt');
  end if;

  d := public._sv_datum(v.gottesdienst_id);
  slot := public._sv_slot(v.gottesdienst_id, v.von_id);
  if d is null or slot is null then
    update public.vertretungen set status = 'vergeben' where id = v.id;
    return jsonb_build_object('ok', false, 'error', 'gone');
  end if;
  if public._sv_slot(v.gottesdienst_id, p_id) is not null then return jsonb_build_object('ok', false, 'error', 'already'); end if;
  if public._sv_absent(p_id, d) then return jsonb_build_object('ok', false, 'error', 'absent'); end if;
  if not public._sv_eligible(v.gottesdienst_id, p_id, slot, d) then return jsonb_build_object('ok', false, 'error', 'gone'); end if;

  select to_jsonb(m) into newp from public.messdiener m where m.id::text = p_id;
  update public.assignments a set
    seniors = case when slot = 'seniors' then
      (select coalesce(jsonb_agg(case when e ->> 'id' = v.von_id then newp else e end order by ord), '[]'::jsonb)
         from jsonb_array_elements(coalesce(a.seniors, '[]'::jsonb)) with ordinality t(e, ord)) else a.seniors end,
    juniors = case when slot = 'juniors' then
      (select coalesce(jsonb_agg(case when e ->> 'id' = v.von_id then newp else e end order by ord), '[]'::jsonb)
         from jsonb_array_elements(coalesce(a.juniors, '[]'::jsonb)) with ordinality t(e, ord)) else a.juniors end
   where a.gottesdienst_id::text = v.gottesdienst_id;

  update public.vertretungen set status = 'angenommen', beantwortet_am = now() where id = v.id;
  update public.vertretungen set status = 'vergeben'
   where gottesdienst_id = v.gottesdienst_id and von_id = v.von_id and status = 'offen' and id <> v.id;
  return jsonb_build_object('ok', true, 'status', 'angenommen');
end $$;

-- 7) Anfragen zurückziehen -----------------------------------------------------
create or replace function public.sub_cancel(p_id text, p_pin text, p_gid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  update public.vertretungen set status = 'zurueckgezogen', beantwortet_am = now()
   where gottesdienst_id = p_gid and von_id = p_id and status = 'offen';
  return jsonb_build_object('ok', true);
end $$;

-- 8) Was muss per Push verschickt werden? (wird von der Edge Function "push" aufgerufen)
create or replace function public.sub_notify_info(p_id text, p_pin text, p_gid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  return jsonb_build_object('ok', true, 'eintraege', (
    select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object(
               'id', v.id,
               'art', case when v.von_id = p_id then 'anfrage' else 'antwort' end,
               'von_id', v.von_id, 'von', public._sv_kurz(mv.name),
               'an_id', v.an_id, 'an', public._sv_kurz(ma.name),
               'status', v.status, 'titel', g.title, 'datum', g.date::text, 'zeit', nullif(g.time::text, '')) as x
        from public.vertretungen v
        join public.gottesdienste g on g.id::text = v.gottesdienst_id
        join public.messdiener mv on mv.id::text = v.von_id
        join public.messdiener ma on ma.id::text = v.an_id
       where v.gottesdienst_id = p_gid
         and ((v.von_id = p_id and v.status = 'offen' and not v.gepusht)
           or (v.an_id = p_id and v.status in ('angenommen', 'abgelehnt') and not v.antwort_gepusht))) t));
end $$;

-- 9) Push-Abo des Geräts speichern / entfernen ------------------------------------
create or replace function public.push_save(p_id text, p_pin text, p_endpoint text, p_p256dh text, p_auth text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    return jsonb_build_object('ok', false, 'error', 'format');
  end if;
  insert into public.push_abos (endpoint, messdiener_id, p256dh, auth) values (p_endpoint, p_id, p_p256dh, p_auth)
  on conflict (endpoint) do update set messdiener_id = excluded.messdiener_id, p256dh = excluded.p256dh, auth = excluded.auth;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.push_remove(p_id text, p_pin text, p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  delete from public.push_abos where endpoint = p_endpoint and messdiener_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 10) Rechte ---------------------------------------------------------------------
revoke all on function public.sub_candidates(text, text, text), public.sub_request(text, text, text, jsonb),
  public.sub_inbox(text, text), public.sub_answer(text, text, bigint, boolean), public.sub_cancel(text, text, text),
  public.sub_notify_info(text, text, text), public.push_save(text, text, text, text, text),
  public.push_remove(text, text, text) from public;
grant execute on function public.sub_candidates(text, text, text), public.sub_request(text, text, text, jsonb),
  public.sub_inbox(text, text), public.sub_answer(text, text, bigint, boolean), public.sub_cancel(text, text, text),
  public.sub_notify_info(text, text, text), public.push_save(text, text, text, text, text),
  public.push_remove(text, text, text) to anon, authenticated;
