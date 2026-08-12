-- ============================================================================
-- EL CLUB GESTIONA SUS PROPIAS ESTADÍSTICAS: puede actualizar MINUTOS y
-- ASISTENCIAS de sus jugadores por partido (goles y tarjetas siguen siendo
-- oficiales del organizador — la RPC no los toca jamás).
-- Alcance: gestiona_equipo (coordinador multimarca / delegado / sub-coordinador
-- de la categoría) y solo en partidos donde juega su equipo.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.actualizar_stats_club(p_equipo uuid, p_partido uuid, p_stats jsonb)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare
  v_cat uuid; r record; n int := 0;
begin
  select categoria_id into v_cat from competencias.partido
  where id = p_partido and (local_id = p_equipo or visita_id = p_equipo);
  if v_cat is null then
    raise exception 'El partido no corresponde a este equipo';
  end if;
  if not competencias.gestiona_equipo(p_equipo, v_cat) then
    raise exception 'Sin permiso sobre este equipo';
  end if;

  for r in
    select (e->>'inscripcion')::uuid as ins,
           greatest(0, coalesce((e->>'minutos')::int, 0))     as mn,
           greatest(0, coalesce((e->>'asistencias')::int, 0)) as asis
    from jsonb_array_elements(p_stats) e
  loop
    -- solo inscripciones del propio equipo (ignora ajenas en silencio)
    if not exists (select 1 from competencias.inscripcion_lbf i
                   where i.id = r.ins and i.equipo_id = p_equipo) then
      continue;
    end if;
    insert into competencias.planilla_partido (partido_id, inscripcion_id, jugo, goles, amarillas, rojas, minutos, asistencias)
    values (p_partido, r.ins, r.mn > 0, 0, 0, 0, r.mn, r.asis)
    on conflict (partido_id, inscripcion_id) do update
      set minutos     = excluded.minutos,
          asistencias = excluded.asistencias,
          jugo        = competencias.planilla_partido.jugo or excluded.minutos > 0;
    n := n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'actualizados', n);
end $$;

revoke execute on function competencias.actualizar_stats_club(uuid,uuid,jsonb) from public, anon;
grant  execute on function competencias.actualizar_stats_club(uuid,uuid,jsonb) to authenticated;

notify pgrst, 'reload schema';
