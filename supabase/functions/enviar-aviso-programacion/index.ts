// ============================================================================
// 📧 enviar-aviso-programacion  ·  Supabase Edge Function (Deno)
// Avisa por email a los clubes de un torneo que la programación de una fecha
// ya está disponible. Cada club recibe SUS partidos (hora, rival, cancha) y,
// si su plantel está incompleto, un recordatorio para cargarlo.
//
// DESPLIEGUE (una sola vez, lo hace el organizador):
//   1) Guardar la API key de Resend como secreto del proyecto:
//        supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxx
//      (o en el panel: Edge Functions → Secrets)
//   2) Desplegar:
//        supabase functions deploy enviar-aviso-programacion
//
// Requiere que el remitente use un dominio verificado en Resend (liguify.com).
// La autorización la impone la base: la RPC destinatarios_programacion solo
// responde al staff de la marca dueña del torneo.
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
    if (!auth) return json({ error: 'Falta la sesión del organizador' }, 401);

    const { torneo_id, fecha, prueba_a } = await req.json();
    if (!torneo_id || !fecha) return json({ error: 'Faltan torneo_id o fecha' }, 400);

    // --- llamadas a PostgREST con el token del usuario (respeta RLS y roles) ---
    const api = async (path: string, init: RequestInit = {}) => {
      const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
        ...init,
        headers: {
          apikey: ANON, Authorization: auth, 'Content-Type': 'application/json',
          'Accept-Profile': 'competencias', 'Content-Profile': 'competencias',
          ...(init.headers || {}),
        },
      });
      const txt = await r.text();
      let body: any = null; try { body = txt ? JSON.parse(txt) : null; } catch { body = txt; }
      if (!r.ok) throw new Error(typeof body === 'string' ? body : (body?.message || `Error ${r.status}`));
      return body;
    };

    // 1) destinatarios (la RPC valida que quien llama sea staff de la marca)
    const clubes = await api('rpc/destinatarios_programacion', {
      method: 'POST', body: JSON.stringify({ p_torneo: torneo_id, p_fecha: fecha }),
    });

    // 2) datos del torneo para el asunto y el enlace público
    const t = (await api(`torneo?id=eq.${torneo_id}&select=nombre,slug,marca:marca_id(nombre,slug)`))[0];
    const marca = t?.marca?.nombre || 'Liguify';
    const urlPublica = `https://liguify.com/${t?.marca?.slug || ''}`;

    // día de la fecha (el primero que aparezca entre los partidos)
    let dia = '';
    for (const c of clubes) { const p = (c.partidos || [])[0]; if (p?.dia) { dia = p.dia; break; } }
    const diaTxt = dia
      ? new Date(dia + 'T00:00:00').toLocaleDateString('es-PE', { weekday: 'long', day: 'numeric', month: 'long' })
      : 'día por confirmar';

    const filaHTML = (p: any) => `
      <tr>
        <td style="padding:8px 10px;border-bottom:1px solid #eef1f5;font-weight:700;color:#d9232e;white-space:nowrap">${esc(p.hora || '--:--')}</td>
        <td style="padding:8px 10px;border-bottom:1px solid #eef1f5;font-size:12px;color:#5b6478">${esc(p.categoria)}</td>
        <td style="padding:8px 10px;border-bottom:1px solid #eef1f5;font-weight:700">${esc(p.local)} <span style="color:#94a3b8;font-weight:400">vs</span> ${esc(p.visita)}</td>
        <td style="padding:8px 10px;border-bottom:1px solid #eef1f5;font-size:12px;color:#5b6478;white-space:nowrap">${esc([p.cancha, p.sede].filter(Boolean).join(' · '))}</td>
      </tr>`;

    const cuerpo = (c: any) => {
      const partidos = c.partidos || [];
      const pend = c.lbf_pendientes || 0, total = c.lbf_total || 0;
      const aviso = total === 0
        ? `<p style="margin:0;padding:12px 14px;background:#fff7ed;border-left:4px solid #d9232e;border-radius:6px;font-size:13px">
             ⚠ <b>Tu lista de buena fe está vacía.</b> Ingresa a <a href="https://liguify.com/club" style="color:#d9232e">liguify.com/club</a> y registra a tus jugadores antes de la fecha.</p>`
        : pend > 0
        ? `<p style="margin:0;padding:12px 14px;background:#fff7ed;border-left:4px solid #f59e0b;border-radius:6px;font-size:13px">
             ⚠ Tienes <b>${pend} jugador(es) pendientes</b> de ${total} en tu lista de buena fe. Complétalos en <a href="https://liguify.com/club" style="color:#d9232e">liguify.com/club</a>.</p>`
        : '';
      return `<!doctype html><html><body style="margin:0;background:#f4f5f7;font-family:Arial,Helvetica,sans-serif;color:#171e2e">
        <div style="max-width:640px;margin:0 auto;padding:24px">
          <div style="background:#171e2e;color:#fff;border-radius:14px;padding:20px 24px">
            <div style="font-size:11px;letter-spacing:3px;color:#fbbf24;font-weight:bold;text-transform:uppercase">Programación disponible</div>
            <div style="font-size:24px;font-weight:bold;text-transform:uppercase;margin-top:4px">${esc(t?.nombre || '')}</div>
            <div style="font-size:13px;color:#cbd5e1;margin-top:4px">Fecha ${esc(fecha)} · ${esc(diaTxt)}</div>
          </div>
          <p style="font-size:15px;line-height:1.5">Hola <b>${esc(c.club)}</b>, ya publicamos la programación de la <b>Fecha ${esc(fecha)}</b>.</p>
          ${partidos.length ? `
          <table style="width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden;border:1px solid #e9e6e0">
            <thead><tr style="background:#f8fafc">
              <th align="left" style="padding:8px 10px;font-size:11px;color:#8b93a7;text-transform:uppercase">Hora</th>
              <th align="left" style="padding:8px 10px;font-size:11px;color:#8b93a7;text-transform:uppercase">Categoría</th>
              <th align="left" style="padding:8px 10px;font-size:11px;color:#8b93a7;text-transform:uppercase">Partido</th>
              <th align="left" style="padding:8px 10px;font-size:11px;color:#8b93a7;text-transform:uppercase">Lugar</th>
            </tr></thead>
            <tbody>${partidos.map(filaHTML).join('')}</tbody>
          </table>` : `<p style="font-size:14px;color:#5b6478">Tu club no tiene partidos programados en esta fecha.</p>`}
          <div style="margin:18px 0">${aviso}</div>
          <p style="text-align:center;margin:22px 0">
            <a href="${esc(urlPublica)}" style="background:#d9232e;color:#fff;text-decoration:none;font-weight:bold;padding:12px 26px;border-radius:10px;display:inline-block">VER LA PROGRAMACIÓN COMPLETA</a>
          </p>
          <p style="font-size:12px;color:#8b93a7;text-align:center;line-height:1.6">
            Tus partidos y tu plantel están en <a href="https://liguify.com/club" style="color:#5b6478">liguify.com/club</a><br>
            ${esc(marca)} · ⚡ Powered by Liguify
          </p>
        </div></body></html>`;
    };

    // 3) envío (uno por club, con sus destinatarios en copia)
    const enviados: any[] = [], fallidos: any[] = [];
    const objetivo = prueba_a ? [{ ...clubes[0], emails: [prueba_a], club: clubes[0]?.club || 'PRUEBA' }] : clubes;
    for (const c of objetivo) {
      const to = (c.emails || []).filter(Boolean);
      if (!to.length) { fallidos.push({ club: c.club, error: 'sin correos registrados' }); continue; }
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: `${marca} <no-reply@liguify.com>`,
          to,
          subject: `${t?.nombre || 'Torneo'} · Fecha ${fecha} — programación disponible`,
          html: cuerpo(c),
        }),
      });
      const body = await r.json().catch(() => ({}));
      if (r.ok) enviados.push({ club: c.club, to, id: body?.id });
      else fallidos.push({ club: c.club, to, error: body?.message || `HTTP ${r.status}` });
      await new Promise((res) => setTimeout(res, 600));   // Resend limita ~2 envíos/segundo
    }

    // 4) registro (la policy solo deja escribir al staff de la marca)
    if (!prueba_a) {
      await api('aviso_programacion', {
        method: 'POST',
        headers: { Prefer: 'return=minimal' },
        body: JSON.stringify({
          torneo_id, fecha_numero: fecha,
          destinatarios: clubes.reduce((a: number, c: any) => a + (c.emails || []).length, 0),
          enviados: enviados.reduce((a: number, e: any) => a + e.to.length, 0),
          detalle: { enviados, fallidos },
        }),
      }).catch(() => {});
    }

    return json({ ok: true, clubes: clubes.length, enviados, fallidos });
  } catch (e) {
    return json({ error: (e as Error).message || String(e) }, 400);
  }
});
