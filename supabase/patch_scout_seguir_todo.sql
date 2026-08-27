-- ============================================================================
-- 🔭 SCOUT: HACER SEGUIMIENTO también desde GOLEADORES, RANKING y PERFIL
--  1) vista_goleadores expone jugador_id (columna nueva al final)
--  2) ranking_categoria agrega jugador_id a cada fila
--  3) perfil_publico devuelve jugador_id SOLO si quien consulta es scout
-- ============================================================================

-- 1) Goleadores con jugador_id
create or replace view competencias.vista_goleadores as
select i.categoria_id, i.equipo_id, i.id as inscripcion_id,
       jp.nombres, jp.apellidos,
       case when jp.consentimiento_imagen
            then coalesce(ft.url, jp.foto_url) else null end as foto_url,
       jp.consentimiento_imagen,
       coalesce(e.nombre, c.nombre) as equipo,
       pp.token as perfil_token,
       sum(p.goles)::int     as goles,
       sum(p.amarillas)::int as amarillas,
       sum(p.rojas)::int     as rojas,
       i.jugador_id
from competencias.planilla_partido p
join competencias.inscripcion_lbf i on i.id = p.inscripcion_id
join competencias.equipo e on e.id = i.equipo_id
join competencias.club c on c.id = e.club_id
join competencias.categoria cat on cat.id = i.categoria_id
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
left join competencias.perfil_jugador pp
       on pp.jugador_id = i.jugador_id and pp.habilitado
left join lateral (
  select f.url from competencias.jugador_foto f
  where f.jugador_id = i.jugador_id and f.torneo_id = cat.torneo_id
  order by f.created_at desc limit 1
) ft on true
group by i.categoria_id, i.equipo_id, i.id,
         jp.nombres, jp.apellidos, jp.consentimiento_imagen, jp.foto_url, ft.url,
         e.nombre, c.nombre, pp.token, i.jugador_id
having sum(p.goles) > 0 or sum(p.amarillas) > 0 or sum(p.rojas) > 0;

-- 2) Ranking con jugador_id
create or replace function competencias.ranking_categoria(p_categoria uuid, p_limite int default 10, p_linea text default null)
returns jsonb language plpgsql stable security definer
set search_path = competencias, public as $$
declare v jsonb; v_lim int := least(greatest(coalesce(p_limite,10),1),50); v_linea text;
begin
  v_linea := nullif(upper(trim(coalesce(p_linea,''))),'');
  if v_linea is not null and v_linea not in ('ARQ','DEF','MED','DEL') then v_linea := null; end if;
  select jsonb_build_object(
    'linea', v_linea,
    'total', (select count(*) from mv_ranking_categoria rc
              where rc.categoria_id = p_categoria and rc.puntos > 0
                and (v_linea is null or rc.linea = v_linea)),
    'actualizado', (select to_char(max(actualizado),'YYYY-MM-DD') from mv_ranking_global),
    'filas', coalesce((select jsonb_agg(x order by (x->>'puesto')::int, x->>'apellidos') from (
      select jsonb_build_object(
        'puesto', case when v_linea is null then rc.puesto else rc.puesto_linea end,
        'jugador_id', rc.jugador_id,
        'puntos', rc.puntos, 'linea', rc.linea,
        'nombres', jp.nombres, 'apellidos', jp.apellidos,
        'foto_url', jp.foto_url, 'consentimiento', jp.consentimiento_imagen,
        'perfil_token', (select pp.token from perfil_jugador pp
                         where pp.jugador_id = rc.jugador_id and pp.habilitado),
        'equipo', (select coalesce(nullif(e.nombre,''), cl.nombre)
                   from inscripcion_lbf i
                   join equipo e on e.id = i.equipo_id
                   join club cl  on cl.id = e.club_id
                   where i.jugador_id = rc.jugador_id and i.categoria_id = rc.categoria_id
                   limit 1),
        'puesto_torneo', (select rt.puesto from mv_ranking_torneo rt
                          where rt.jugador_id = rc.jugador_id and rt.torneo_id = rc.torneo_id)
      ) as x
      from mv_ranking_categoria rc
      join vista_jugador_publico jp on jp.id = rc.jugador_id
      where rc.categoria_id = p_categoria and rc.puntos > 0
        and (v_linea is null or rc.linea = v_linea)
      order by case when v_linea is null then rc.puesto else rc.puesto_linea end
      limit v_lim
    ) s), '[]'::jsonb)
  ) into v;
  return v;
end $$;
grant execute on function competencias.ranking_categoria(uuid, int, text) to anon, authenticated;

-- 3) Perfil: jugador_id solo para scouts
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
    'jugador_id', case when competencias.es_scout() then v_jug end,
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
        'duracion', coalesce(c.duracion_partido, t.duracion_partido, 90),
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
        and (coalesce(pl.jugo,false) or coalesce(pl.goles,0)>0 or coalesce(pl.amarillas,0)>0 or coalesce(pl.rojas,0)>0)   -- NUEVO: solo si participo
      limit 200
    ) sub2), '[]'::jsonb)
  ) into v;
  return v;
end $$;
grant execute on function competencias.perfil_publico(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- Verificación
select 'goleadores.jugador_id' as objeto, count(*) as existe from information_schema.columns
 where table_schema='competencias' and table_name='vista_goleadores' and column_name='jugador_id';
