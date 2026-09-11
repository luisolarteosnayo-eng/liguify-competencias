-- ============================================================================
-- 🔎 DUPLICADOS + PARTICIPACIÓN REAL
-- El reporte de duplicados ahora indica, por cada inscripción, si el jugador
-- YA JUGÓ en ese torneo (asistencia acreditada o estadísticas en planilla) y
-- en cuántos partidos — para decidir de qué equipo se le puede eliminar
-- (el candado de la BD impide borrar inscripciones con participación).
-- Mismo nombre y firma: create or replace directo.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.reporte_duplicados(p_marca uuid, p_torneos uuid[] default null)
returns table(jugador_id uuid, nombres text, apellidos text, pais text, documento text, equipos jsonb)
language sql security definer stable
set search_path = competencias, public
as $$
  select j.id, j.nombres, j.apellidos, j.pais_documento, j.nro_documento,
         jsonb_agg(jsonb_build_object(
           'equipo',    coalesce(e.nombre, c.nombre),
           'club',      c.nombre,
           'categoria', coalesce(cat.nombre_display, 'Cat. '||cat.anio_nacimiento||'/'||cat.modalidad),
           'torneo',    t.nombre,
           'torneo_id', t.id,
           'estado',    i.estado,
           'inscripcion_id', i.id,
           -- participación REAL (mismo criterio que el candado t_proteger_participacion)
           'jugo', (exists (select 1 from competencias.planilla_partido p
                            where p.inscripcion_id = i.id
                              and (p.jugo or coalesce(p.goles,0)>0 or coalesce(p.amarillas,0)>0
                                   or coalesce(p.rojas,0)>0 or coalesce(p.minutos,0)>0
                                   or coalesce(p.asistencias,0)>0))
                    or exists (select 1 from competencias.acreditacion_partido a
                               where a.inscripcion_id = i.id)),
           'pj', (select count(*) from (
                    select p.partido_id from competencias.planilla_partido p
                    where p.inscripcion_id = i.id
                      and (p.jugo or coalesce(p.goles,0)>0 or coalesce(p.amarillas,0)>0
                           or coalesce(p.rojas,0)>0 or coalesce(p.minutos,0)>0
                           or coalesce(p.asistencias,0)>0)
                    union
                    select a.partido_id from competencias.acreditacion_partido a
                    where a.inscripcion_id = i.id) x)
         ) order by t.nombre, cat.anio_nacimiento)
  from competencias.inscripcion_lbf i
  join competencias.equipo e on e.id = i.equipo_id
  join competencias.club c on c.id = e.club_id
  join competencias.categoria cat on cat.id = i.categoria_id
  join competencias.torneo t on t.id = cat.torneo_id
  join competencias.jugador_maestro j on j.id = i.jugador_id
  where t.marca_id = p_marca
    and competencias.es_staff_marca(p_marca)
    and (p_torneos is null or cardinality(p_torneos) = 0 or t.id = any(p_torneos))
  group by j.id, j.nombres, j.apellidos, j.pais_documento, j.nro_documento
  having count(*) > 1
  order by count(*) desc, j.apellidos
$$;

notify pgrst, 'reload schema';

-- VERIFICACIÓN: el primer duplicado con sus flags de participación
select nombres, apellidos,
       jsonb_pretty(equipos) as detalle
from competencias.reporte_duplicados(
  (select id from competencias.marca where nombre ilike '%INTI%' limit 1), null)
limit 1;
