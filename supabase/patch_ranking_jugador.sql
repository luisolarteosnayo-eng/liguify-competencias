-- ============================================================================
-- 🏅 RANKING DE JUGADORES (histórico en el sistema, actualización SEMANAL)
--
-- Puntaje por jugador según su posición (jugador_maestro.posicion):
--   Partido jugado ............ +10
--   Asistencia: DEF/ARQ +20 · MED +10 · DEL +10 · sin posición +10
--   Gol:        DEF/ARQ +30 · MED +20 · DEL +10 · sin posición +10
--   Figura del partido ........ +10
--   Aparición en equipo ideal . +10
--   Tarjeta amarilla .......... -10
--   Tarjeta roja .............. -20
--
-- Se materializa en 3 vistas (foto semanal): puesto GENERAL, por TORNEO y
-- por CATEGORÍA. Refresco: cron semanal (lunes 6am) o RPC actualizar_ranking()
-- (solo admins). El perfil público muestra puntos y puestos (sin nombres de
-- otros jugadores).
-- ============================================================================

-- 1) Posición → línea (mismo criterio que el equipo ideal en el admin)
create or replace function competencias.linea_de_posicion(pos text)
returns text language sql immutable as $$
  select case
    when p ~ 'arquer|porter|golero' then 'ARQ'
    when p ~ 'defens|lateral|central|back|zaguer|liber|stopper' then 'DEF'
    when p ~ 'delant|extremo|punta|atacant|golead|wing|ariete|9' then 'DEL'
    when p ~ 'medio|volante|mediocamp|enganche|pivot|contenci|interior|creativo' then 'MED'
    else null end
  from (select competencias.norm_txt(coalesce(pos,''))) x(p)
$$;

-- 2) Puntaje
create or replace function competencias.puntos_ranking(
  linea text, pj int, goles int, asistencias int, amarillas int, rojas int, figuras int, ideal int)
returns int language sql immutable as $$
  select pj*10
       + goles       * case when linea in ('DEF','ARQ') then 30 when linea='MED' then 20 else 10 end
       + asistencias * case when linea in ('DEF','ARQ') then 20 else 10 end
       + figuras*10 + ideal*10
       - amarillas*10 - rojas*20
$$;

-- 3) Detalle por jugador × categoría (vista en vivo; base de las materializadas)
create or replace view competencias.v_ranking_detalle as
select b.jugador_id, b.categoria_id, b.torneo_id, b.linea,
       sum(b.pj)::int pj, sum(b.goles)::int goles, sum(b.asistencias)::int asistencias,
       sum(b.amarillas)::int amarillas, sum(b.rojas)::int rojas,
       sum(b.figuras)::int figuras, sum(b.ideal)::int ideal,
       competencias.puntos_ranking(b.linea, sum(b.pj)::int, sum(b.goles)::int,
         sum(b.asistencias)::int, sum(b.amarillas)::int, sum(b.rojas)::int,
         sum(b.figuras)::int, sum(b.ideal)::int) as puntos
from (
  select i.jugador_id, i.categoria_id, c.torneo_id,
         competencias.linea_de_posicion(j.posicion) as linea,
         (select count(*) from competencias.planilla_partido pl
            join competencias.partido pa on pa.id = pl.partido_id
           where pl.inscripcion_id = i.id and pl.jugo
             and pa.estado in ('finalizado','walkover'))            as pj,
         coalesce((select sum(pl.goles)       from competencias.planilla_partido pl where pl.inscripcion_id=i.id),0) as goles,
         coalesce((select sum(pl.asistencias) from competencias.planilla_partido pl where pl.inscripcion_id=i.id),0) as asistencias,
         coalesce((select sum(pl.amarillas)   from competencias.planilla_partido pl where pl.inscripcion_id=i.id),0) as amarillas,
         coalesce((select sum(pl.rojas)       from competencias.planilla_partido pl where pl.inscripcion_id=i.id),0) as rojas,
         (select count(*) from competencias.partido pa where pa.figura_inscripcion_id = i.id) as figuras,
         (select count(*) from competencias.equipo_ideal ei where ei.inscripcion_id = i.id)   as ideal
  from competencias.inscripcion_lbf i
  join competencias.categoria c on c.id = i.categoria_id
  join competencias.torneo t    on t.id = c.torneo_id and t.estado <> 'borrador'
  join competencias.jugador_maestro j on j.id = i.jugador_id
) b
group by b.jugador_id, b.categoria_id, b.torneo_id, b.linea;

-- 4) Materializadas (la "foto" semanal)
drop materialized view if exists competencias.mv_ranking_global;
create materialized view competencias.mv_ranking_global as
select jugador_id, puntos, pj, goles, asistencias, amarillas, rojas, figuras, ideal,
       rank() over (order by puntos desc, goles desc, pj desc, jugador_id) as puesto,
       count(*) over ()::int as total,
       now() as actualizado
from (
  select jugador_id, sum(puntos)::int puntos, sum(pj)::int pj, sum(goles)::int goles,
         sum(asistencias)::int asistencias, sum(amarillas)::int amarillas, sum(rojas)::int rojas,
         sum(figuras)::int figuras, sum(ideal)::int ideal
  from competencias.v_ranking_detalle group by jugador_id
) g;
create unique index on competencias.mv_ranking_global (jugador_id);

drop materialized view if exists competencias.mv_ranking_torneo;
create materialized view competencias.mv_ranking_torneo as
select jugador_id, torneo_id, puntos,
       rank() over (partition by torneo_id order by puntos desc, goles desc, pj desc, jugador_id) as puesto,
       count(*) over (partition by torneo_id)::int as total
from (
  select jugador_id, torneo_id, sum(puntos)::int puntos, sum(goles)::int goles, sum(pj)::int pj
  from competencias.v_ranking_detalle group by jugador_id, torneo_id
) g;
create unique index on competencias.mv_ranking_torneo (jugador_id, torneo_id);

drop materialized view if exists competencias.mv_ranking_categoria;
create materialized view competencias.mv_ranking_categoria as
select jugador_id, categoria_id, torneo_id, puntos,
       rank() over (partition by categoria_id order by puntos desc, goles desc, pj desc, jugador_id) as puesto,
       count(*) over (partition by categoria_id)::int as total
from competencias.v_ranking_detalle;
create unique index on competencias.mv_ranking_categoria (jugador_id, categoria_id);

-- 5) Refresco: cron semanal o manual por un admin
create or replace function competencias.actualizar_ranking()
returns text language plpgsql security definer
set search_path = competencias, public as $$
begin
  if auth.uid() is not null
     and not exists (select 1 from usuario_marca
                     where usuario_id = auth.uid() and rol = 'admin_marca') then
    raise exception 'Solo un admin puede actualizar el ranking';
  end if;
  refresh materialized view competencias.mv_ranking_global;
  refresh materialized view competencias.mv_ranking_torneo;
  refresh materialized view competencias.mv_ranking_categoria;
  return 'Ranking actualizado ' || to_char(now(), 'YYYY-MM-DD HH24:MI');
end $$;
revoke execute on function competencias.actualizar_ranking() from public, anon;
grant execute on function competencias.actualizar_ranking() to authenticated;

do $$ begin
  create extension if not exists pg_cron;
  perform cron.unschedule('liguify_ranking_semanal')
    where exists (select 1 from cron.job where jobname = 'liguify_ranking_semanal');
  perform cron.schedule('liguify_ranking_semanal', '0 6 * * 1',
    $c$ select competencias.actualizar_ranking(); $c$);
  raise notice 'Cron semanal programado (lunes 6:00).';
exception when others then
  raise notice 'pg_cron no disponible (%). Habilita la extensión pg_cron en el panel de Supabase (Database → Extensions) y vuelve a correr este bloque, o refresca manualmente con: select competencias.actualizar_ranking();', sqlerrm;
end $$;

-- 6) Perfil público: agrega la clave 'ranking' (puntos, puesto general,
--    puesto por torneo y por categoría, fecha de actualización)
create or replace function competencias.perfil_publico(p_token text)
returns jsonb language plpgsql stable security definer
set search_path = competencias, public as $$
declare v jsonb; v_jug uuid;
begin
  select jugador_id into v_jug
  from competencias.perfil_jugador
  where token = p_token and habilitado;
  if v_jug is null then return null; end if;

  select jsonb_build_object(
    'scout_vistas', (select count(*) from scout_vista sv where sv.jugador_id = v_jug),
    'jugador', (select jsonb_build_object(
        'nombres', competencias.primer_token(j.nombres),
        'apellidos', competencias.primer_apellido(j.apellidos),
        'anio', extract(year from j.fecha_nacimiento),
        'posicion', j.posicion, 'pie', j.pie_habil,
        'foto_url', j.foto_url)
      from jugador_maestro j where j.id = v_jug),
    'perfil', (select jsonb_build_object(
        'bio', p.bio, 'instagram', p.instagram, 'facebook', p.facebook, 'tiktok', p.tiktok)
      from perfil_jugador p where p.jugador_id = v_jug),
    'media', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'tipo', m.tipo, 'url', m.url, 'titulo', m.titulo) order by m.orden, m.created_at)
      from perfil_media m where m.jugador_id = v_jug), '[]'::jsonb),
    'ranking', (select jsonb_build_object(
        'puntos', g.puntos, 'puesto', g.puesto, 'total', g.total,
        'actualizado', to_char(g.actualizado, 'YYYY-MM-DD'),
        'torneos', coalesce((select jsonb_agg(jsonb_build_object(
            'torneo', t.nombre, 'anio', t.anio, 'puntos', rt.puntos,
            'puesto', rt.puesto, 'total', rt.total) order by t.anio desc nulls last)
          from mv_ranking_torneo rt join torneo t on t.id = rt.torneo_id
          where rt.jugador_id = v_jug), '[]'::jsonb),
        'categorias', coalesce((select jsonb_agg(jsonb_build_object(
            'torneo', t2.nombre,
            'categoria', coalesce(c2.nombre_display, c2.anio_nacimiento::text || ' / ' || c2.modalidad),
            'puntos', rc.puntos, 'puesto', rc.puesto, 'total', rc.total) order by t2.anio desc nulls last)
          from mv_ranking_categoria rc
          join categoria c2 on c2.id = rc.categoria_id
          join torneo t2    on t2.id = rc.torneo_id
          where rc.jugador_id = v_jug), '[]'::jsonb))
      from mv_ranking_global g where g.jugador_id = v_jug),
    'equipo_ideal', coalesce((select jsonb_agg(z order by (z->>'anio') desc nulls last, (z->>'numero')::int desc) from (
      select jsonb_build_object(
        'torneo', t.nombre, 'anio', t.anio,
        'categoria', coalesce(c.nombre_display, c.anio_nacimiento::text || ' / ' || c.modalidad),
        'numero', jo.numero, 'linea', ei.linea) as z
      from equipo_ideal ei
      join inscripcion_lbf i on i.id = ei.inscripcion_id
      join jornada jo  on jo.id = ei.jornada_id
      join categoria c on c.id = i.categoria_id
      join torneo t    on t.id = c.torneo_id
      where i.jugador_id = v_jug and t.estado <> 'borrador'
    ) sub0), '[]'::jsonb),
    'torneos', coalesce((select jsonb_agg(x order by (x->>'anio') desc nulls last) from (
      select jsonb_build_object(
        'torneo', t.nombre, 'anio', t.anio, 'marca', mk.nombre,
        'categoria', coalesce(c.nombre_display, c.anio_nacimiento::text || ' / ' || c.modalidad),
        'club', cl.nombre, 'escudo', cl.escudo_url, 'color', cl.color,
        'pj',        (select count(*) from planilla_partido pl
                      join partido pa on pa.id = pl.partido_id
                      where pl.inscripcion_id = i.id and pl.jugo
                        and pa.estado in ('finalizado','walkover')),
        'goles',     coalesce((select sum(pl.goles)     from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'amarillas', coalesce((select sum(pl.amarillas) from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'rojas',     coalesce((select sum(pl.rojas)     from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'minutos',   coalesce((select sum(pl.minutos)   from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'asistencias', coalesce((select sum(pl.asistencias) from planilla_partido pl where pl.inscripcion_id = i.id),0)
      ) as x
      from inscripcion_lbf i
      join categoria c on c.id = i.categoria_id
      join torneo t    on t.id = c.torneo_id
      join marca mk    on mk.id = t.marca_id
      join equipo e    on e.id = i.equipo_id
      join club cl     on cl.id = e.club_id
      where i.jugador_id = v_jug and t.estado <> 'borrador'
    ) sub), '[]'::jsonb),
    'partidos', coalesce((select jsonb_agg(y order by (y->>'fecha') desc nulls last) from (
      select jsonb_build_object(
        'fecha', pa.fecha, 'torneo', t.nombre,
        'categoria', coalesce(c.nombre_display, c.anio_nacimiento::text || ' / ' || c.modalidad),
        'mi_club', cl_mio.nombre,
        'rival', coalesce(nullif(e_riv.nombre,''), cl_riv.nombre, 'Por definir'),
        'rival_escudo', cl_riv.escudo_url, 'rival_color', cl_riv.color,
        'local', (pa.local_id = i.equipo_id),
        'gl', pa.goles_local, 'gv', pa.goles_visita, 'estado', pa.estado,
        'video', pa.video_url,
        'ideal', exists (select 1 from equipo_ideal ei
                         where ei.jornada_id = pa.jornada_id and ei.inscripcion_id = i.id),
        'goles', coalesce(pl.goles,0), 'amarillas', coalesce(pl.amarillas,0),
        'rojas', coalesce(pl.rojas,0), 'jugo', coalesce(pl.jugo,false)
      ) as y
      from inscripcion_lbf i
      join categoria c on c.id = i.categoria_id
      join torneo t    on t.id = c.torneo_id
      join equipo e_mio on e_mio.id = i.equipo_id
      join club cl_mio  on cl_mio.id = e_mio.club_id
      join partido pa  on pa.categoria_id = c.id
                      and (pa.local_id = i.equipo_id or pa.visita_id = i.equipo_id)
      left join equipo e_riv on e_riv.id = case when pa.local_id = i.equipo_id then pa.visita_id else pa.local_id end
      left join club cl_riv  on cl_riv.id = e_riv.club_id
      left join planilla_partido pl on pl.partido_id = pa.id and pl.inscripcion_id = i.id
      where i.jugador_id = v_jug and t.estado <> 'borrador'
        and pa.visible and pa.estado in ('finalizado','walkover')
      limit 200
    ) sub2), '[]'::jsonb)
  ) into v;
  return v;
end $$;
grant execute on function competencias.perfil_publico(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- Verificación: TOP 15 del ranking general
select j.nombres || ' ' || j.apellidos as jugador, g.puntos, g.puesto, g.total,
       g.pj, g.goles, g.asistencias, g.figuras, g.ideal, g.amarillas, g.rojas
from competencias.mv_ranking_global g
join competencias.jugador_maestro j on j.id = g.jugador_id
order by g.puesto limit 15;
