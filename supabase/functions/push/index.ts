// Supabase Edge Function "push": verschickt Web-Push-Nachrichten für Vertretungsanfragen.
// Einstellungen: Verify JWT = OFF (die Mini-Seite weist sich mit Name + PIN aus, nicht mit einem Login).
// Secrets (Dashboard > Edge Functions > Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (z. B. mailto:du@example.de)
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const WD = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];
function wann(datum: string, zeit?: string | null) {
  const [y, m, d] = datum.split("-").map(Number);
  const wd = WD[new Date(y, m - 1, d).getDay()];
  return `${wd}, ${String(d).padStart(2, "0")}.${String(m).padStart(2, "0")}.` + (zeit ? ` ${zeit.slice(0, 5)} Uhr` : "");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { id, pin, gid } = await req.json();
    if (!id || !pin || !gid) return json({ error: "Angaben fehlen" }, 400);

    const url = Deno.env.get("SUPABASE_URL")!;
    // Ausweis per PIN: die Datenbank-Funktion prüft Name + PIN und liefert nur, was dieses Mini verschicken darf
    const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false } });
    const { data, error } = await anon.rpc("sub_notify_info", { p_id: String(id), p_pin: String(pin), p_gid: String(gid) });
    if (error || !data?.ok) return json({ error: data?.error || error?.message || "Nicht erlaubt" }, 403);

    const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY");
    if (!pub || !priv) return json({ error: "VAPID-Schlüssel fehlen" }, 500);
    webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:admin@example.com", pub, priv);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    let gesendet = 0;
    for (const e of data.eintraege as any[]) {
      const anfrage = e.art === "anfrage";
      const target = anfrage ? e.an_id : e.von_id;
      const w = wann(e.datum, e.zeit);
      const msg = anfrage
        ? { title: "Vertretung gesucht", body: `${e.von} sucht eine Vertretung: ${w} · ${e.titel}`, tag: `anfrage-${e.id}` }
        : e.status === "angenommen"
          ? { title: "Vertretung gefunden", body: `${e.an} übernimmt deinen Dienst: ${w}`, tag: `antwort-${e.id}` }
          : { title: "Vertretung abgelehnt", body: `${e.an} kann leider nicht: ${w}`, tag: `antwort-${e.id}` };
      const payload = JSON.stringify({ ...msg, url: "mini.html#anfragen" });

      const { data: abos } = await admin.from("push_abos").select("endpoint,p256dh,auth").eq("messdiener_id", target);
      for (const a of abos || []) {
        try {
          await webpush.sendNotification({ endpoint: a.endpoint, keys: { p256dh: a.p256dh, auth: a.auth } }, payload, { TTL: 86400 });
          gesendet++;
        } catch (err: any) {
          if (err?.statusCode === 404 || err?.statusCode === 410) await admin.from("push_abos").delete().eq("endpoint", a.endpoint);
        }
      }
      // Als erledigt markieren, auch wenn niemand ein Gerät angemeldet hat (in der App sieht man die Anfrage trotzdem)
      await admin.from("vertretungen").update(anfrage ? { gepusht: true } : { antwort_gepusht: true }).eq("id", e.id);
    }
    return json({ ok: true, gesendet });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
