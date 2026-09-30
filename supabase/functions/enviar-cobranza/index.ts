// ============================================================================
// 💰 enviar-cobranza · Supabase Edge Function (Deno) · v2 — ENVÍO MANUAL
// La invoca el ERP (Cuentas por Cobrar → seleccionar cobros → ENVIAR COBRO).
// Body: { org_id, items: [{ club_id, torneo_id }, …] }  (ids del ERP)
// Seguridad: el RPC competencias.cobranza_datos se llama CON EL TOKEN DEL
// USUARIO y solo devuelve datos si pertenece a esa organización del ERP.
// Envía un correo por club (estado de cuenta de los torneos seleccionados)
// y registra cada envío en competencias.cobranza_aviso.
//
// DESPLIEGUE: Panel → Edge Functions → New function → "enviar-cobranza"
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
const fmt = (n: unknown) => 'S/ ' + Number(n || 0).toFixed(2);

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

    const { org_id, items } = await req.json();
    if (!org_id || !Array.isArray(items) || !items.length) return json({ error: 'Faltan org_id o items' }, 400);
    if (items.length > 200) return json({ error: 'Demasiados cobros en una sola tanda' }, 400);

    // Datos de los cobros seleccionados — validados con el TOKEN DEL USUARIO
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/cobranza_datos`, {
      method: 'POST',
      headers: { apikey: ANON, Authorization: auth, 'Content-Type': 'application/json',
                 'Accept-Profile': 'competencias', 'Content-Profile': 'competencias' },
      body: JSON.stringify({ p_org: org_id, p_items: items }),
    });
    if (!r.ok) return json({ error: 'cobranza_datos: ' + await r.text() }, 500);
    const filas = await r.json() as Record<string, unknown>[];
    if (!filas.length) return json({ ok: true, enviados: 0, sin_email: [], errores: [],
      nota: 'Sin datos: verifica que perteneces a la organización y que los cobros existen' });

    let enviados = 0; const sin_email: string[] = []; const errores: string[] = [];
    for (const f of filas) {
      if (!f.email) { sin_email.push(String(f.club)); continue; }
      const det = (f.detalle as Record<string, unknown>[]) || [];
      const filasTorneo = det.map(t => `
        <tr><td style="padding:7px 0;border-top:1px solid #e9e6e0"><b>${esc(t.torneo)}</b>
          <div style="font-size:11px;color:#8b93a7">${((t.equipos as Record<string, unknown>[]) || [])
            .map(e => `${esc(e.categoria)} · ${fmt(e.monto)}`).join('<br/>')}</div></td>
        <td style="padding:7px 0;border-top:1px solid #e9e6e0;text-align:right">${fmt(t.cargos)}</td>
        <td style="padding:7px 0;border-top:1px solid #e9e6e0;text-align:right;color:#059669">−${fmt(t.abonos)}</td>
        <td style="padding:7px 0;border-top:1px solid #e9e6e0;text-align:right;font-weight:bold;color:${Number(t.saldo) > 0 ? '#d9232e' : '#059669'}">${fmt(t.saldo)}</td></tr>`).join('');

      const html = `
        <div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#171e2e">
          <div style="background:#171e2e;color:#fff;border-radius:14px;padding:22px 26px;margin-bottom:18px">
            <p style="margin:0;font-size:11px;letter-spacing:3px;color:#fbbf24;font-weight:bold">${esc(f.empresa)} · ESTADO DE CUENTA</p>
            <h1 style="margin:6px 0 0;font-size:22px">${esc(f.club)}</h1>
          </div>
          <p style="font-size:13px">Hola, este es el estado de cuenta de tu club con <b>${esc(f.empresa)}</b>.
            Tienes un saldo pendiente de <b style="color:#d9232e">${fmt(f.saldo_total)}</b>.</p>
          <table style="width:100%;font-size:13px;border-collapse:collapse">
            <tr style="font-size:10px;color:#8b93a7;text-transform:uppercase;letter-spacing:1px">
              <td>Torneo</td><td style="text-align:right">Cargos</td>
              <td style="text-align:right">Pagado</td><td style="text-align:right">Saldo</td></tr>
            ${filasTorneo}
            <tr><td style="padding:9px 0;border-top:2px solid #171e2e;font-weight:bold">TOTAL PENDIENTE</td>
              <td></td><td></td>
              <td style="padding:9px 0;border-top:2px solid #171e2e;text-align:right;font-weight:bold;font-size:16px;color:#d9232e">${fmt(f.saldo_total)}</td></tr>
          </table>
          ${f.instrucciones ? `<div style="font-size:13px;background:#faf9f7;border:1px solid #e9e6e0;border-radius:10px;padding:10px 14px;margin-top:12px"><b>¿Cómo pagar?</b><br/>${esc(f.instrucciones)}</div>` : ''}
          <p style="font-size:12px;color:#5b6478;margin-top:12px">Si ya realizaste el pago, envía tu voucher al organizador para que lo apruebe; el saldo se actualiza automáticamente. Si crees que hay un error, responde este correo.</p>
          <p style="font-size:11px;color:#8b93a7;border-top:1px solid #e9e6e0;padding-top:10px;margin-top:18px">⚡ Powered by Liguify · liguify.com</p>
        </div>`;

      const to = [String(f.email)];
      if (f.cc_email && f.cc_email !== f.email) to.push(String(f.cc_email));
      const rs = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: 'Liguify <noreply@liguify.com>',
          to,
          subject: `${f.empresa} · Pago pendiente de ${f.club}: ${fmt(f.saldo_total)}`,
          html,
        }),
      });
      if (!rs.ok) { errores.push(`${f.club}: ${await rs.text()}`); continue; }

      await fetch(`${SUPABASE_URL}/rest/v1/cobranza_aviso`, {
        method: 'POST',
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json',
                   'Content-Profile': 'competencias', Prefer: 'return=minimal' },
        body: JSON.stringify({ marca_id: f.marca_id, club_id: f.club_id, erp_club_id: f.erp_club_id,
                               email: f.email, saldo: f.saldo_total, detalle: f.detalle }),
      });
      enviados++;
    }
    return json({ ok: true, enviados, sin_email, errores });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
