// ============================================================================
// /api/jugador  ·  Vercel Serverless Function (Node)
// Sirve jugador.html para /jugador/<token> con las etiquetas Open Graph /
// Twitter del jugador ya inyectadas, para que al compartir el enlace en
// Facebook, WhatsApp, Instagram, TikTok, X, etc. la vista previa muestre su
// foto, nombre y resumen (los bots de esas redes NO ejecutan JavaScript).
//
// Ruta: vercel.json reescribe /jugador/:token → /api/jugador?token=:token
// Datos: la misma RPC pública perfil_publico(token) que usa la página.
// Si el token no existe o algo falla, sirve la página tal cual (sin romper).
// ============================================================================

const SUPABASE_URL = 'https://bpsczjjomgzhnjxnzmhj.supabase.co';
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJwc2N6ampvbWd6aG5qeG56bWhqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI1MDg5MTgsImV4cCI6MjA5ODA4NDkxOH0.3O92Q-3xxdCmF1LStCQrlCtz1s_EfdlayXnL_mEElOw';

const esc = (t) => String(t ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

let HTML_CACHE = { html: null, at: 0 };

async function leerPlantilla(host) {
  // se lee del propio deploy (siempre la versión publicada); cache 5 min en memoria
  if (HTML_CACHE.html && Date.now() - HTML_CACHE.at < 5 * 60 * 1000) return HTML_CACHE.html;
  const r = await fetch(`https://${host}/jugador.html`, { headers: { 'x-og-bypass': '1' } });
  if (!r.ok) throw new Error('No se pudo leer jugador.html');
  const html = await r.text();
  HTML_CACHE = { html, at: Date.now() };
  return html;
}

async function perfil(token) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/perfil_publico`, {
    method: 'POST',
    headers: {
      apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json',
      'Accept-Profile': 'competencias', 'Content-Profile': 'competencias',
    },
    body: JSON.stringify({ p_token: token }),
  });
  if (!r.ok) return null;
  const d = await r.json().catch(() => null);
  return d && d.jugador ? d : null;
}

module.exports = async (req, res) => {
  const host = req.headers.host || 'www.liguify.com';
  const token = String(req.query.token || '').replace(/[^a-z0-9]/gi, '').slice(0, 64);
  let html;
  try { html = await leerPlantilla(host); }
  catch (e) { res.statusCode = 502; return res.end('Perfil no disponible'); }

  let meta = '';
  try {
    const p = token ? await perfil(token) : null;
    if (p) {
      const j = p.jugador || {}, ts = p.torneos || [];
      const nombre = `${j.nombres || ''} ${j.apellidos || ''}`.trim();
      const tot = (k) => ts.reduce((s, t) => s + (+t[k] || 0), 0);
      const club = ts[0] ? ts[0].club : null;
      const partes = [
        j.anio ? `Nacido en ${j.anio}` : null,
        j.posicion || null,
        club || null,
        `${tot('pj')} PJ · ${tot('goles')} goles`,
      ].filter(Boolean);
      const desc = partes.join(' · ') + ' — perfil deportivo oficial en Liguify.';
      const imagen = j.foto_url || (ts.find((t) => t.escudo) || {}).escudo || null;
      const url = `https://${host}/jugador/${token}`;
      const titulo = `${nombre} — Perfil de jugador`;
      meta = [
        `<meta property="og:type" content="profile"/>`,
        `<meta property="og:site_name" content="Liguify"/>`,
        `<meta property="og:url" content="${esc(url)}"/>`,
        `<meta property="og:title" content="${esc(titulo)}"/>`,
        `<meta property="og:description" content="${esc(desc)}"/>`,
        imagen ? `<meta property="og:image" content="${esc(imagen)}"/>` : '',
        imagen ? `<meta property="og:image:alt" content="${esc(nombre)}"/>` : '',
        `<meta name="twitter:card" content="${imagen ? 'summary_large_image' : 'summary'}"/>`,
        `<meta name="twitter:title" content="${esc(titulo)}"/>`,
        `<meta name="twitter:description" content="${esc(desc)}"/>`,
        imagen ? `<meta name="twitter:image" content="${esc(imagen)}"/>` : '',
        `<meta name="description" content="${esc(desc)}"/>`,
      ].filter(Boolean).join('\n');
      html = html.replace(/<title>[^<]*<\/title>/, `<title>${esc(titulo)} · Liguify</title>\n${meta}`);
    }
  } catch (e) { /* sin OG: se sirve la página normal */ }

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  // cache en el edge de Vercel: 5 min fresco, 1 h sirviendo mientras revalida
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=3600');
  res.statusCode = 200;
  res.end(html);
};
