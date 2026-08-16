-- ============================================================================
-- VALIDACIÓN DE TRAZABILIDAD: un jugador que YA PARTICIPÓ en algún partido
-- del torneo (asistencia acreditada o estadísticas en planilla) NO puede
-- eliminarse de la LBF — a nivel de BASE DE DATOS (antes solo el admin lo
-- validaba en pantalla; el club podía borrar pendientes con participación).
-- La alternativa correcta es INHABILITARLO.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.impedir_borrar_participacion()
returns trigger
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if exists (select 1 from competencias.planilla_partido p
             where p.inscripcion_id = old.id
               and (p.jugo or p.goles > 0 or p.amarillas > 0 or p.rojas > 0
                    or p.minutos > 0 or p.asistencias > 0))
     or exists (select 1 from competencias.acreditacion_partido a
                where a.inscripcion_id = old.id) then
    raise exception 'Este jugador ya participó en partidos del torneo: no puede eliminarse de la LBF (protege la trazabilidad). Usa INHABILITAR.';
  end if;
  return old;
end $$;

drop trigger if exists t_proteger_participacion on competencias.inscripcion_lbf;
create trigger t_proteger_participacion before delete on competencias.inscripcion_lbf
for each row execute function competencias.impedir_borrar_participacion();

notify pgrst, 'reload schema';
