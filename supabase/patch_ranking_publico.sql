-- ============================================================================
-- 🏅 RANKING VISIBLE EN PÚBLICO / ADMIN / CLUB (debajo de Goleadores)
-- RPC ranking_categoria(categoria, limite): TOP N de la categoría con puntos,
-- puesto en la categoría, puesto en el torneo y puesto Liguify (sistema).
-- Nombres recortados (vista_jugador_publico: un nombre + un apellido) y foto
-- solo con consentimiento. Límite máximo 50. Lee las vistas materializadas
-- (foto semanal del ranking).
-- ============================================================================
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

-- Verificación: TOP 10 de la categoría 2016/F9 de ORO - CLAUSURA 2026
select jsonb_pretty(competencias.ranking_categoria(c.id, 10))
from competencias.categoria c
join competencias.torneo t on t.id = c.torneo_id
where t.nombre ilike '%ORO%CLAUSURA%2026%' and c.anio_nacimiento = 2016
limit 1;
