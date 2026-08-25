-- ============================================================================
-- GOLEADORES y RANKING → clic en el jugador abre su PERFIL PÚBLICO.
--  1) vista_goleadores expone perfil_token (solo si el perfil está habilitado)
--  2) ranking_categoria agrega perfil_token a cada fila
-- El token del perfil es público por diseño (es el enlace que se comparte).
-- ============================================================================

-- 1) Goleadores con token del perfil (drop y recrear: la columna nueva va al medio)
drop view if exists competencias.vista_goleadores;
create view competencias.vista_goleadores as
select i.categoria_id, i.equipo_id, i.id as inscripcion_id,
       jp.nombres, jp.apellidos,
       case when jp.consentimiento_imagen
            then coalesce(ft.url, jp.foto_url) else null end as foto_url,
       jp.consentimiento_imagen,
       coalesce(e.nombre, c.nombre) as equipo,
       pp.token as perfil_token,
       sum(p.goles)::int     as goles,
       sum(p.amarillas)::int as amarillas,
       sum(p.rojas)::int     as rojas
from competencias.planilla_partido p
join competencias.inscripcion_lbf i on i.id = p.inscripcion_id
join competencias.equipo e on e.id = i.equipo_id
join competencias.club c on c.id = e.club_id
join competencias.categoria cat on cat.id = i.categoria_id
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
left join competencias.perfil_jugador pp
       on pp.jugador_id = i.jugador_id and pp.habilitado
left join lateral (
  select f.url from competencias.jugador_foto f
  where f.jugador_id = i.jugador_id and f.torneo_id = cat.torneo_id
  order by f.created_at desc limit 1
) ft on true
group by i.categoria_id, i.equipo_id, i.id,
         jp.nombres, jp.apellidos, jp.consentimiento_imagen, jp.foto_url, ft.url,
         e.nombre, c.nombre, pp.token
having sum(p.goles) > 0 or sum(p.amarillas) > 0 or sum(p.rojas) > 0;
grant select on competencias.vista_goleadores to anon, authenticated;   -- el drop borra los grants

-- 2) Ranking con token del perfil
create or replace function competencias.ranking_categoria(p_categoria uuid, p_limite int default 10)
returns jsonb language plpgsql stable security definer
set search_path = competencias, public as $$
declare v jsonb; v_lim int := least(greatest(coalesce(p_limite,10),1),50);
begin
  select jsonb_build_object(
    'total', (select count(*) from mv_ranking_categoria rc
              where rc.categoria_id = p_categoria and rc.puntos > 0),
    'actualizado', (select to_char(max(actualizado),'YYYY-MM-DD') from mv_ranking_global),
    'filas', coalesce((select jsonb_agg(x order by (x->>'puesto')::int, x->>'apellidos') from (
      select jsonb_build_object(
        'puesto', rc.puesto, 'puntos', rc.puntos,
        'nombres', jp.nombres, 'apellidos', jp.apellidos,
        'foto_url', jp.foto_url, 'consentimiento', jp.consentimiento_imagen,
        'perfil_token', (select pp.token from perfil_jugador pp
                         where pp.jugador_id = rc.jugador_id and pp.habilitado),
        'equipo', (select coalesce(nullif(e.nombre,''), cl.nombre)
                   from inscripcion_lbf i
                   join equipo e on e.id = i.equipo_id
                   join club cl  on cl.id = e.club_id
                   where i.jugador_id = rc.jugador_id and i.categoria_id = rc.categoria_id
                   limit 1),
        'puesto_torneo', (select rt.puesto from mv_ranking_torneo rt
                          where rt.jugador_id = rc.jugador_id and rt.torneo_id = rc.torneo_id),
        'puesto_liguify', (select g.puesto from mv_ranking_global g
                           where g.jugador_id = rc.jugador_id)
      ) as x
      from mv_ranking_categoria rc
      join vista_jugador_publico jp on jp.id = rc.jugador_id
      where rc.categoria_id = p_categoria and rc.puntos > 0
      order by rc.puesto limit v_lim
    ) s), '[]'::jsonb)
  ) into v;
  return v;
end $$;
grant execute on function competencias.ranking_categoria(uuid, int) to anon, authenticated;

notify pgrst, 'reload schema';

-- Verificación: goleadores con perfil clicable
select count(*) filter (where perfil_token is not null) as con_perfil,
       count(*) as total_goleadores
from competencias.vista_goleadores;
