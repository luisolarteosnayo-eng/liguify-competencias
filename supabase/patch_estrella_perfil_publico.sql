-- ============================================================================
-- PÚBLICO: en el plantel del equipo, los jugadores con perfil habilitado
-- muestran una ⭐ que abre liguify.com/jugador/<token>.
-- Se agrega perfil_token a vista_lbf_publica (solo cuando el perfil está
-- habilitado; deshabilitado ⇒ null y la estrella no aparece).
-- La vista es la vigente de patch_fix_foto_publico.sql + el LEFT JOIN nuevo.
-- ============================================================================
create or replace view competencias.vista_lbf_publica as
select i.id as inscripcion_id, i.equipo_id, i.categoria_id, i.dorsal, i.capitan,
       i.es_excepcion, jp.nombres, jp.apellidos, jp.anio_nacimiento,
       case when jp.consentimiento_imagen
            then coalesce(ft.url, jp.foto_url) else null end as foto_url,
       jp.consentimiento_imagen,
       jp.pie_habil, jp.posicion, jp.mes_nacimiento,
       pp.token as perfil_token
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

-- Verificación: debe listar a los jugadores con perfil habilitado y su token
select nombres, apellidos, perfil_token
from competencias.vista_lbf_publica
where perfil_token is not null;
