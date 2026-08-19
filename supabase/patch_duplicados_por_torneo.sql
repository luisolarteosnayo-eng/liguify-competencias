-- ============================================================================
-- 🔎 DUPLICADOS por TORNEOS SELECCIONADOS
-- Antes el reporte siempre comparaba TODOS los torneos de la marca. Ahora se
-- puede elegir qué torneos revisar: uno solo (duplicados entre categorías de
-- ese torneo) o un subconjunto (cruces solo entre esos torneos).
-- p_torneos null o vacío = todos los torneos de la marca (comportamiento
-- anterior). Se agrega torneo_id al detalle para que el frontend no dependa
-- del nombre del torneo.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

drop function if exists competencias.reporte_duplicados(uuid);

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
           'estado',    i.estado) order by t.nombre, cat.anio_nacimiento)
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

revoke execute on function competencias.reporte_duplicados(uuid,uuid[]) from public, anon;
grant  execute on function competencias.reporte_duplicados(uuid,uuid[]) to authenticated;

notify pgrst, 'reload schema';
