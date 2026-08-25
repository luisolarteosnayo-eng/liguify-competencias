-- ============================================================================
-- 🏅 RANKING v2 (redefinición 2026-08-25)
--  · El ranking es POR TORNEO: se deja de mostrar el puesto "sistema".
--  · Nuevo: ranking POR PUESTO dentro de la categoría (pestañas):
--      ARQUEROS · DEFENSAS (defensa y lateral) ·
--      MEDIOCAMPISTAS (medios y extremos) · DELANTEROS
--  · Reagrupación de posiciones: extremo/wing pasa de DELANTERO a
--    MEDIOCAMPISTA (afecta también el puntaje: su gol vale 20, no 10).
-- ============================================================================

-- 1) Posición → línea (nueva agrupación)
create or replace function competencias.linea_de_posicion(pos text)
returns text language sql immutable as $$
  select case
    when p ~ 'arquer|porter|golero' then 'ARQ'
    when p ~ 'defens|lateral|central|back|zaguer|liber|stopper' then 'DEF'
    when p ~ 'medio|volante|mediocamp|enganche|pivot|contenci|interior|creativo|extremo|wing' then 'MED'
    when p ~ 'delant|punta|atacant|golead|ariete|9' then 'DEL'
    else null end
  from (select competencias.norm_txt(coalesce(pos,''))) x(p)
$$;

-- 2) Materializada por categoría: agrega línea y puesto dentro de la línea
drop materialized view if exists competencias.mv_ranking_categoria;
create materialized view competencias.mv_ranking_categoria as
select jugador_id, categoria_id, torneo_id, linea, puntos, goles, pj,
       rank() over (partition by categoria_id order by puntos desc, goles desc, pj desc, jugador_id) as puesto,
       count(*) over (partition by categoria_id)::int as total,
       case when linea is not null then
         rank() over (partition by categoria_id, linea order by puntos desc, goles desc, pj desc, jugador_id)
       end as puesto_linea,
       case when linea is not null then
         count(*) over (partition by categoria_id, linea)::int
       end as total_linea
from competencias.v_ranking_detalle;
create unique index on competencias.mv_ranking_categoria (jugador_id, categoria_id);

-- (las otras materializadas no cambian; se refrescan para tomar la nueva
--  agrupación de posiciones en el puntaje)
refresh materialized view competencias.mv_ranking_global;
refresh materialized view competencias.mv_ranking_torneo;

-- 3) RPC: acepta la línea (null = ranking general de la categoría)
drop function if exists competencias.ranking_categoria(uuid, int);
drop function if exists competencias.ranking_categoria(uuid, int, text);
create or replace function competencias.ranking_categoria(p_categoria uuid, p_limite int default 10, p_linea text default null)
returns jsonb language plpgsql stable security definer
set search_path = competencias, public as $$
declare v jsonb; v_lim int := least(greatest(coalesce(p_limite,10),1),50); v_linea text;
begin
  v_linea := nullif(upper(trim(coalesce(p_linea,''))),'');
  if v_linea is not null and v_linea not in ('ARQ','DEF','MED','DEL') then v_linea := null; end if;
  select jsonb_build_object(
    'linea', v_linea,
    'total', (select count(*) from mv_ranking_categoria rc
              where rc.categoria_id = p_categoria and rc.puntos > 0
                and (v_linea is null or rc.linea = v_linea)),
    'actualizado', (select to_char(max(actualizado),'YYYY-MM-DD') from mv_ranking_global),
    'filas', coalesce((select jsonb_agg(x order by (x->>'puesto')::int, x->>'apellidos') from (
      select jsonb_build_object(
        'puesto', case when v_linea is null then rc.puesto else rc.puesto_linea end,
        'puntos', rc.puntos, 'linea', rc.linea,
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
                          where rt.jugador_id = rc.jugador_id and rt.torneo_id = rc.torneo_id)
      ) as x
      from mv_ranking_categoria rc
      join vista_jugador_publico jp on jp.id = rc.jugador_id
      where rc.categoria_id = p_categoria and rc.puntos > 0
        and (v_linea is null or rc.linea = v_linea)
      order by case when v_linea is null then rc.puesto else rc.puesto_linea end
      limit v_lim
    ) s), '[]'::jsonb)
  ) into v;
  return v;
end $$;
grant execute on function competencias.ranking_categoria(uuid, int, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- Verificación: top 5 de MEDIOCAMPISTAS de la categoría 2016 de ORO - CLAUSURA
select jsonb_pretty(competencias.ranking_categoria(c.id, 5, 'MED'))
from competencias.categoria c
join competencias.torneo t on t.id = c.torneo_id
where t.nombre ilike '%ORO%CLAUSURA%2026%' and c.anio_nacimiento = 2016
limit 1;
