-- ============================================================================
-- ⚡ FASE C DE RENDIMIENTO: UN SOLO VIAJE POR PANTALLA (público)
-- Dos RPCs que devuelven TODO lo que necesita cada pantalla en un solo JSON:
--   · pantalla_torneo(p_torneo): categorías activas, clubes, equipos,
--     partidos VISIBLES (con su jornada), conteo de jugadores, tabla por zona
--     y documentos del torneo.
--   · pantalla_categoria(p_categoria): equipos, clubes, partidos VISIBLES
--     (con jornada/zona/fase), tabla, goleadores top 6, ranking top 10,
--     planillas públicas (goles/tarjetas) y conteo de jugadores.
-- Seguridad: mismos datos que HOY ve el anónimo por RLS/vistas públicas —
-- los partidos ocultos (visible=false) NO se incluyen; los nombres salen de
-- las vistas públicas (nombre abreviado de menores).
-- El frontend ya está desplegado con fallback: si estos RPCs no existen,
-- sigue usando el camino anterior; al ejecutarlos, pasa a 1 solo viaje.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.pantalla_torneo(p_torneo uuid)
returns jsonb language sql stable security definer
set search_path = competencias, public as $$
with t as (select * from competencias.torneo where id = p_torneo),
cats as (select c.* from competencias.categoria c
         where c.torneo_id = p_torneo and c.activa)
select jsonb_build_object(
  'categorias', (select coalesce(jsonb_agg(to_jsonb(c) order by c.anio_nacimiento desc),'[]'::jsonb) from cats c),
  'clubes',     (select coalesce(jsonb_agg(to_jsonb(cl)),'[]'::jsonb)
                 from competencias.club cl where cl.marca_id = (select marca_id from t)),
  'equipos',    (select coalesce(jsonb_agg(to_jsonb(e)),'[]'::jsonb)
                 from competencias.equipo e where e.categoria_id in (select id from cats)),
  'partidos',   (select coalesce(jsonb_agg((to_jsonb(p) || jsonb_build_object(
                    'jornada', case when j.id is null then null
                      else jsonb_build_object('numero',j.numero,'horarios_publicados',j.horarios_publicados) end))
                    order by p.fecha, p.hora),'[]'::jsonb)
                 from competencias.partido p
                 left join competencias.jornada j on j.id = p.jornada_id
                 where p.categoria_id in (select id from cats) and p.visible),
  'jugadores',  (select count(*) from competencias.vista_lbf_publica v
                 where v.categoria_id in (select id from cats)),
  'tabla',      (select coalesce(jsonb_agg(to_jsonb(z)),'[]'::jsonb)
                 from competencias.vista_tabla_zona z where z.categoria_id in (select id from cats)),
  'documentos', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb)
                 from competencias.torneo_documento d where d.torneo_id = p_torneo)
);
$$;

create or replace function competencias.pantalla_categoria(p_categoria uuid)
returns jsonb language sql stable security definer
set search_path = competencias, public as $$
with c as (select * from competencias.categoria where id = p_categoria),
mk as (select t.marca_id, t.id as torneo_id from competencias.torneo t
       where t.id = (select torneo_id from c))
select jsonb_build_object(
  'categoria', (select to_jsonb(x) from c x),
  'equipos',   (select coalesce(jsonb_agg(to_jsonb(e)),'[]'::jsonb)
                from competencias.equipo e where e.categoria_id = p_categoria),
  'clubes',    (select coalesce(jsonb_agg(to_jsonb(cl)),'[]'::jsonb)
                from competencias.club cl where cl.marca_id = (select marca_id from mk)),
  'partidos',  (select coalesce(jsonb_agg((to_jsonb(p)
                  || jsonb_build_object('jornada', case when j.id is null then null
                       else jsonb_build_object('numero',j.numero,'nombre',j.nombre,'horarios_publicados',j.horarios_publicados) end)
                  || jsonb_build_object('zona', case when z.id is null then null
                       else jsonb_build_object('nombre',z.nombre) end)
                  || jsonb_build_object('fase', case when f.id is null then null
                       else jsonb_build_object('nombre',f.nombre) end))
                  order by p.fecha, p.hora),'[]'::jsonb)
                from competencias.partido p
                left join competencias.jornada j on j.id = p.jornada_id
                left join competencias.zona z on z.id = p.zona_id
                left join competencias.fase f on f.id = p.fase_id
                where p.categoria_id = p_categoria and p.visible),
  'tabla',     (select coalesce(jsonb_agg(to_jsonb(v)),'[]'::jsonb)
                from competencias.vista_tabla_zona v where v.categoria_id = p_categoria),
  'goleadores',(select coalesce(jsonb_agg(to_jsonb(g)),'[]'::jsonb)
                from (select * from competencias.vista_goleadores
                      where categoria_id = p_categoria and goles > 0
                      order by goles desc, apellidos limit 6) g),
  'ranking',   competencias.ranking_categoria(p_categoria, 10, null),
  'planillas', (select coalesce(jsonb_agg(to_jsonb(v)),'[]'::jsonb)
                from competencias.vista_planilla_publica v
                where v.partido_id in (select id from competencias.partido
                                       where categoria_id = p_categoria
                                         and estado in ('finalizado','walkover') and visible)
                  and (v.goles > 0 or v.amarillas > 0 or v.rojas > 0)),
  'jugadores', (select count(*) from competencias.vista_lbf_publica v
                where v.categoria_id = p_categoria),
  'documentos',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb)
                from competencias.torneo_documento d
                where d.torneo_id = (select torneo_id from mk))
);
$$;

grant execute on function competencias.pantalla_torneo(uuid)    to anon, authenticated;
grant execute on function competencias.pantalla_categoria(uuid) to anon, authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN: ambas funciones creadas y devolviendo datos
select 'pantalla_torneo' as rpc,
       jsonb_array_length(competencias.pantalla_torneo('7a64159e-f6e1-4884-9b3b-8e1710014c35')->'categorias')::text as categorias
union all
select 'pantalla_categoria',
       jsonb_array_length(competencias.pantalla_categoria('d9c43d7f-c344-427a-9e6b-3842e5fff671')->'equipos')::text;
