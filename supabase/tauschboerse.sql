-- =====================================================================
-- Tauschbörse: Minis stellen einen eigenen Dienst ein, andere Minis übernehmen ihn oder tauschen.
--   "abgeben": Wer in Frage kommt, übernimmt den Dienst sofort.
--   "tausch":  Andere bieten einen eigenen Dienst dagegen an, der Anbieter nimmt einen Vorschlag an oder lehnt ab.
-- Bei Übernahme bzw. Tausch wird die Einteilung (assignments) automatisch geändert. Existiert für den Gottesdienst
-- schon eine bestätigte Einteilung (einteilung_statistik), wird auch sie angepasst, damit die Häufigkeit stimmt.
-- Voraussetzung: abwesenheiten.sql, mini.sql und vertretung.sql wurden schon ausgeführt.
-- Im Supabase SQL-Editor einmal ausführen. Mehrfaches Ausführen ist unkritisch.
-- =====================================================================

-- 1) Tabellen -----------------------------------------------------------
create table if not exists public.tauschboerse (
  id bigint generated always as identity primary key,
  gottesdienst_id text not null,
  von_id text not null,            -- wer den Dienst einstellt
  modus text not null check (modus in ('abgeben', 'tausch')),
  status text not null default 'offen'
    check (status in ('offen', 'vergeben', 'getauscht', 'zurueckgezogen')),
  uebernommen_von text,            -- wer den Dienst bekommen hat
  created_at timestamptz not null default now(),
  erledigt_am timestamptz
);
create unique index if not exists tauschboerse_ein_angebot_idx
  on public.tauschboerse (gottesdienst_id, von_id) where status = 'offen';
alter table public.tauschboerse enable row level security;
drop policy if exists "Leiter lesen Tauschbörse" on public.tauschboerse;
create policy "Leiter lesen Tauschbörse" on public.tauschboerse for select to authenticated using (true);

create table if not exists public.tausch_vorschlaege (
  id bigint generated always as identity primary key,
  angebot_id bigint not null references public.tauschboerse(id) on delete cascade,
  von_id text not null,            -- wer einen Tausch vorschlägt
  gottesdienst_id text not null,   -- der eigene Dienst, den er dafür hergibt
  status text not null default 'offen'
    check (status in ('offen', 'angenommen', 'abgelehnt', 'zurueckgezogen')),
  created_at timestamptz not null default now(),
  beantwortet_am timestamptz,
  unique (angebot_id, von_id, gottesdienst_id)
);
alter table public.tausch_vorschlaege enable row level security;
drop policy if exists "Leiter lesen Tauschvorschläge" on public.tausch_vorschlaege;
create policy "Leiter lesen Tauschvorschläge" on public.tausch_vorschlaege for select to authenticated using (true);

-- 2) Hilfsfunktionen (nicht öffentlich aufrufbar) -------------------------
-- Person old_id durch newp ersetzen: in der Einteilung und in der bestätigten Einteilung
create or replace function public._tb_replace(gid text, old_id text, newp jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.assignments a set
    seniors = (select coalesce(jsonb_agg(case when e ->> 'id' = old_id then newp else e end order by ord), '[]'::jsonb)
                 from jsonb_array_elements(coalesce(a.seniors, '[]'::jsonb)) with ordinality t(e, ord)),
    juniors = (select coalesce(jsonb_agg(case when e ->> 'id' = old_id then newp else e end order by ord), '[]'::jsonb)
                 from jsonb_array_elements(coalesce(a.juniors, '[]'::jsonb)) with ordinality t(e, ord))
   where a.gottesdienst_id::text = gid;
  if to_regclass('public.einteilung_statistik') is not null then
    execute $q$
      update public.einteilung_statistik s set
        seniors = (select coalesce(jsonb_agg(case when e ->> 'id' = $2 then $3 else e end order by ord), '[]'::jsonb)
                     from jsonb_array_elements(coalesce(s.seniors, '[]'::jsonb)) with ordinality t(e, ord)),
        juniors = (select coalesce(jsonb_agg(case when e ->> 'id' = $2 then $3 else e end order by ord), '[]'::jsonb)
                     from jsonb_array_elements(coalesce(s.juniors, '[]'::jsonb)) with ordinality t(e, ord))
       where s.gottesdienst_id = $1 $q$ using gid, old_id, newp;
  end if;
end $$;

-- Wenn jemand einen Dienst nicht mehr hat, erledigen sich alle offenen Angebote, Vorschläge und Vertretungs-Anfragen dazu
create or replace function public._tb_cleanup(gid text, pid text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.tauschboerse set status = 'zurueckgezogen', erledigt_am = now()
   where gottesdienst_id = gid and von_id = pid and status = 'offen';
  update public.tausch_vorschlaege set status = 'zurueckgezogen', beantwortet_am = now()
   where gottesdienst_id = gid and von_id = pid and status = 'offen';
  update public.vertretungen set status = 'vergeben'
   where gottesdienst_id = gid and von_id = pid and status = 'offen';
end $$;

revoke all on function public._tb_replace(text, text, jsonb), public._tb_cleanup(text, text) from public, anon, authenticated;

-- 3) Tauschbörse anzeigen ---------------------------------------------------
create or replace function public.tb_list(p_id text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; heute date := (now() at time zone 'Europe/Berlin')::date;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  return jsonb_build_object('ok', true,
    -- Angebote anderer, bei denen ich einspringen könnte
    'angebote', (select coalesce(jsonb_agg(x order by x ->> 'datum', x ->> 'zeit'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'id', o.id, 'gottesdienst_id', o.gottesdienst_id, 'modus', o.modus,
                 'von', public._sv_kurz(m.name), 'titel', g.title, 'datum', g.date::text, 'zeit', nullif(g.time::text, ''),
                 'optionen', case when o.modus <> 'tausch' then '[]'::jsonb else (
                    select coalesce(jsonb_agg(jsonb_build_object(
                             'gottesdienst_id', g2.id::text, 'titel', g2.title, 'datum', g2.date::text, 'zeit', nullif(g2.time::text, ''))
                             order by g2.date::date, g2.time), '[]'::jsonb)
                      from public.gottesdienste g2
                     where g2.date::date >= heute
                       and public._sv_slot(g2.id::text, p_id) is not null
                       and public._sv_eligible(g2.id::text, o.von_id, public._sv_slot(g2.id::text, p_id), g2.date::date)
                       and not exists (select 1 from public.tausch_vorschlaege v
                                        where v.angebot_id = o.id and v.von_id = p_id
                                          and v.gottesdienst_id = g2.id::text and v.status = 'offen')) end,
                 'vorgeschlagen', (select coalesce(jsonb_agg(v.gottesdienst_id), '[]'::jsonb) from public.tausch_vorschlaege v
                                    where v.angebot_id = o.id and v.von_id = p_id and v.status = 'offen')) as x
          from public.tauschboerse o
          join public.gottesdienste g on g.id::text = o.gottesdienst_id
          join public.messdiener m on m.id::text = o.von_id
         cross join lateral (select public._sv_slot(o.gottesdienst_id, o.von_id) as slot) s
         where o.status = 'offen' and o.von_id <> p_id and g.date::date >= heute and s.slot is not null
           and public._sv_eligible(o.gottesdienst_id, p_id, s.slot, g.date::date)) t),
    -- Meine eigenen offenen Angebote samt Tausch-Vorschlägen
    'meine', (select coalesce(jsonb_agg(x order by x ->> 'datum', x ->> 'zeit'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'id', o.id, 'gottesdienst_id', o.gottesdienst_id, 'modus', o.modus,
                 'titel', g.title, 'datum', g.date::text, 'zeit', nullif(g.time::text, ''),
                 'vorschlaege', (select coalesce(jsonb_agg(jsonb_build_object(
                                    'id', v.id, 'von', public._sv_kurz(mv.name), 'gottesdienst_id', v.gottesdienst_id,
                                    'titel', g3.title, 'datum', g3.date::text, 'zeit', nullif(g3.time::text, '')) order by v.created_at), '[]'::jsonb)
                                   from public.tausch_vorschlaege v
                                   join public.messdiener mv on mv.id::text = v.von_id
                                   join public.gottesdienste g3 on g3.id::text = v.gottesdienst_id
                                  where v.angebot_id = o.id and v.status = 'offen' and g3.date::date >= heute
                                    and public._sv_slot(v.gottesdienst_id, v.von_id) is not null)) as x
          from public.tauschboerse o
          join public.gottesdienste g on g.id::text = o.gottesdienst_id
         where o.von_id = p_id and o.status = 'offen' and g.date::date >= heute) t),
    -- Kürzlich erledigte Angebote von mir
    'erledigt', (select coalesce(jsonb_agg(x order by x ->> 'datum'), '[]'::jsonb) from (
        select jsonb_build_object('modus', o.modus, 'titel', g.title, 'datum', g.date::text, 'zeit', nullif(g.time::text, ''),
                                  'mit', public._sv_kurz(mu.name)) as x
          from public.tauschboerse o
          join public.gottesdienste g on g.id::text = o.gottesdienst_id
          join public.messdiener mu on mu.id::text = o.uebernommen_von
         where o.von_id = p_id and o.status in ('vergeben', 'getauscht') and g.date::date >= heute
           and o.erledigt_am > now() - interval '7 days') t),
    -- Meine Tausch-Vorschläge an andere
    'vorschlaege', (select coalesce(jsonb_agg(x order by x ->> 'datum'), '[]'::jsonb) from (
        select jsonb_build_object('id', v.id, 'status', v.status, 'von', public._sv_kurz(m.name),
                                  'titel', g.title, 'datum', g.date::text, 'zeit', nullif(g.time::text, ''),
                                  'dafuer_titel', g2.title, 'dafuer_datum', g2.date::text, 'dafuer_zeit', nullif(g2.time::text, '')) as x
          from public.tausch_vorschlaege v
          join public.tauschboerse o on o.id = v.angebot_id
          join public.messdiener m on m.id::text = o.von_id
          join public.gottesdienste g on g.id::text = o.gottesdienst_id
          join public.gottesdienste g2 on g2.id::text = v.gottesdienst_id
         where v.von_id = p_id and g.date::date >= heute and g2.date::date >= heute
           and (v.status = 'offen' and o.status = 'offen'
                or v.status in ('angenommen', 'abgelehnt') and v.beantwortet_am > now() - interval '3 days')) t));
end $$;

-- 4) Dienst einstellen / zurückziehen ----------------------------------------
create or replace function public.tb_offer(p_id text, p_pin text, p_gid text, p_modus text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; d date;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  if p_modus not in ('abgeben', 'tausch') then return jsonb_build_object('ok', false, 'error', 'format'); end if;
  d := public._sv_datum(p_gid);
  if d is null or public._sv_slot(p_gid, p_id) is null then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if (select count(*) from public.tauschboerse where von_id = p_id and status = 'offen') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'limit');
  end if;
  insert into public.tauschboerse (gottesdienst_id, von_id, modus) values (p_gid, p_id, p_modus)
  on conflict (gottesdienst_id, von_id) where status = 'offen' do update set modus = excluded.modus;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.tb_withdraw(p_id text, p_pin text, p_offer bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  update public.tauschboerse set status = 'zurueckgezogen', erledigt_am = now()
   where id = p_offer and von_id = p_id and status = 'offen';
  update public.tausch_vorschlaege set status = 'zurueckgezogen', beantwortet_am = now()
   where angebot_id = p_offer and status = 'offen';
  return jsonb_build_object('ok', true);
end $$;

-- 5) Abgeben: Dienst übernehmen --------------------------------------------------
create or replace function public.tb_take(p_id text, p_pin text, p_offer bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; o public.tauschboerse; d date; slot text; newp jsonb;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  select * into o from public.tauschboerse where id = p_offer for update;
  if not found or o.status <> 'offen' or o.modus <> 'abgeben' or o.von_id = p_id then
    return jsonb_build_object('ok', false, 'error', 'gone');
  end if;
  d := public._sv_datum(o.gottesdienst_id);
  slot := public._sv_slot(o.gottesdienst_id, o.von_id);
  if d is null or slot is null then
    update public.tauschboerse set status = 'zurueckgezogen', erledigt_am = now() where id = o.id;
    return jsonb_build_object('ok', false, 'error', 'gone');
  end if;
  if public._sv_slot(o.gottesdienst_id, p_id) is not null then return jsonb_build_object('ok', false, 'error', 'already'); end if;
  if public._sv_absent(p_id, d) then return jsonb_build_object('ok', false, 'error', 'absent'); end if;
  if not public._sv_eligible(o.gottesdienst_id, p_id, slot, d) then return jsonb_build_object('ok', false, 'error', 'gone'); end if;

  select to_jsonb(m) into newp from public.messdiener m where m.id::text = p_id;
  perform public._tb_replace(o.gottesdienst_id, o.von_id, newp);
  perform public._tb_cleanup(o.gottesdienst_id, o.von_id);
  update public.tauschboerse set status = 'vergeben', uebernommen_von = p_id, erledigt_am = now() where id = o.id;
  return jsonb_build_object('ok', true);
end $$;

-- 6) Tauschen: Vorschlag machen, zurückziehen, annehmen / ablehnen -------------------------
create or replace function public.tb_propose(p_id text, p_pin text, p_offer bigint, p_gid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; o public.tauschboerse; dA date; dB date; slotA text; slotB text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  select * into o from public.tauschboerse where id = p_offer;
  if not found or o.status <> 'offen' or o.modus <> 'tausch' or o.von_id = p_id then
    return jsonb_build_object('ok', false, 'error', 'gone');
  end if;
  dA := public._sv_datum(o.gottesdienst_id); slotA := public._sv_slot(o.gottesdienst_id, o.von_id);
  dB := public._sv_datum(p_gid);             slotB := public._sv_slot(p_gid, p_id);
  if dA is null or slotA is null then return jsonb_build_object('ok', false, 'error', 'gone'); end if;
  if dB is null or slotB is null then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if public._sv_slot(o.gottesdienst_id, p_id) is not null then return jsonb_build_object('ok', false, 'error', 'already'); end if;
  if public._sv_absent(p_id, dA) then return jsonb_build_object('ok', false, 'error', 'absent'); end if;
  if not public._sv_eligible(o.gottesdienst_id, p_id, slotA, dA)
     or not public._sv_eligible(p_gid, o.von_id, slotB, dB) then
    return jsonb_build_object('ok', false, 'error', 'nomatch');
  end if;
  insert into public.tausch_vorschlaege (angebot_id, von_id, gottesdienst_id) values (o.id, p_id, p_gid)
  on conflict (angebot_id, von_id, gottesdienst_id) do update
    set status = 'offen', created_at = now(), beantwortet_am = null
    where public.tausch_vorschlaege.status in ('abgelehnt', 'zurueckgezogen');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.tb_unpropose(p_id text, p_pin text, p_vorschlag bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  update public.tausch_vorschlaege set status = 'zurueckgezogen', beantwortet_am = now()
   where id = p_vorschlag and von_id = p_id and status = 'offen';
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.tb_decide(p_id text, p_pin text, p_vorschlag bigint, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare chk text; v public.tausch_vorschlaege; o public.tauschboerse;
        dA date; dB date; slotA text; slotB text; pj jsonb; tj jsonb;
begin
  chk := public._mini_pin_check(p_id, p_pin);
  if chk <> 'ok' then return jsonb_build_object('ok', false, 'error', chk); end if;
  select * into v from public.tausch_vorschlaege where id = p_vorschlag for update;
  if not found or v.status <> 'offen' then return jsonb_build_object('ok', false, 'error', 'gone'); end if;
  select * into o from public.tauschboerse where id = v.angebot_id for update;
  if not found or o.von_id <> p_id or o.status <> 'offen' then return jsonb_build_object('ok', false, 'error', 'gone'); end if;

  if not p_accept then
    update public.tausch_vorschlaege set status = 'abgelehnt', beantwortet_am = now() where id = v.id;
    return jsonb_build_object('ok', true, 'status', 'abgelehnt');
  end if;

  -- Alles noch einmal prüfen: p_id steht in Dienst A, v.von_id in Dienst B
  dA := public._sv_datum(o.gottesdienst_id); slotA := public._sv_slot(o.gottesdienst_id, p_id);
  dB := public._sv_datum(v.gottesdienst_id); slotB := public._sv_slot(v.gottesdienst_id, v.von_id);
  if dA is null or slotA is null or dB is null or slotB is null
     or not public._sv_eligible(o.gottesdienst_id, v.von_id, slotA, dA)
     or not public._sv_eligible(v.gottesdienst_id, p_id, slotB, dB) then
    update public.tausch_vorschlaege set status = 'abgelehnt', beantwortet_am = now() where id = v.id;
    return jsonb_build_object('ok', false, 'error', 'gone');
  end if;

  select to_jsonb(m) into pj from public.messdiener m where m.id::text = p_id;
  select to_jsonb(m) into tj from public.messdiener m where m.id::text = v.von_id;
  perform public._tb_replace(o.gottesdienst_id, p_id, tj);       -- Dienst A: Anbieter -> Vorschlagender
  perform public._tb_replace(v.gottesdienst_id, v.von_id, pj);   -- Dienst B: Vorschlagender -> Anbieter
  perform public._tb_cleanup(o.gottesdienst_id, p_id);
  perform public._tb_cleanup(v.gottesdienst_id, v.von_id);
  update public.tausch_vorschlaege set status = 'abgelehnt', beantwortet_am = now()
   where angebot_id = o.id and id <> v.id and status = 'offen';
  update public.tausch_vorschlaege set status = 'angenommen', beantwortet_am = now() where id = v.id;
  update public.tauschboerse set status = 'getauscht', uebernommen_von = v.von_id, erledigt_am = now() where id = o.id;
  return jsonb_build_object('ok', true, 'status', 'angenommen');
end $$;

-- 7) Rechte ---------------------------------------------------------------------------
revoke all on function public.tb_list(text, text), public.tb_offer(text, text, text, text),
  public.tb_withdraw(text, text, bigint), public.tb_take(text, text, bigint),
  public.tb_propose(text, text, bigint, text), public.tb_unpropose(text, text, bigint),
  public.tb_decide(text, text, bigint, boolean) from public;
grant execute on function public.tb_list(text, text), public.tb_offer(text, text, text, text),
  public.tb_withdraw(text, text, bigint), public.tb_take(text, text, bigint),
  public.tb_propose(text, text, bigint, text), public.tb_unpropose(text, text, bigint),
  public.tb_decide(text, text, bigint, boolean) to anon, authenticated;

-- 8) Supabase soll die neuen Funktionen sofort kennen (Schema-Cache neu laden)
notify pgrst, 'reload schema';
