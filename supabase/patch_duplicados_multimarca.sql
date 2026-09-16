-- ============================================================================
-- 🔎 DUPLICADOS ENTRE MARCAS DE LA MISMA EMPRESA (caso INTI CUP + NOVA CUP)
-- Nueva RPC que compara torneos de VARIAS marcas a la vez. Seguridad: el
-- usuario debe ser staff de TODAS las marcas solicitadas (si no, no devuelve
-- nada). La RPC reporte_duplicados de una sola marca queda intacta.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.reporte_duplicados_marcas(p_marcas uuid[], p_torneos uuid[] default null)
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
           'marca',     mk.nombre,
           'estado',    i.estado,
           'inscripcion_id', i.id,
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
         ) order by mk.nombre, t.nombre, cat.anio_nacimiento)
  from competencias.inscripcion_lbf i
  join competencias.equipo e on e.id = i.equipo_id
  join competencias.club c on c.id = e.club_id
  join competencias.categoria cat on cat.id = i.categoria_id
  join competencias.torneo t on t.id = cat.torneo_id
  join competencias.marca mk on mk.id = t.marca_id
  where t.marca_id = any(p_marcas)
    -- staff de TODAS las marcas pedidas, o nada
    and not exists (select 1 from unnest(p_marcas) pm(id)
                    where not competencias.es_staff_marca(pm.id))
    and (p_torneos is null or cardinality(p_torneos) = 0 or t.id = any(p_torneos))
  group by j.id, j.nombres, j.apellidos, j.pais_documento, j.nro_documento
  having count(*) > 1
  order by count(*) desc, j.apellidos
$$;
revoke execute on function competencias.reporte_duplicados_marcas(uuid[],uuid[]) from public, anon;
grant  execute on function competencias.reporte_duplicados_marcas(uuid[],uuid[]) to authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'rpc reporte_duplicados_marcas' as objeto, count(*)::text as existe
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='competencias' and p.proname='reporte_duplicados_marcas';
