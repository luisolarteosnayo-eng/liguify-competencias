-- Reporte de jugadores en MÁS de un equipo (misma persona/documento) en los
-- torneos de la marca. Solo staff de la marca. La anti-suplantación ya impide
-- duplicados dentro de una misma categoría; este reporte detecta los cruces
-- entre categorías y torneos para revisión del admin.
create or replace function competencias.reporte_duplicados(p_marca uuid)
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
           'estado',    i.estado) order by t.nombre, cat.anio_nacimiento)
  from competencias.inscripcion_lbf i
  join competencias.equipo e on e.id = i.equipo_id
  join competencias.club c on c.id = e.club_id
  join competencias.categoria cat on cat.id = i.categoria_id
  join competencias.torneo t on t.id = cat.torneo_id
  join competencias.jugador_maestro j on j.id = i.jugador_id
  where t.marca_id = p_marca
    and competencias.es_staff_marca(p_marca)
  group by j.id, j.nombres, j.apellidos, j.pais_documento, j.nro_documento
  having count(*) > 1
  order by count(*) desc, j.apellidos
$$;
revoke execute on function competencias.reporte_duplicados(uuid) from public, anon;
grant  execute on function competencias.reporte_duplicados(uuid) to authenticated;

notify pgrst, 'reload schema';
