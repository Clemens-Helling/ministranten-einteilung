// Supabase Edge Function "sync-gottesdienste"
// Liest die Gottesdienste (Gurtweil) von kath-anderwutach.de und legt neue Termine an.
// Es wird nur ein Monat im Voraus geladen (HORIZON_DAYS).
// Einstellungen: Verify JWT = ON (wird aus der App mit dem Login des Leiters aufgerufen).
import { createClient } from "npm:@supabase/supabase-js@2";

const HORIZON_DAYS = 31;
const MAX_PAGES = 6;
const BASE =
  "https://kath-anderwutach.de/gottesdienste-mehr/gottesdienste/gottesdienste-sued-west/" +
  "?plz_f1092ea5=&umkreis_f1092ea5=10&oertlichkeit_multiple_v2_f1092ea5%5B%5D=51647&btn-submit_f1092ea5=1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const decode = (s: string) =>
  s.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#0?39;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n));

type Termin = { key: string; date: string; time: string; title: string };

// Zerlegt die Seite in Textzeilen; ein Termin beginnt mit "Mo. 02.11.2026, 19:00",
// die nächste nicht-leere Zeile ist der Titel.
function parse(html: string): Termin[] {
  const body = html.replace(/<(script|style)[\s\S]*?<\/\1>/gi, "");
  const ids = [...body.matchAll(/detail\/termin\/id\/(\d+)/g)].map((m) => m[1]);
  const lines = decode(body.replace(/<\/?(?:br|p|div|li|h\d|a|strong|b|span)\b[^>]*>/gi, "\n").replace(/<[^>]+>/g, " "))
    .split("\n").map((l) => l.replace(/\s+/g, " ").trim()).filter(Boolean);
  const re = /^(?:Mo|Di|Mi|Do|Fr|Sa|So)\.?,?\s*(\d{2})\.(\d{2})\.(\d{4}),?\s*(\d{1,2}):(\d{2})/;
  const out: Termin[] = [];
  let n = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(re);
    if (!m) continue;
    let title = (lines[i + 1] || "").replace(/^\+\s*/, "").trim();
    if (!title || re.test(title)) title = "Gottesdienst";
    const date = `${m[3]}-${m[2]}-${m[1]}`;
    const time = `${m[4].padStart(2, "0")}:${m[5]}`;
    out.push({ key: ids[n] ? `kaw-${ids[n]}` : `kaw-${date}-${time}`, date, time, title });
    n++;
  }
  return out;
}

const iso = (d: Date) => d.toISOString().slice(0, 10);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: u } = await admin.auth.getUser(token);
    if (!u?.user) return json({ error: "Nicht angemeldet" }, 401);

    const today = new Date();
    const from = iso(today);
    const to = iso(new Date(today.getTime() + HORIZON_DAYS * 86400000));

    const found: Termin[] = [];
    for (let page = 1; page <= MAX_PAGES; page++) {
      const r = await fetch(BASE + (page > 1 ? `&pagerPage_f1092ea5=${page}` : ""), {
        headers: { "User-Agent": "Mozilla/5.0 (Ministranten-Einteilung)", "Accept-Language": "de" },
      });
      if (!r.ok) return json({ error: `Seite nicht erreichbar (${r.status})` }, 502);
      const list = parse(await r.text());
      if (!list.length) break;
      found.push(...list);
      if (list.some((t) => t.date > to)) break; // chronologisch: weiter hinten nur noch spätere
    }

    const wanted = found.filter((t) => t.date >= from && t.date <= to);
    const { data: existing, error: e1 } = await admin.from("gottesdienste").select("id,date,time").gte("date", from).lte("date", to);
    if (e1) return json({ error: e1.message }, 500);
    const have = new Set((existing || []).map((g: any) => `${g.date}|${String(g.time).slice(0, 5)}`));
    const ids = new Set((existing || []).map((g: any) => g.id));

    const rows = [];
    for (const t of wanted) {
      const k = `${t.date}|${t.time}`;
      if (have.has(k) || ids.has(t.key)) continue;
      have.add(k);
      const sunday = new Date(t.date + "T12:00:00Z").getUTCDay() === 0;
      rows.push({ id: t.key, title: t.title, date: t.date, time: t.time, seniors: 1, juniors: sunday ? 4 : 2 });
    }
    if (rows.length) {
      const { error } = await admin.from("gottesdienste").insert(rows);
      if (error) return json({ error: error.message }, 500);
    }
    return json({ ok: true, gefunden: wanted.length, neu: rows.length, von: from, bis: to });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
