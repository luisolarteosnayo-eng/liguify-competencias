-- ============================================================================
-- 🚫 GRUPO DE EXCLUSIÓN v2 · + NOVA CUP · excepción de MISMO CLUB
--  1) El grupo ahora incluye NOVA CUP 2026 (además de ORO y las 4 PLATAS).
--  2) EXCEPCIÓN: si el jugador ya jugó en el grupo pero con el MISMO CLUB
--     (emparejado por nombre normalizado — cubre INTI↔NOVA, p. ej. TEAM
--     CANDELA en PLATA SUR y Team Candela en NOVA), SÍ puede inscribirse.
--     El bloqueo aplica solo cuando ya jugó con un CLUB DISTINTO.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.impedir_doble_participacion_grupo()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
declare v_grupo text; v_club_nuevo text; v_club text; v_torneo text;
begin
  select t.grupo_exclusion into v_grupo
  from competencias.categoria c
  join competencias.torneo t on t.id = c.torneo_id
  where c.id = new.categoria_id;
  if v_grupo is null then return new; end if;

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

-- El grupo pasa a llamarse ORO-PLATA-NOVA 2026 e incluye NOVA CUP 2026
update competencias.torneo set grupo_exclusion = 'ORO-PLATA-NOVA 2026'
where ( marca_id = (select id from competencias.marca where nombre = 'INTI CUP')
        and nombre in ('ORO - CLAUSURA 2026',
                       'PLATA SUR - CARFIP - CLAUSURA',
                       'PLATA ESTE - RIMAC - CLAUSURA',
                       'PLATA NORTE - MAGNA CARABAYLLO - CLAUSURA',
                       'PLATA CENTRO - LEONCIO PRADO - CLAUSURA') )
   or ( marca_id in (select id from competencias.marca where nombre ilike '%NOVA%')
        and nombre = 'NOVA CUP 2026' );

notify pgrst, 'reload schema';

-- VERIFICACIÓN: deben salir 6 torneos con el grupo ORO-PLATA-NOVA 2026
select mk.nombre as marca, t.nombre as torneo, t.grupo_exclusion
from competencias.torneo t join competencias.marca mk on mk.id = t.marca_id
where t.grupo_exclusion is not null order by mk.nombre, t.nombre;
