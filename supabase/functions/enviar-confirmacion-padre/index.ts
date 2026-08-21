// ============================================================================
// 📧 enviar-confirmacion-padre  ·  Supabase Edge Function (Deno)
// Confirma por email al padre/madre que su acceso al perfil del jugador quedó
// aprobado (flujo de autoservicio de jugador.html).
//
// DESPLIEGUE (una sola vez, igual que enviar-aviso-programacion):
//   Panel de Supabase → Edge Functions → New function →
//   nombre: enviar-confirmacion-padre → pegar este código → Deploy.
//   Usa el mismo secreto RESEND_API_KEY ya configurado.
//
// La autorización la impone la base: la RPC datos_confirmacion_padre solo
// responde si el usuario del token realmente tiene el acceso al jugador.
// ============================================================================

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const esc = (t: unknown) => String(t ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const RESEND = Deno.env.get('RESEND_API_KEY');
    if (!RESEND) return json({ error: 'Falta el secreto RESEND_API_KEY en el proyecto' }, 500);
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const auth = req.headers.get('Authorization') || '';
    if (!auth) return json({ error: 'Falta la sesión del padre/madre' }, 401);

    const { jugador_id } = await req.json();
    if (!jugador_id) return json({ error: 'Falta jugador_id' }, 400);

    // La RPC corre con el token del usuario: solo responde si el acceso existe.
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/datos_confirmacion_padre`, {
      method: 'POST',
      headers: {
        apikey: ANON, Authorization: auth, 'Content-Type': 'application/json',
        'Accept-Profile': 'competencias', 'Content-Profile': 'competencias',
      },
      body: JSON.stringify({ p_jugador: jugador_id }),
    });
    const txt = await r.text();
    let d: any = null; try { d = txt ? JSON.parse(txt) : null; } catch { d = null; }
    if (!r.ok || !d || !d.email) return json({ error: 'Acceso no encontrado para este usuario' }, 403);

    const link = `https://www.liguify.com/jugador/${d.token}`;
    const html = `
      <div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#171e2e">
        <div style="background:#171e2e;color:#fff;border-radius:14px;padding:22px 26px;margin-bottom:18px">
          <p style="margin:0;font-size:11px;letter-spacing:3px;color:#fbbf24;font-weight:bold">LIGUIFY · PERFIL DE JUGADOR</p>
          <h1 style="margin:6px 0 0;font-size:22px">✅ Acceso confirmado</h1>
        </div>
        <p>Hola${d.padre ? ' <b>' + esc(d.padre) + '</b>' : ''},</p>
        <p>Tu registro como <b>padre/madre</b> quedó aprobado. Ya puedes ver y administrar el perfil de <b>${esc(d.jugador)}</b>: su información, estadísticas oficiales, fotos, videos y redes sociales.</p>
        <p style="margin:22px 0">
          <a href="${link}" style="background:#d9232e;color:#fff;text-decoration:none;font-weight:bold;padding:12px 22px;border-radius:10px;display:inline-block">ABRIR EL PERFIL</a>
        </p>
        <p style="font-size:12px;color:#5b6478">Entra siempre con este mismo correo (${esc(d.email)}). Si tú no realizaste este registro, responde a este email.</p>
        <p style="font-size:11px;color:#8b93a7;border-top:1px solid #e9e6e0;padding-top:10px">⚡ Powered by Liguify · liguify.com</p>
      </div>`;

    const rs = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'Liguify <notificaciones@liguify.com>',
        to: [d.email],
        subject: `✅ Acceso confirmado — perfil de ${d.jugador}`,
        html,
      }),
    });
    const rsBody = await rs.json().catch(() => null);
    if (!rs.ok) return json({ error: 'Resend: ' + (rsBody?.message || rs.status) }, 502);
    return json({ ok: true, id: rsBody?.id || null });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
