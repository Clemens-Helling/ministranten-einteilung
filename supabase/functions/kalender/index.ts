// Edge Function "kalender": liefert den persönlichen Kalender (ICS) für ein Abo.
// Bereitstellen (einmalig): supabase functions deploy kalender --no-verify-jwt
// Oder im Supabase-Dashboard unter Edge Functions eine neue Funktion "kalender" anlegen,
// diesen Code einfügen und "Verify JWT" ausschalten (Kalender-Apps senden keine Anmeldung).
Deno.serve(async (req: Request) => {
  const token = new URL(req.url).searchParams.get("token") ?? "";
  if (!/^[a-f0-9]{64}$/.test(token)) return new Response("Nicht gefunden", { status: 404 });

  const base = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_ANON_KEY")!;
  const res = await fetch(`${base}/rest/v1/rpc/calendar_feed`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: token }),
  });
  const ics = res.ok ? await res.json() : null;
  if (typeof ics !== "string") return new Response("Nicht gefunden", { status: 404 });

  return new Response(ics, {
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": 'inline; filename="messdienst.ics"',
      "Cache-Control": "private, max-age=900",
    },
  });
});
