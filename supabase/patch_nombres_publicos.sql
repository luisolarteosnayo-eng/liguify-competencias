-- ============================================================================
-- SEGURIDAD: en el PÚBLICO los jugadores se muestran con UN nombre y UN
-- apellido (decisión 2026-08-23). Se corta EN LA BASE: el visitante anónimo
-- nunca recibe el nombre completo, sin importar la pantalla.
-- Cubre: LBF pública, goleadores, planilla pública (detalle de partido, goles
-- y tarjetas bajo el marcador), perfil de jugador y su vista previa al
-- compartir. Admin y Club siguen viendo el nombre completo (leen la maestra).
-- ============================================================================

-- 1) Helpers: primer nombre / primer apellido (respetando partículas:
--    "De la Cruz" → "De la Cruz"… se toma partícula + siguiente palabra)
create or replace function competencias.primer_token(t text)
returns text language sql immutable as $$
  select coalesce((regexp_split_to_array(trim(coalesce(t,'')), '\s+'))[1], '')
$$;

create or replace function competencias.primer_apellido(t text)
returns text language sql immutable as $$
  select case
    when lower(coalesce(p[1],'')) in ('de','del','la','las','los','san','santa','van','von','da','di','mc','mac')
         and array_length(p,1) >= 2
      then case
        when lower(p[1])='de' and lower(coalesce(p[2],'')) in ('la','las','los') and array_length(p,1) >= 3
          then p[1]||' '||p[2]||' '||p[3]
        else p[1]||' '||p[2]
      end
    else coalesce(p[1],'')
  end
  from (select regexp_split_to_array(trim(coalesce(t,'')), '\s+') as p) x
$$;

-- 2) La vista base del jugador PÚBLICO entrega el nombre recortado.
--    (vista_lbf_publica, vista_planilla_publica y vista_goleadores se
--    alimentan de esta vista, así que heredan el recorte sin tocarlas.)
create or replace view competencias.vista_jugador_publico as
select j.id,
       competencias.primer_token(j.nombres)     as nombres,
       competencias.primer_apellido(j.apellidos) as apellidos,
       extract(year from j.fecha_nacimiento)::int as anio_nacimiento,
       case when j.consentimiento_imagen then j.foto_url else null end as foto_url,
       j.consentimiento_imagen,
       j.verificado,
       j.pie_habil, j.posicion,
       extract(month from j.fecha_nacimiento)::int as mes_nacimiento
from competencias.jugador_maestro j;

-- 3) Perfil público del jugador: mismo recorte (solo cambian estas 2 líneas;
--    el resto de la función queda igual que la versión vigente)
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

-- Verificación: el recorte funcionando
select competencias.primer_token('Valentino Benjamin')    as nombre,
       competencias.primer_apellido('Ramos Yauri')        as apellido,
       competencias.primer_apellido('De la Cruz Gonzales') as apellido_compuesto;
