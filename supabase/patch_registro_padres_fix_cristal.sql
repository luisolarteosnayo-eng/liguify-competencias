-- FIX piloto: el club se llama "SPORTING CRISTAL - BASE" (con guion). El filtro
-- pasa a ignorar guiones, puntos y espacios repetidos al comparar nombres.
create or replace function competencias.club_piloto_perfil(p_jugador uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (
    select 1
    from inscripcion_lbf i
    join equipo e on e.id = i.equipo_id
    join club  cl on cl.id = e.club_id
    where i.jugador_id = p_jugador
      and trim(regexp_replace(competencias.norm_txt(cl.nombre), '[^a-z0-9]+', ' ', 'g')) in
          ('sporting cristal base', 'tales academy')   -- PILOTO: ampliar aquí
  )
$$;

-- Habilitar perfiles de los jugadores de Sporting Cristal - Base (idempotente)
insert into competencias.perfil_jugador (jugador_id)
select distinct i.jugador_id
from competencias.inscripcion_lbf i
join competencias.equipo e on e.id = i.equipo_id
join competencias.club cl  on cl.id = e.club_id
where trim(regexp_replace(competencias.norm_txt(cl.nombre), '[^a-z0-9]+', ' ', 'g'))
      in ('sporting cristal base','tales academy')
on conflict (jugador_id) do nothing;

-- Verificación: ahora deben salir ambos clubes
select cl.nombre as club, count(distinct pj.jugador_id) as perfiles
from competencias.perfil_jugador pj
join competencias.inscripcion_lbf i on i.jugador_id = pj.jugador_id
join competencias.equipo e on e.id = i.equipo_id
join competencias.club cl  on cl.id = e.club_id
where trim(regexp_replace(competencias.norm_txt(cl.nombre), '[^a-z0-9]+', ' ', 'g'))
      in ('sporting cristal base','tales academy')
group by cl.nombre order by cl.nombre;
