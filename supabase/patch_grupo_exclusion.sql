-- ============================================================================
-- 🚫 GRUPO DE EXCLUSIÓN DE JUGADORES (regla INTI CUP: ORO + las 4 PLATAS)
-- Los torneos que comparten torneo.grupo_exclusion son un mismo campeonato a
-- efectos de participación: si un jugador YA JUGÓ (participación real:
-- asistencia o estadísticas — mismo criterio que el candado de la LBF) en
-- cualquier torneo del grupo, NO puede inscribirse en OTRO equipo de ningún
-- torneo del grupo. Si solo está inscrito pero sin jugar, sí puede.
-- Configurable: basta poner el mismo texto de grupo en los torneos.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.torneo
  add column if not exists grupo_exclusion text;

create or replace function competencias.impedir_doble_participacion_grupo()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
declare v_grupo text; v_club text; v_torneo text;
begin
  select t.grupo_exclusion into v_grupo
  from competencias.categoria c
  join competencias.torneo t on t.id = c.torneo_id
  where c.id = new.categoria_id;
  if v_grupo is null then return new; end if;

  select cl.nombre, t2.nombre into v_club, v_torneo
  from competencias.inscripcion_lbf i
  join competencias.categoria c2 on c2.id = i.categoria_id
  join competencias.torneo t2 on t2.id = c2.torneo_id and t2.grupo_exclusion = v_grupo
  join competencias.equipo e on e.id = i.equipo_id
  join competencias.club cl on cl.id = e.club_id
  where i.jugador_id = new.jugador_id
    and i.equipo_id <> new.equipo_id
    and ( exists (select 1 from competencias.planilla_partido p
                  where p.inscripcion_id = i.id
                    and (p.jugo or coalesce(p.goles,0)>0 or coalesce(p.amarillas,0)>0
                         or coalesce(p.rojas,0)>0 or coalesce(p.minutos,0)>0
                         or coalesce(p.asistencias,0)>0))
       or exists (select 1 from competencias.acreditacion_partido a
                  where a.inscripcion_id = i.id) )
  limit 1;

  if v_club is not null then
    raise exception 'Este jugador YA ESTÁ PARTICIPANDO con % en % (mismo campeonato). No puede inscribirse en otro equipo. Si está inscrito en otro lado SIN haber jugado, primero deben quitarlo de esa planilla.', v_club, v_torneo;
  end if;
  return new;
end $$;

drop trigger if exists t_grupo_exclusion on competencias.inscripcion_lbf;
create trigger t_grupo_exclusion
before insert on competencias.inscripcion_lbf
for each row execute function competencias.impedir_doble_participacion_grupo();

-- Activar la regla para INTI CUP: ORO - CLAUSURA 2026 + las 4 PLATAS
update competencias.torneo set grupo_exclusion = 'INTI ORO-PLATA 2026'
where marca_id = (select id from competencias.marca where nombre = 'INTI CUP')
  and nombre in ('ORO - CLAUSURA 2026',
                 'PLATA SUR - CARFIP - CLAUSURA',
                 'PLATA ESTE - RIMAC - CLAUSURA',
                 'PLATA NORTE - MAGNA CARABAYLLO - CLAUSURA',
                 'PLATA CENTRO - LEONCIO PRADO - CLAUSURA');

notify pgrst, 'reload schema';

-- VERIFICACIÓN: deben salir los 5 torneos con el grupo asignado
select nombre, grupo_exclusion from competencias.torneo
where grupo_exclusion is not null order by nombre;
