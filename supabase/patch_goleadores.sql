-- Vista pública de estadísticas por jugador y categoría (goleadores, tarjetas).
-- Corre como owner → expone solo columnas seguras (foto ya censurada por
-- consentimiento vía vista_jugador_publico).
-- foto resuelta POR TORNEO (patch_fotos_historial.sql) con consentimiento
create or replace view competencias.vista_goleadores as
select i.categoria_id, i.equipo_id, i.id as inscripcion_id,
       jp.nombres, jp.apellidos,
       case when jp.consentimiento_imagen
            then competencias.foto_torneo(i.jugador_id, cat.torneo_id) else null end as foto_url,
       jp.consentimiento_imagen,
       coalesce(e.nombre, c.nombre) as equipo,
       sum(p.goles)::int     as goles,
       sum(p.amarillas)::int as amarillas,
       sum(p.rojas)::int     as rojas
from competencias.planilla_partido p
join competencias.inscripcion_lbf i on i.id = p.inscripcion_id
join competencias.equipo e on e.id = i.equipo_id
join competencias.club c on c.id = e.club_id
join competencias.categoria cat on cat.id = i.categoria_id
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
group by i.categoria_id, i.equipo_id, i.id, i.jugador_id, cat.torneo_id,
         jp.nombres, jp.apellidos, jp.consentimiento_imagen,
         e.nombre, c.nombre
having sum(p.goles) > 0 or sum(p.amarillas) > 0 or sum(p.rojas) > 0;

grant select on competencias.vista_goleadores to anon, authenticated;

notify pgrst, 'reload schema';
