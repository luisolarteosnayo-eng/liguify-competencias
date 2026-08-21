-- DIAGNÓSTICO (solo lectura) · ¿Quién ocupa el documento 79002986?

-- 1) La ficha maestra que tiene ese documento (y la de Eyhal, para comparar)
select j.id, j.nombres, j.apellidos,
       j.pais_documento || ' ' || j.nro_documento as documento,
       j.fecha_nacimiento, j.verificado, j.origen,
       j.created_at,
       (j.foto_url is not null)             as tiene_foto,
       (j.doc_scan_frente_url is not null)  as tiene_dni_escaneado,
       (j.autorizacion_url is not null)     as tiene_autorizacion
from competencias.jugador_maestro j
where j.nro_documento = '79002986'
   or (j.nombres ilike '%eyhal%' or j.apellidos ilike '%sánchez sotelo%' or j.apellidos ilike '%sanchez sotelo%');

-- 2) Todas las inscripciones de esa(s) ficha(s): en qué equipos figura
select j.nombres || ' ' || j.apellidos as jugador,
       j.nro_documento,
       t.nombre  as torneo,
       coalesce(c.nombre_display, c.anio_nacimiento::text || ' / ' || c.modalidad) as categoria,
       cl.nombre as club,
       coalesce(nullif(e.nombre,''), cl.nombre) as equipo,
       i.estado, i.en_lbf, i.created_at as inscrito_el,
       (select count(*) from competencias.planilla_partido pl
        where pl.inscripcion_id = i.id and pl.jugo) as partidos_jugados
from competencias.jugador_maestro j
left join competencias.inscripcion_lbf i on i.jugador_id = j.id
left join competencias.categoria c on c.id = i.categoria_id
left join competencias.torneo t    on t.id = c.torneo_id
left join competencias.equipo e    on e.id = i.equipo_id
left join competencias.club cl     on cl.id = e.club_id
where j.nro_documento = '79002986'
   or (j.nombres ilike '%eyhal%' or j.apellidos ilike '%sanchez sotelo%' or j.apellidos ilike '%sánchez sotelo%')
order by jugador, inscrito_el;

-- 3) ¿Quién pudo registrarlo? La maestra no guarda created_by (origen +
--    fecha solamente), así que se listan los accesos del club de su primera
--    inscripción: coordinadores/delegados con email, para preguntar directo.
select distinct cl.nombre as club, uc.rol, up.email
from competencias.jugador_maestro j
join competencias.inscripcion_lbf i on i.jugador_id = j.id
join competencias.equipo e  on e.id = i.equipo_id
join competencias.club cl   on cl.id = e.club_id
join competencias.usuario_club uc on uc.club_id = cl.id
join competencias.usuario_perfil up on up.id = uc.usuario_id
where j.nro_documento = '79002986';
