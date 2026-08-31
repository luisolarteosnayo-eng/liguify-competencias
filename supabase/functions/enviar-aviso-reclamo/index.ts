// ============================================================================
// ⚖ enviar-aviso-reclamo  ·  Supabase Edge Function (Deno)  · v1
// En cada envío o cambio de estado de un RECLAMO avisa por email a:
//   1) los admins del torneo, 2) el club reclamante, 3) el club reclamado.
//
// Seguridad: primero valida con el TOKEN DEL USUARIO que quien llama participa
// del reclamo (detalle_reclamo); solo entonces usa la clave de servicio para
// obtener los destinatarios (datos_email_reclamo, SOLO service_role).
//
// DESPLIEGUE: Panel → Edge Functions → New function → "enviar-aviso-reclamo"
// → pegar este código → Deploy. Usa RESEND_API_KEY (secreto ya configurado).
// ============================================================================

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const esc = (t: unknown) => String(t ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const ESTADOS: Record<string, { titulo: string; nota: string }> = {
  generado:             { titulo: 'RECLAMO PRESENTADO',        nota: 'El reclamo fue enviado y está en cola para revisión del organizador.' },
  en_proceso:           { titulo: 'RECLAMO EN PROCESO',        nota: 'El organizador inició la revisión del reclamo.' },
  pendiente_devolucion: { titulo: 'RECLAMO VÁLIDO',            nota: 'El reclamo fue declarado VÁLIDO. Queda pendiente la devolución del pago al reclamante.' },
  cerrado:              { titulo: 'RECLAMO CERRADO',           nota: 'La devolución fue registrada. El reclamo queda CERRADO.' },
  rechazado:            { titulo: 'RECLAMO RECHAZADO',         nota: 'El reclamo fue revisado y RECHAZADO. El monto queda a disposición de la organización, según las condiciones.' },
};

const marco = (titulo: string, cuerpo: string) => `
  <div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#171e2e">
    <div style="background:#171e2e;color:#fff;border-radius:14px;padding:22px 26px;margin-bottom:18px">
      <p style="margin:0;font-size:11px;letter-spacing:3px;color:#fbbf24;font-weight:bold">LIGUIFY · RECLAMOS</p>
      <h1 style="margin:6px 0 0;font-size:22px">${titulo}</h1>
    </div>
    ${cuerpo}
    <p style="font-size:11px;color:#8b93a7;border-top:1px solid #e9e6e0;padding-top:10px;margin-top:18px">⚡ Powered by Liguify · liguify.com</p>
  </div>`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const RESEND = Deno.env.get('RESEND_API_KEY');
    if (!RESEND) return json({ error: 'Falta el secreto RESEND_API_KEY' }, 500);
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const auth = req.headers.get('Authorization') || '';
    if (!auth) return json({ error: 'Falta la sesión' }, 401);

    const { reclamo_id } = await req.json();
    if (!reclamo_id) return json({ error: 'Falta reclamo_id' }, 400);

    const rpc = async (fn: string, body: unknown, key: string, bearer: string) => {
      const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: { apikey: key, Authorization: bearer, 'Content-Type': 'application/json',
                   'Accept-Profile': 'competencias', 'Content-Profile': 'competencias' },
        body: JSON.stringify(body),
      });
      const txt = await r.text();
      let d: unknown = null; try { d = txt ? JSON.parse(txt) : null; } catch { d = null; }
      return { ok: r.ok, d };
    };

    // 1) ¿quien llama participa del reclamo? (con SU token)
    const det = await rpc('detalle_reclamo', { p_id: reclamo_id }, ANON, auth);
    if (!det.ok || !det.d) return json({ error: 'Sin acceso a este reclamo' }, 403);

    // 2) destinatarios (clave de servicio)
    const dat = await rpc('datos_email_reclamo', { p_id: reclamo_id }, SERVICE, `Bearer ${SERVICE}`);
    if (!dat.ok || !dat.d) return json({ error: 'No se pudieron obtener los destinatarios' }, 500);
    const d = dat.d as Record<string, unknown>;
    const est = ESTADOS[String(d.estado)] || { titulo: 'ACTUALIZACIÓN DEL RECLAMO', nota: 'El reclamo cambió de estado.' };

    const datos = `
      <table style="width:100%;font-size:13px;border-collapse:collapse">
        <tr><td style="padding:5px 0;color:#5b6478">Reclamo</td><td style="font-weight:bold">${esc(d.codigo)}</td></tr>
        <tr><td style="padding:5px 0;color:#5b6478">Torneo</td><td style="font-weight:bold">${esc(d.torneo)}</td></tr>
        <tr><td style="padding:5px 0;color:#5b6478">Categoría</td><td>${esc(d.categoria)}</td></tr>
        <tr><td style="padding:5px 0;color:#5b6478">Reclamante</td><td>${esc(d.reclamante)}</td></tr>
        <tr><td style="padding:5px 0;color:#5b6478">Reclamado</td><td>${esc(d.reclamado)}</td></tr>
        <tr><td style="padding:5px 0;color:#5b6478">Estado</td><td style="font-weight:bold">${esc(String(d.estado).replace(/_/g,' ').toUpperCase())}</td></tr>
      </table>
      <p style="font-size:13px;background:#faf9f7;border:1px solid #e9e6e0;border-radius:10px;padding:10px 14px">${esc(est.nota)}</p>
      ${d.respuesta ? `<p style="font-size:13px"><b>Respuesta del organizador:</b><br/>${esc(d.respuesta)}</p>` : ''}`;

    const enviar = async (to: string[], titulo: string, extra: string, link: string) => {
      const dest = [...new Set(to.filter(Boolean))];
      if (!dest.length) return 0;
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: 'Liguify <noreply@liguify.com>',
          to: dest,
          subject: `${d.codigo} · ${titulo}`,
          html: marco(titulo, `${extra}${datos}
            <p style="text-align:center;margin-top:16px"><a href="${link}" style="background:#d9232e;color:#fff;text-decoration:none;font-weight:bold;padding:11px 22px;border-radius:10px;display:inline-block">VER EN LIGUIFY</a></p>`),
        }),
      });
      return r.ok ? dest.length : 0;
    };

    const admins  = (d.admins as string[]) || [];
    const recl    = (d.emails_reclamante as string[]) || [];
    const recdo   = (d.emails_reclamado as string[]) || [];
    let enviados = 0;
    enviados += await enviar(admins, est.titulo, `<p style="font-size:13px">Aviso para el <b>organizador del torneo</b>:</p>`, 'https://www.liguify.com/admin');
    enviados += await enviar(recl, est.titulo, `<p style="font-size:13px">Aviso para el <b>club reclamante</b> (${esc(d.reclamante)}):</p>`, 'https://www.liguify.com/club');
    enviados += await enviar(recdo, est.titulo, `<p style="font-size:13px">Aviso para el <b>club reclamado</b> (${esc(d.reclamado)}):</p>`, 'https://www.liguify.com/club');

    return json({ ok: true, enviados });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
