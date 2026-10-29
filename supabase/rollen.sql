-- Rollen für die Leiter-Anmeldung: 'admin' (darf Messdiener verwalten) und 'leiter' (nur Einteilung).
-- Im Supabase SQL-Editor ausführen. Das Skript kann mehrfach laufen.
-- Wer nicht in der Tabelle steht, ist Leiter.

create table if not exists public.rollen (
  email text primary key,
  rolle text not null check (rolle in ('admin', 'leiter'))
);
alter table public.rollen enable row level security;
revoke all on public.rollen from anon, authenticated;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select rolle from public.rollen where lower(email) = lower(auth.jwt() ->> 'email')),
    'leiter');
$$;
revoke all on function public.my_role() from public, anon;
grant execute on function public.my_role() to authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_role() = 'admin';
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Schreibzugriff auf die Messdiener-Verwaltung nur für Admins.
-- "restrictive" gilt zusätzlich zu allen bestehenden Policies.
do $$
declare t text; c text;
begin
  foreach t in array array['messdiener', 'mini_pins'] loop
    if to_regclass('public.' || t) is not null then
      foreach c in array array['insert', 'update', 'delete'] loop
        execute format('drop policy if exists %I on public.%I', 'nur_admin_' || c, t);
        execute format('create policy %I on public.%I as restrictive for %s to authenticated %s',
          'nur_admin_' || c, t, c,
          case c when 'insert' then 'with check (public.is_admin())'
                 when 'update' then 'using (public.is_admin()) with check (public.is_admin())'
                 else 'using (public.is_admin())' end);
      end loop;
    end if;
  end loop;
end $$;

-- Mini-PINs sind nur für Admins lesbar.
drop policy if exists nur_admin_select on public.mini_pins;
create policy nur_admin_select on public.mini_pins as restrictive for select to authenticated using (public.is_admin());

-- Admins eintragen (E-Mail-Adresse wie bei der Anmeldung):
-- insert into public.rollen (email, rolle) values ('deine@mail.de', 'admin')
--   on conflict (email) do update set rolle = excluded.rolle;
