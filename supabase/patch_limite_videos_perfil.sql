-- Perfil de jugador: máximo 2 links de video propios (antes 8). Los perfiles
-- que ya superan el tope conservan sus videos; solo se bloquea agregar más.
-- (En el futuro se ofrecerán más videos previo pago.) Fotos siguen en 3.
create or replace function competencias.limite_perfil_media()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
declare n int;
begin
  select count(*) into n from competencias.perfil_media
  where jugador_id = new.jugador_id and tipo = new.tipo;
  if new.tipo = 'foto'  and n >= 3 then raise exception 'Máximo 3 fotos: elimina una para subir otra.'; end if;
  if new.tipo = 'video' and n >= 2 then raise exception 'Máximo 2 videos en el plan actual: elimina uno para agregar otro.'; end if;
  new.created_by := auth.uid();
  return new;
end $$;
select 'limite de videos = 2' as resultado;
