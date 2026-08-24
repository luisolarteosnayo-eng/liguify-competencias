// ============================================================================
// 📲 enviar-sms-padre  ·  Supabase Edge Function (Deno)  · v1
// Envía por SMS (Twilio) el código de verificación del celular del padre/madre
// en el registro del perfil de jugador (seguridad nivel 2).
//
// Flujo: valida la sesión del usuario → crea el código vía RPC
// crear_codigo_sms (SOLO service_role: aplica límites y el código en claro
// nunca llega al navegador) → envía el SMS por Twilio.
//
// DESPLIEGUE: Panel → Edge Functions → New function → "enviar-sms-padre" →
// pegar este código → Deploy.
// SECRETOS (Edge Functions → Secrets — NUNCA pegar las claves en otro lado):
//   TWILIO_ACCOUNT_SID  → Account SID de la consola de Twilio
//   TWILIO_AUTH_TOKEN   → Auth Token de la consola de Twilio
//   TWILIO_FROM         → número Twilio en E.164 (ej. +12025550123) o un
//                         Messaging Service SID (empieza con MG...)
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY los inyecta
// Supabase automáticamente.
// ============================================================================

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const SID = Deno.env.get('TWILIO_ACCOUNT_SID');
    const TOK = Deno.env.get('TWILIO_AUTH_TOKEN');
    const FROM = Deno.env.get('TWILIO_FROM');
    if (!SID || !TOK || !FROM) return json({ error: 'Faltan los secretos TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN / TWILIO_FROM' }, 500);
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth = req.headers.get('Authorization') || '';
    if (!auth) return json({ error: 'Falta la sesión' }, 401);

    const { telefono } = await req.json();
    if (!telefono) return json({ error: 'Falta el teléfono' }, 400);

    // 1) ¿Quién llama? (valida el JWT del usuario contra Auth)
    const uRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON, Authorization: auth } });
    const user = uRes.ok ? await uRes.json() : null;
    if (!user || !user.id) return json({ error: 'Sesión inválida: vuelve a iniciar sesión' }, 401);

    // 2) Crear el código (service_role; aplica límites de envío)
    const cRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/crear_codigo_sms`, {
      method: 'POST',
      headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json',
                 'Accept-Profile': 'competencias', 'Content-Profile': 'competencias' },
      body: JSON.stringify({ p_usuario: user.id, p_telefono: telefono }),
    });
    const cTxt = await cRes.text();
    let c: any = null; try { c = cTxt ? JSON.parse(cTxt) : null; } catch { c = null; }
    if (!cRes.ok) return json({ error: 'No se pudo generar el código', detalle: cTxt.slice(0, 200) }, 500);
    if (!c || !c.ok) return json({ ok: false, msg: (c && c.msg) || 'No se pudo generar el código' });

    // 3) Enviar el SMS por Twilio (el código no sale de esta función)
    const params = new URLSearchParams({
      To: c.telefono,
      Body: `Liguify: tu codigo de verificacion es ${c.codigo}. Vence en 10 minutos. No lo compartas.`,
    });
    if (FROM.startsWith('MG')) params.set('MessagingServiceSid', FROM); else params.set('From', FROM);
    const tw = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${SID}/Messages.json`, {
      method: 'POST',
      headers: { Authorization: 'Basic ' + btoa(`${SID}:${TOK}`), 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
    });
    const twBody: any = await tw.json().catch(() => null);
    if (!tw.ok) {
      const msg = twBody && twBody.message ? String(twBody.message) : 'Twilio rechazó el envío';
      return json({ ok: false, msg: 'No se pudo enviar el SMS: ' + msg });
    }
    return json({ ok: true, telefono: c.telefono });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
