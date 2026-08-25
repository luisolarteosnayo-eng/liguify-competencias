-- ============================================================================
-- PERFIL DE JUGADOR LIBRE PARA TODO EL SISTEMA (fin de la etapa piloto)
--  1) club_piloto_perfil pasa a devolver TRUE siempre: el registro de padres
--     (autoservicio con email + SMS) queda abierto para todos los clubes, y el
--     trigger t_auto_perfil_piloto crea el perfil en cada inscripción nueva.
--  2) Ponerse al día: se habilita el perfil de TODOS los jugadores ya
--     inscritos en la LBF (idempotente).
--  La seguridad no cambia: validación DNI+fecha con límite de intentos,
--  email confirmado, celular verificado por SMS, tope de 2 padres, DNI del
--  padre en almacenamiento privado y avisos al organizador.
-- ============================================================================

-- 1) Sin restricción de clubes (se mantiene la firma: todo el código que la
--    llama sigue funcionando sin cambios)
create or replace function competencias.club_piloto_perfil(p_jugador uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select true   -- perfil habilitado para todo el sistema (2026-08-25)
$$;

-- 2) Perfil para todos los jugadores ya inscritos en alguna LBF
insert into competencias.perfil_jugador (jugador_id)
select distinct i.jugador_id
from competencias.inscripcion_lbf i
on conflict (jugador_id) do nothing;

notify pgrst, 'reload schema';

-- Verificación: ningún jugador inscrito debe quedar sin perfil
select count(distinct i.jugador_id)                                   as jugadores_inscritos,
       count(distinct i.jugador_id) filter (where pj.jugador_id is null) as sin_perfil,
       (select count(*) from competencias.perfil_jugador)             as perfiles_totales
from competencias.inscripcion_lbf i
left join competencias.perfil_jugador pj on pj.jugador_id = i.jugador_id;
