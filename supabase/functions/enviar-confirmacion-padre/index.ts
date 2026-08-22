// ============================================================================
// 📧 enviar-confirmacion-padre  ·  Supabase Edge Function (Deno)  · v2
// Tras un registro de padre/madre en el perfil del jugador:
//   1) Confirma al padre por email: ACCESO APROBADO o SOLICITUD PENDIENTE
//      (si ya había un padre registrado).
//   2) AVISA al organizador (admins de la marca) y al padre ya registrado:
//      quién se registró, teléfono, email y enlace al perfil/reporte.
//
// DESPLIEGUE: Panel → Edge Functions → enviar-confirmacion-padre → reemplazar
// el código por este → Deploy. Usa RESEND_API_KEY (secreto ya configurado) y
// SUPABASE_SERVICE_ROLE_KEY (la inyecta Supabase automáticamente).
//
// Seguridad: primero valida con el TOKEN DEL USUARIO que quien llama sea el
// padre registrado de ese jugador (datos_confirmacion_padre); solo entonces
// usa la clave de servicio para obtener los destinatarios (aviso_nuevo_padre,
// concedida únicamente a service_role). Nunca devuelve emails al navegador.
// ============================================================================

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const esc = (t: unknown) => String(t ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const marco = (titulo: string, cuerpo: string) => `
  <div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#171e2e">
    <div style="background:#171e2e;color:#fff;border-radius:14px;padding:22px 26px;margin-bottom:18px">
      <p style="margin:0;font-size:11px;letter-spacing:3px;color:#fbbf24;font-weight:bold">LIGUIFY · PERFIL DE JUGADOR</p>
      <h1 style="margin:6px 0 0;font-size:22px">${titulo}</h1>
    </div>
    ${cuerpo}
    <p style="font-size:11px;color:#8b93a7;border-top:1px solid #e9e6e0;padding-top:10px;margin-top:18px">⚡ Powered by Liguify · liguify.com</p>
  </div>`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const RESEND = Deno.env.get('RESEND_API_KEY');
    if (!RESEND) return json({ error: 'Falta el secreto RESEND_API_KEY en el proyecto' }, 500);
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth = req.headers.get('Authorization') || '';
    if (!auth) return json({ error: 'Falta la sesión del padre/madre' }, 401);

    const { jugador_id } = await req.json();
    if (!jugador_id) return json({ error: 'Falta jugador_id' }, 400);

    const rpc = async (fn: string, body: unknown, key: string, bearer: string) => {
      const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: { apikey: key, Authorization: bearer, 'Content-Type': 'application/json',
                   'Accept-Profile': 'competencias', 'Content-Profile': 'competencias' },
        body: JSON.stringify(body),
      });
      const txt = await r.text();
      let d: any = null; try { d = txt ? JSON.parse(txt) : null; } catch { d = null; }
      if (!r.ok) throw new Error(d?.message || `Error ${r.status} en ${fn}`);
      return d;
    };

    // 1) ¿Quién llama es realmente el padre registrado de este jugador? (token del usuario)
    const d = await rpc('datos_confirmacion_padre', { p_jugador: jugador_id }, ANON, auth);
    if (!d || !d.email) return json({ error: 'Acceso no encontrado para este usuario' }, 403);

    // identidad del usuario (para pedir los destinatarios con service role)
    const me = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON, Authorization: auth } });
    const meJ = await me.json().catch(() => null);
    const uid = meJ?.id;
    if (!uid) return json({ error: 'Sesión inválida' }, 401);

    // 2) destinatarios de los avisos (solo service_role)
    let av: any = null;
    try { av = await rpc('aviso_nuevo_padre', { p_usuario: uid, p_jugador: jugador_id }, SERVICE, `Bearer ${SERVICE}`); } catch (_) { av = null; }

    const link = `https://www.liguify.com/jugador/${d.token}`;
    const pendiente = d.estado === 'pendiente';
    const enviar = async (to: string[], subject: string, html: string) => {
      if (!to.length) return null;
      const rs = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: 'Liguify <notificaciones@liguify.com>', to, subject, html }),
      });
      const b = await rs.json().catch(() => null);
      return rs.ok ? (b?.id || true) : ('ERR ' + (b?.message || rs.status));
    };

    // 3) email al padre
    const r1 = await enviar([d.email],
      pendiente ? `⏳ Solicitud recibida — perfil de ${d.jugador}` : `✅ Acceso confirmado — perfil de ${d.jugador}`,
      pendiente
        ? marco('⏳ Solicitud recibida', `
            <p>Hola${d.padre ? ' <b>' + esc(d.padre) + '</b>' : ''},</p>
            <p>Recibimos tu solicitud de acceso al perfil de <b>${esc(d.jugador)}</b>. Como este perfil ya tiene un padre/madre registrado, tu acceso queda <b>pendiente de aprobación</b> por esa persona o por el organizador.</p>
            <p>Te avisaremos por este correo cuando se apruebe. Mientras tanto puedes ver el perfil aquí:</p>
            <p style="margin:22px 0"><a href="${link}" style="background:#171e2e;color:#fff;text-decoration:none;font-weight:bold;padding:12px 22px;border-radius:10px;display:inline-block">VER EL PERFIL</a></p>
            <p style="font-size:12px;color:#5b6478">Si tú no realizaste esta solicitud, responde a este email.</p>`)
        : marco('✅ Acceso confirmado', `
            <p>Hola${d.padre ? ' <b>' + esc(d.padre) + '</b>' : ''},</p>
            <p>Tu registro como <b>padre/madre</b> quedó aprobado. Ya puedes ver y administrar el perfil de <b>${esc(d.jugador)}</b>: información, estadísticas oficiales, fotos, videos y redes sociales.</p>
            <p style="margin:22px 0"><a href="${link}" style="background:#d9232e;color:#fff;text-decoration:none;font-weight:bold;padding:12px 22px;border-radius:10px;display:inline-block">ABRIR EL PERFIL</a></p>
            <p style="font-size:12px;color:#5b6478">Entra siempre con este mismo correo (${esc(d.email)}). Si tú no realizaste este registro, responde a este email.</p>`));

    // 4) avisos: organizador + padre ya registrado
    let r2: unknown = null, r3: unknown = null;
    if (av) {
      const p = av.padre || {};
      const ficha = `
        <table style="font-size:13px;border-collapse:collapse;margin:10px 0">
          <tr><td style="padding:4px 10px 4px 0;color:#5b6478">Jugador</td><td><b>${esc(av.jugador)}</b></td></tr>
          <tr><td style="padding:4px 10px 4px 0;color:#5b6478">Padre/madre</td><td><b>${esc(p.nombre)}</b></td></tr>
          <tr><td style="padding:4px 10px 4px 0;color:#5b6478">Teléfono</td><td>${esc(p.telefono)}</td></tr>
          <tr><td style="padding:4px 10px 4px 0;color:#5b6478">Email</td><td>${esc(p.email)}</td></tr>
          <tr><td style="padding:4px 10px 4px 0;color:#5b6478">Estado</td><td>${pendiente ? '⏳ PENDIENTE de aprobación' : '✅ Aprobado (primer padre registrado)'}</td></tr>
        </table>`;
      const admins: string[] = (av.admins || []).filter(Boolean);
      r2 = await enviar(admins, `👨‍👩‍👦 Nuevo registro de padre — ${av.jugador}`,
        marco('👨‍👩‍👦 Nuevo registro de padre/madre', `
          <p>Se registró un padre/madre en el perfil de un jugador de tu marca:</p>${ficha}
          <p>Revisa su DNI y, si hace falta, quita o aprueba el acceso desde <b>liguify.com/admin → tarjeta de la marca → 👨‍👩‍👦 PADRES</b>.</p>
          <p style="margin:18px 0"><a href="${link}" style="background:#171e2e;color:#fff;text-decoration:none;font-weight:bold;padding:10px 18px;border-radius:10px;display:inline-block">VER EL PERFIL</a></p>`));
      const otros: string[] = (av.otros_padres || []).filter(Boolean);
      r3 = await enviar(otros, `${pendiente ? '⏳' : 'ℹ️'} Nueva solicitud de acceso — perfil de ${av.jugador}`,
        marco(pendiente ? '⏳ Alguien pide acceso al perfil' : 'ℹ️ Nuevo acceso al perfil', `
          <p>Hola, te avisamos porque eres padre/madre registrado de <b>${esc(av.jugador)}</b>:</p>${ficha}
          ${pendiente
            ? `<p>Esta solicitud queda <b>pendiente</b> hasta que tú o el organizador la aprueben. Entra al perfil → <b>✏️ EDITAR PERFIL</b> → sección <b>Solicitudes de acceso</b> para aprobarla o rechazarla.</p>`
            : ''}
          <p>Si no reconoces a esta persona, recházala o avisa al organizador.</p>
          <p style="margin:18px 0"><a href="${link}" style="background:#d9232e;color:#fff;text-decoration:none;font-weight:bold;padding:10px 18px;border-radius:10px;display:inline-block">ABRIR EL PERFIL</a></p>`));
    }

    return json({ ok: true, estado: d.estado, padre: r1, admins: r2, otros: r3 });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
