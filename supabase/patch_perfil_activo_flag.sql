-- PÚBLICO: distinguir perfiles ACTIVOS (padre registrado y aprobado → estrella
-- dorada) de los habilitados sin padre aún (estrella ploma). Solo se expone
-- un boolean; ningún dato del padre.
create or replace view competencias.vista_lbf_publica as
select i.id as inscripcion_id, i.equipo_id, i.categoria_id, i.dorsal, i.capitan,
       i.es_excepcion, jp.nombres, jp.apellidos, jp.anio_nacimiento,
       case when jp.consentimiento_imagen
            then coalesce(ft.url, jp.foto_url) else null end as foto_url,
       jp.consentimiento_imagen,
       jp.pie_habil, jp.posicion, jp.mes_nacimiento,
       pp.token as perfil_token,
       exists (select 1 from competencias.usuario_jugador uj
               where uj.jugador_id = i.jugador_id and uj.estado = 'aprobado') as perfil_activo
from competencias.inscripcion_lbf i
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
join competencias.categoria cat on cat.id = i.categoria_id
left join lateral (
  select f.url from competencias.jugador_foto f
  where f.jugador_id = i.jugador_id and f.torneo_id = cat.torneo_id
  order by f.created_at desc limit 1
) ft on true
left join competencias.perfil_jugador pp
       on pp.jugador_id = i.jugador_id and pp.habilitado
where i.en_lbf and not i.inhabilitado;

notify pgrst, 'reload schema';

-- Verificación: cuántos perfiles activos (con padre) vs habilitados sin padre
select count(*) filter (where perfil_token is not null and perfil_activo)     as con_padre,
       count(*) filter (where perfil_token is not null and not perfil_activo) as sin_padre
from competencias.vista_lbf_publica;
