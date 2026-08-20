-- ============================================================================
-- ONE-OFF · Activar inscripciones PENDIENTES de jugadores que YA tienen
-- autorización de Padre/Tutor subida, en torneos que la exigen.
--
-- Caso: Owen Iturriza (PE 006161327) subió su autorización en ORO 2014 F11;
-- al reinscribirlo en la categoría 2015 de ORO CLAUSURA 2026 la inscripción
-- nueva nació 'pendiente' y nada la reactivó, porque la activación solo se
-- disparaba al SUBIR el archivo (y el archivo ya estaba subido).
--
-- Corrige TODOS los casos iguales, no solo el de Owen. No toca inhabilitaciones,
-- no toca torneos que no exigen autorización, y es idempotente.
-- ============================================================================

-- Vista previa: qué inscripciones se van a activar.
select t.nombre as torneo,
       coalesce(c.nombre_display, c.anio_nacimiento::text || ' ' || c.modalidad) as categoria,
       cl.nombre as club,
       j.nombres || ' ' || j.apellidos as jugador,
       j.pais_documento || ' ' || j.nro_documento as documento,
       i.estado
from competencias.inscripcion_lbf i
join competencias.jugador_maestro j on j.id = i.jugador_id
join competencias.categoria c on c.id = i.categoria_id
join competencias.torneo t    on t.id = c.torneo_id
join competencias.equipo e    on e.id = i.equipo_id
join competencias.club cl     on cl.id = e.club_id
where i.estado = 'pendiente'
  and t.requiere_autorizacion
  and j.autorizacion_url is not null
order by t.nombre, categoria, club, jugador;

-- La activación. El flag es el mismo que usa la RPC subir_autorizacion_jugador:
-- el trigger de protección solo deja pasar pendiente→activo cuando está puesto.
do $$
declare n int;
begin
  perform set_config('competencias.activar_por_autorizacion', '1', true);
  update competencias.inscripcion_lbf i
     set estado = 'activo'
  from competencias.jugador_maestro j,
       competencias.categoria c
       join competencias.torneo t on t.id = c.torneo_id
  where j.id = i.jugador_id
    and c.id = i.categoria_id
    and i.estado = 'pendiente'
    and t.requiere_autorizacion
    and j.autorizacion_url is not null;
  get diagnostics n = row_count;
  perform set_config('competencias.activar_por_autorizacion', '', true);
  raise notice 'Inscripciones activadas: %', n;
end $$;

-- Verificación puntual: Owen debe salir 'activo' en la categoría 2015.
select t.nombre as torneo,
       coalesce(c.nombre_display, c.anio_nacimiento::text || ' ' || c.modalidad) as categoria,
       i.estado
from competencias.inscripcion_lbf i
join competencias.jugador_maestro j on j.id = i.jugador_id
join competencias.categoria c on c.id = i.categoria_id
join competencias.torneo t    on t.id = c.torneo_id
where j.nro_documento = '006161327'
order by t.nombre;
