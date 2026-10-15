-- ============================================================================
-- ⚖ SANCIÓN/AJUSTE DE PUNTOS POR EQUIPO — ya descontaba, ahora es visible
-- La vista vista_tabla_zona YA suma equipo.ajuste_puntos al PTS (y la tabla
-- general acumulada suma esos PTS, así que el descuento se propaga solo).
-- Este patch agrega:
--  1) equipo.ajuste_motivo (auditoría: por qué se sancionó).
--  2) La vista expone el ajuste (columna nueva al final) para que las tablas
--     muestren la etiqueta "−3 PTS" junto al equipo sancionado.
-- La UI (botón ± PTS en Equipos del admin) es cambio de frontend.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.equipo add column if not exists ajuste_motivo text;

create or replace view competencias.vista_tabla_zona as
with cfg as (
  select c.id as categoria_id,
         (competencias.config_efectiva(c.id)->>'puntos_ganado')::int  as pg_,
         (competencias.config_efectiva(c.id)->>'puntos_empate')::int  as pe_,
         (competencias.config_efectiva(c.id)->>'puntos_perdido')::int as pp_
  from competencias.categoria c
),
juegos as (
  select p.zona_id, p.categoria_id, e.id as equipo_id,
         case when p.local_id = e.id then p.goles_local  else p.goles_visita end as gf,
         case when p.local_id = e.id then p.goles_visita else p.goles_local  end as gc
  from competencias.partido p
  join competencias.equipo e on e.id in (p.local_id, p.visita_id)
  left join competencias.jornada j on j.id = p.jornada_id
  where p.estado in ('finalizado','walkover')
    and p.goles_local is not null
    and coalesce(j.computa_en_tabla, true)
)
select z.id  as zona_id, z.nombre as zona,
       e.categoria_id, e.id as equipo_id,
       coalesce(e.nombre, cl.nombre) as equipo,
       cl.color, e.color_dot,
       count(g.equipo_id)::int                                   as pj,
       count(*) filter (where g.gf > g.gc)::int                  as pg,
       count(*) filter (where g.gf = g.gc)::int                  as pe,
       count(*) filter (where g.gf < g.gc)::int                  as pp,
       coalesce(sum(g.gf),0)::int                                as gf,
       coalesce(sum(g.gc),0)::int                                as gc,
       coalesce(sum(g.gf) - sum(g.gc),0)::int                    as dg,
       (count(*) filter (where g.gf > g.gc) * cfg.pg_
      + count(*) filter (where g.gf = g.gc) * cfg.pe_
      + count(*) filter (where g.gf < g.gc) * cfg.pp_
      + e.ajuste_puntos)::int                                    as pts,
       e.ajuste_puntos::int                                      as ajuste
from competencias.equipo e
join competencias.club cl on cl.id = e.club_id
join cfg on cfg.categoria_id = e.categoria_id
join competencias.equipo_en_zona ez on ez.equipo_id = e.id
join competencias.zona z on z.id = ez.zona_id
left join juegos g on g.equipo_id = e.id and g.zona_id = z.id
where e.estado = 'activo'
group by z.id, z.nombre, e.categoria_id, e.id, e.nombre, cl.nombre, cl.color,
         e.color_dot, e.ajuste_puntos, cfg.pg_, cfg.pe_, cfg.pp_;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'columna ajuste_motivo' as objeto, count(*)::text as existe
from information_schema.columns
where table_schema='competencias' and table_name='equipo' and column_name='ajuste_motivo'
union all
select 'vista expone ajuste', count(*)::text
from information_schema.columns
where table_schema='competencias' and table_name='vista_tabla_zona' and column_name='ajuste';
