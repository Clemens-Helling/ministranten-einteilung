// Edge Function "benutzer": Leiter-Zugänge in der App verwalten (nur Admins).
// Voraussetzung: rollen.sql wurde ausgeführt und du bist dort als Admin eingetragen.
// Bereitstellen: supabase functions deploy benutzer
// Oder im Dashboard unter Edge Functions eine neue Funktion anlegen und diesen Code einfügen
// ("Verify JWT" bleibt AN). Trage in index.html bei USERS_FUNCTION den Namen aus der URL-Spalte ein.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const ROLLEN = ["admin", "leiter"];
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Nur POST" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Wer fragt an?
  const caller = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: who } = await caller.auth.getUser();
  const me = who?.user;
  if (!me?.email) return json({ ok: false, error: "Nicht angemeldet." }, 401);

  const admin = createClient(url, service, { auth: { persistSession: false } });
  const { data: myRole } = await admin.from("rollen").select("rolle").ilike("email", me.email).maybeSingle();
  if (myRole?.rolle !== "admin") return json({ ok: false, error: "Nur Admins dürfen Zugänge verwalten." }, 403);

  let body: Record<string, string> = {};
  try { body = await req.json(); } catch (_) { /* leer */ }

  const adminCount = async () => (await admin.from("rollen").select("email", { count: "exact", head: true }).eq("rolle", "admin")).count ?? 0;

  switch (body.action) {
    case "list": {
      const { data, error } = await admin.auth.admin.listUsers({ page: 1, perPage: 200 });
      if (error) return json({ ok: false, error: error.message }, 500);
      const { data: rollen } = await admin.from("rollen").select("email, rolle");
      const map = new Map((rollen ?? []).map((r: { email: string; rolle: string }) => [r.email.toLowerCase(), r.rolle]));
      const users = data.users.map((u) => ({
        id: u.id, email: u.email, created_at: u.created_at, last_sign_in_at: u.last_sign_in_at,
        rolle: map.get((u.email ?? "").toLowerCase()) ?? "leiter", self: u.id === me.id,
      })).sort((a, b) => (a.email ?? "").localeCompare(b.email ?? ""));
      return json({ ok: true, users });
    }

    case "create": {
      const email = (body.email ?? "").trim().toLowerCase();
      const rolle = body.rolle ?? "leiter";
      if (!EMAIL.test(email)) return json({ ok: false, error: "Bitte eine gültige E-Mail-Adresse angeben." });
      if ((body.password ?? "").length < 8) return json({ ok: false, error: "Das Passwort braucht mindestens 8 Zeichen." });
      if (!ROLLEN.includes(rolle)) return json({ ok: false, error: "Unbekannte Rolle." });
      const { error } = await admin.auth.admin.createUser({ email, password: body.password, email_confirm: true });
      if (error) return json({ ok: false, error: /already|registered/i.test(error.message) ? "Diese E-Mail-Adresse hat schon einen Zugang." : error.message });
      await admin.from("rollen").upsert({ email, rolle });
      return json({ ok: true });
    }

    case "set_role": {
      const email = (body.email ?? "").trim().toLowerCase();
      if (!ROLLEN.includes(body.rolle)) return json({ ok: false, error: "Unbekannte Rolle." });
      if (email === me.email.toLowerCase() && body.rolle !== "admin" && (await adminCount()) <= 1)
        return json({ ok: false, error: "Es muss mindestens ein Admin bleiben." });
      await admin.from("rollen").upsert({ email, rolle: body.rolle });
      return json({ ok: true });
    }

    case "reset_password": {
      if ((body.password ?? "").length < 8) return json({ ok: false, error: "Das Passwort braucht mindestens 8 Zeichen." });
      const { error } = await admin.auth.admin.updateUserById(body.id, { password: body.password });
      return error ? json({ ok: false, error: error.message }) : json({ ok: true });
    }

    case "delete": {
      if (body.id === me.id) return json({ ok: false, error: "Du kannst dich nicht selbst löschen." });
      const { data: u } = await admin.auth.admin.getUserById(body.id);
      const { error } = await admin.auth.admin.deleteUser(body.id);
      if (error) return json({ ok: false, error: error.message });
      if (u?.user?.email) await admin.from("rollen").delete().ilike("email", u.user.email);
      return json({ ok: true });
    }

    default:
      return json({ ok: false, error: "Unbekannte Aktion." }, 400);
  }
});
