-- =====================================================================
-- Anmelde-Links für einzelne Gottesdienste (z. B. Beerdigung, Hochzeit):
-- Minis mit Zeit tragen sich selbst über einen Link ein (anmeldung.html, mit PIN).
-- Voraussetzung: abwesenheiten.sql wurde schon ausgeführt (PIN-Prüfung).
-- Im Supabase SQL-Editor einmal komplett ausführen. Mehrfaches Ausführen ist unkritisch.
-- =====================================================================

alter table public.gottesdienste add column if not exists anmeldung_token text;
create unique index if not exists gottesdienste_anmeldung_token_idx on public.gottesdienste (anmeldung_token) where anmeldung_token is not null;

create table if not exists public.anmeldungen (
  gottesdienst_id text not null,
  messdiener_id text not null,
  created_at timestamptz not null default now(),
  primary key (gottesdienst_id, messdiener_id)
);
alter table public.anmeldungen enable row level security;
drop policy if exists "leiter alles" on public.anmeldungen;
create policy "leiter alles" on public.anmeldungen for all to authenticated using (true) with check (true);
revoke all on public.anmeldungen from anon;
grant select, insert, update, delete on public.anmeldungen to authenticated;

-- Infos zum Gottesdienst für die Anmelde-Seite (ohne PIN, nur mit gültigem Link)
create or replace function public.signup_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare g record;
begin
  if p_token is null or length(p_token) < 16 then return jsonb_build_object('ok', false, 'error', 'notfound'); end if;
  select id::text as id, title, date::text as datum, nullif(time::text, '') as zeit, seniors, juniors
    into g from public.gottesdienste where anmeldung_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'notfound'); end if;
  return jsonb_build_object('ok', true, 'titel', g.title, 'datum', g.datum, 'zeit', g.zeit,
                            'closed', g.datum::date < current_date);
end;
$$;

-- Eigener Stand (angemeldet ja/nein)
create or replace function public.signup_get(p_token text, p_id text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text; gid text;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  select id::text into gid from public.gottesdienste where anmeldung_token = p_token;
  if gid is null then return jsonb_build_object('ok', false, 'error', 'notfound'); end if;
  return jsonb_build_object('ok', true,
    'angemeldet', exists (select 1 from public.anmeldungen where gottesdienst_id = gid and messdiener_id = p_id));
end;
$$;

-- Eintragen (p_join = true) oder wieder austragen (false)
create or replace function public.signup_set(p_token text, p_id text, p_pin text, p_join boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare status text; gid text; gdate date;
begin
  status := public._mini_pin_check(p_id, p_pin);
  if status <> 'ok' then return jsonb_build_object('ok', false, 'error', status); end if;
  select id::text, date::date into gid, gdate from public.gottesdienste where anmeldung_token = p_token;
  if gid is null then return jsonb_build_object('ok', false, 'error', 'notfound'); end if;
  if gdate < current_date then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if p_join then
    insert into public.anmeldungen (gottesdienst_id, messdiener_id) values (gid, p_id) on conflict do nothing;
  else
    delete from public.anmeldungen where gottesdienst_id = gid and messdiener_id = p_id;
  end if;
  return public.signup_get(p_token, p_id, p_pin);
end;
$$;

revoke all on function public.signup_info(text) from public;
revoke all on function public.signup_get(text, text, text) from public;
revoke all on function public.signup_set(text, text, text, boolean) from public;
grant execute on function public.signup_info(text) to anon, authenticated;
grant execute on function public.signup_get(text, text, text) to anon, authenticated;
grant execute on function public.signup_set(text, text, text, boolean) to anon, authenticated;
