-- ============================================================================
-- PERFILES DEL PILOTO: los jugadores inscritos DESPUÉS de la habilitación
-- masiva quedaban sin perfil (la habilitación fue una foto del momento).
--  1) Se habilita a todos los que falten hoy en los clubes del piloto.
--  2) TRIGGER: cada inscripción nueva en un club del piloto crea el perfil
--     automáticamente (idempotente; los demás clubes no se tocan).
-- ============================================================================

-- 1) Ponerse al día (idempotente)
insert into competencias.perfil_jugador (jugador_id)
select distinct i.jugador_id
from competencias.inscripcion_lbf i
join competencias.equipo e on e.id = i.equipo_id
join competencias.club cl  on cl.id = e.club_id
where trim(regexp_replace(competencias.norm_txt(cl.nombre), '[^a-z0-9]+', ' ', 'g'))
      in ('sporting cristal base','tales academy')
on conflict (jugador_id) do nothing;

-- 2) Automático para inscripciones futuras
create or replace function competencias.auto_perfil_piloto()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
begin
  if competencias.club_piloto_perfil(new.jugador_id) then
    insert into competencias.perfil_jugador (jugador_id) values (new.jugador_id)
    on conflict (jugador_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists t_auto_perfil_piloto on competencias.inscripcion_lbf;
create trigger t_auto_perfil_piloto after insert on competencias.inscripcion_lbf
for each row execute function competencias.auto_perfil_piloto();

notify pgrst, 'reload schema';

-- Verificación: no debe quedar ningún jugador del piloto sin perfil
select cl.nombre as club,
       count(distinct i.jugador_id)                                  as jugadores,
       count(distinct i.jugador_id) filter (where pj.jugador_id is null) as sin_perfil
from competencias.inscripcion_lbf i
join competencias.equipo e on e.id = i.equipo_id
join competencias.club cl  on cl.id = e.club_id
left join competencias.perfil_jugador pj on pj.jugador_id = i.jugador_id
where trim(regexp_replace(competencias.norm_txt(cl.nombre), '[^a-z0-9]+', ' ', 'g'))
      in ('sporting cristal base','tales academy')
group by cl.nombre order by cl.nombre;
