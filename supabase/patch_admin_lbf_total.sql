-- ============================================================================
-- 👑 CONTROL TOTAL DEL ADMIN SOBRE LA LBF
--  1) RPC eliminar_inscripcion_total: el STAFF de la marca puede eliminar a
--     CUALQUIER jugador de una LBF aunque ya haya jugado. Borra primero su
--     participación (planillas, acreditaciones, eventos en vivo, y lo quita
--     como figura de partido); suspensiones y equipo ideal caen por cascade.
--     Los MARCADORES de los partidos NO cambian (van en partido.goles_*),
--     solo se pierde la atribución individual del jugador.
--     El candado t_proteger_participacion sigue intacto para los clubes.
--  2) Grupo de exclusión v3: el STAFF de la marca queda EXENTO del candado
--     al inscribir (puede agregar a cualquier jugador en cualquier momento);
--     los clubes/coordinadores siguen bloqueados igual que hoy.
--     (La fecha límite ya exoneraba al staff desde su patch original.)
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Eliminar jugador CON participación (solo staff) --------------------------
create or replace function competencias.eliminar_inscripcion_total(p_ins uuid)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_marca uuid; v_nombre text; v_pl int; v_ac int; v_ev int; v_fig int;
begin
  select t.marca_id, jm.nombres || ' ' || jm.apellidos
    into v_marca, v_nombre
  from competencias.inscripcion_lbf i
  join competencias.categoria c on c.id = i.categoria_id
  join competencias.torneo t on t.id = c.torneo_id
  join competencias.jugador_maestro jm on jm.id = i.jugador_id
  where i.id = p_ins;
  if v_marca is null then
    raise exception 'Inscripción no encontrada.';
  end if;
  if auth.uid() is null or not competencias.es_staff_marca(v_marca) then
    raise exception 'Solo el staff del organizador puede eliminar a un jugador con participación.';
  end if;

  update competencias.partido set figura_inscripcion_id = null
   where figura_inscripcion_id = p_ins;
  get diagnostics v_fig = row_count;
  delete from competencias.evento_partido where inscripcion_id = p_ins;
  get diagnostics v_ev = row_count;
  delete from competencias.planilla_partido where inscripcion_id = p_ins;
  get diagnostics v_pl = row_count;
  delete from competencias.acreditacion_partido where inscripcion_id = p_ins;
  get diagnostics v_ac = row_count;
  -- ya sin participación, t_proteger_participacion deja pasar el DELETE;
  -- suspension y equipo_ideal se limpian por on delete cascade
  delete from competencias.inscripcion_lbf where id = p_ins;

  return jsonb_build_object('jugador', v_nombre, 'planillas', v_pl,
                            'acreditaciones', v_ac, 'eventos', v_ev, 'figuras', v_fig);
end $$;

grant execute on function competencias.eliminar_inscripcion_total(uuid) to authenticated;

-- 2) Grupo de exclusión v3: staff exento ---------------------------------------
create or replace function competencias.impedir_doble_participacion_grupo()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
declare v_grupo text; v_marca uuid; v_club_nuevo text; v_club text; v_torneo text;
begin
  select t.grupo_exclusion, t.marca_id into v_grupo, v_marca
  from competencias.categoria c
  join competencias.torneo t on t.id = c.torneo_id
  where c.id = new.categoria_id;
  if v_grupo is null then return new; end if;
  if auth.uid() is null then return new; end if;                       -- service/procesos
  if competencias.es_staff_marca(v_marca) then return new; end if;     -- 👑 el admin decide

  -- club del equipo donde se quiere inscribir
  select cl.nombre into v_club_nuevo
  from competencias.equipo e
  join competencias.club cl on cl.id = e.club_id
  where e.id = new.equipo_id;

  select cl.nombre, t2.nombre into v_club, v_torneo
  from competencias.inscripcion_lbf i
  join competencias.categoria c2 on c2.id = i.categoria_id
  join competencias.torneo t2 on t2.id = c2.torneo_id and t2.grupo_exclusion = v_grupo
  join competencias.equipo e on e.id = i.equipo_id
  join competencias.club cl on cl.id = e.club_id
  where i.jugador_id = new.jugador_id
    and i.equipo_id <> new.equipo_id
    -- EXCEPCIÓN: mismo club (por nombre normalizado) → permitido
    and competencias.norm_club(cl.nombre) <> competencias.norm_club(coalesce(v_club_nuevo,''))
    and ( exists (select 1 from competencias.planilla_partido p
                  where p.inscripcion_id = i.id
                    and (p.jugo or coalesce(p.goles,0)>0 or coalesce(p.amarillas,0)>0
                         or coalesce(p.rojas,0)>0 or coalesce(p.minutos,0)>0
                         or coalesce(p.asistencias,0)>0))
       or exists (select 1 from competencias.acreditacion_partido a
                  where a.inscripcion_id = i.id) )
  limit 1;

  if v_club is not null then
    raise exception 'Este jugador YA ESTÁ PARTICIPANDO con % en % (mismo campeonato). Solo puede inscribirse en otro LBF si es el MISMO club. Si está inscrito en otro lado SIN haber jugado, primero deben quitarlo de esa planilla.', v_club, v_torneo;
  end if;
  return new;
end $$;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'rpc eliminar_inscripcion_total' as objeto, count(*)::text as existe
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'competencias' and p.proname = 'eliminar_inscripcion_total'
union all
select 'trigger exclusion (fn actualizada)', count(*)::text
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'competencias' and p.proname = 'impedir_doble_participacion_grupo';
