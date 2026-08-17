-- ============================================================================
-- FIX: en el PÚBLICO (anónimo), abrir la ficha de un equipo fallaba con
-- "permission denied for table usuario_club".
-- Causa: las vistas públicas llamaban a foto_torneo(), y el cuerpo de una
-- función NO security definer corre con el rol del visitante (anon), que no
-- puede leer jugador_foto/jugador_maestro. Solución:
--   1) Las vistas resuelven la foto por torneo con un JOIN LATERAL inline
--      (el texto de la vista sí corre con privilegios del owner).
--   2) foto_torneo() pasa a SECURITY DEFINER (para las RPC y usos internos)
--      y se le revoca el execute a anon (evita leer fotos sin consentimiento
--      llamándola directo).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace view competencias.vista_lbf_publica as
select i.id as inscripcion_id, i.equipo_id, i.categoria_id, i.dorsal, i.capitan,
       i.es_excepcion, jp.nombres, jp.apellidos, jp.anio_nacimiento,
       case when jp.consentimiento_imagen
            then coalesce(ft.url, jp.foto_url) else null end as foto_url,
       jp.consentimiento_imagen,
       jp.pie_habil, jp.posicion, jp.mes_nacimiento
from competencias.inscripcion_lbf i
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
join competencias.categoria cat on cat.id = i.categoria_id
left join lateral (
  select f.url from competencias.jugador_foto f
  where f.jugador_id = i.jugador_id and f.torneo_id = cat.torneo_id
  order by f.created_at desc limit 1
) ft on true
where i.en_lbf and not i.inhabilitado;

create or replace view competencias.vista_goleadores as
select i.categoria_id, i.equipo_id, i.id as inscripcion_id,
       jp.nombres, jp.apellidos,
       case when jp.consentimiento_imagen
            then coalesce(ft.url, jp.foto_url) else null end as foto_url,
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
left join lateral (
  select f.url from competencias.jugador_foto f
  where f.jugador_id = i.jugador_id and f.torneo_id = cat.torneo_id
  order by f.created_at desc limit 1
) ft on true
group by i.categoria_id, i.equipo_id, i.id,
         jp.nombres, jp.apellidos, jp.consentimiento_imagen, jp.foto_url, ft.url,
         e.nombre, c.nombre
having sum(p.goles) > 0 or sum(p.amarillas) > 0 or sum(p.rojas) > 0;

-- foto_torneo con privilegios propios (la usan las RPC de carnets) y SIN anon
create or replace function competencias.foto_torneo(p_jugador uuid, p_torneo uuid)
returns text
language sql stable security definer
set search_path = competencias, public
as $$
  select coalesce(
    (select f.url from competencias.jugador_foto f
      where f.jugador_id = p_jugador and f.torneo_id = p_torneo
      order by f.created_at desc limit 1),
    (select j.foto_url from competencias.jugador_maestro j where j.id = p_jugador))
$$;
revoke execute on function competencias.foto_torneo(uuid,uuid) from public, anon;
grant  execute on function competencias.foto_torneo(uuid,uuid) to authenticated;

notify pgrst, 'reload schema';
