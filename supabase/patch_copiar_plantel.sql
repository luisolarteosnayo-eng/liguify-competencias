-- ============================================================================
-- ⬇ COPIAR PLANTEL ENTRE TORNEOS (incluye torneos de OTRAS MARCAS)
--
-- El club se empareja por NOMBRE normalizado (TALES ACADEMY en NOVA CUP y en
-- INTI CUP son registros distintos pero el mismo club real). Seguridad:
--  · El que copia debe gestionar el equipo DESTINO.
--  · Solo ve como fuente los clubes homónimos donde TAMBIÉN tiene acceso:
--    es staff de esa marca, o es coordinador/sub-coordinador de ese club.
--    (Evita que alguien cree un club con el nombre de otro para jalarse
--    su lista de jugadores.)
-- Los jugadores copiados llegan con sus datos maestros y quedan PENDIENTES;
-- se omiten los que ya están inscritos en la categoría destino.
-- ============================================================================

create or replace function competencias.norm_club(t text)
returns text language sql immutable as $$
  select trim(regexp_replace(competencias.norm_txt(coalesce(t,'')), '[^a-z0-9]+', ' ', 'g'))
$$;

create or replace function competencias.acceso_club_fuente(p_club uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (
    select 1 from competencias.club c
    where c.id = p_club
      and ( competencias.es_staff_marca(c.marca_id)
         or exists (select 1 from usuario_club uc
                    where uc.usuario_id = auth.uid() and uc.club_id = c.id)
         or exists (select 1 from usuario_club_categoria ucc
                    where ucc.usuario_id = auth.uid() and ucc.club_id = c.id) )
  )
$$;

-- Fuentes disponibles para copiar hacia p_equipo
create or replace function competencias.fuentes_copiar_plantel(p_equipo uuid)
returns table(equipo_id uuid, torneo text, marca text, categoria text,
              anio int, misma_categoria boolean, jugadores int)
language plpgsql stable security definer
set search_path = competencias, public as $$
declare v_club text; v_anio int;
begin
  if not competencias.gestiona_equipo(p_equipo) then
    raise exception 'No gestionas este equipo';
  end if;
  select competencias.norm_club(cl.nombre), c.anio_nacimiento into v_club, v_anio
  from competencias.equipo e
  join competencias.club cl on cl.id = e.club_id
  join competencias.categoria c on c.id = e.categoria_id
  where e.id = p_equipo;

  return query
  select e2.id, t2.nombre, m2.nombre,
         coalesce(c2.nombre_display, c2.anio_nacimiento::text||' / '||c2.modalidad),
         c2.anio_nacimiento, (c2.anio_nacimiento = v_anio),
         count(i.id)::int
  from competencias.equipo e2
  join competencias.club cl2      on cl2.id = e2.club_id
  join competencias.categoria c2  on c2.id = e2.categoria_id
  join competencias.torneo t2     on t2.id = c2.torneo_id
  join competencias.marca m2      on m2.id = t2.marca_id
  join competencias.inscripcion_lbf i on i.equipo_id = e2.id
  where e2.id <> p_equipo
    and competencias.norm_club(cl2.nombre) = v_club
    and competencias.acceso_club_fuente(cl2.id)
  group by e2.id, t2.nombre, m2.nombre, c2.nombre_display, c2.anio_nacimiento, c2.modalidad
  order by (c2.anio_nacimiento = v_anio) desc, t2.nombre;
end $$;
revoke execute on function competencias.fuentes_copiar_plantel(uuid) from public, anon;
grant  execute on function competencias.fuentes_copiar_plantel(uuid) to authenticated;

-- Copiar la LBF de p_fuente hacia p_destino
create or replace function competencias.copiar_plantel(p_destino uuid, p_fuente uuid)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_club text; v_club_f text; v_cat uuid; v_anio int; v_total int; v_copiados int;
begin
  if not competencias.gestiona_equipo(p_destino) then
    raise exception 'No gestionas el equipo destino';
  end if;
  select competencias.norm_club(cl.nombre), e.categoria_id, c.anio_nacimiento
    into v_club, v_cat, v_anio
  from competencias.equipo e
  join competencias.club cl on cl.id = e.club_id
  join competencias.categoria c on c.id = e.categoria_id
  where e.id = p_destino;
  select competencias.norm_club(cl.nombre) into v_club_f
  from competencias.equipo e join competencias.club cl on cl.id = e.club_id
  where e.id = p_fuente;
  if v_club_f is null or v_club_f <> v_club then
    raise exception 'La fuente no corresponde al mismo club';
  end if;
  if not competencias.acceso_club_fuente((select club_id from competencias.equipo where id = p_fuente)) then
    raise exception 'Sin acceso al club de origen';
  end if;
  select count(*) into v_total from competencias.inscripcion_lbf where equipo_id = p_fuente;
  insert into competencias.inscripcion_lbf
    (equipo_id, jugador_id, categoria_id, dorsal, capitan, en_lbf, estado, es_excepcion, origen)
  select p_destino, i.jugador_id, v_cat, i.dorsal, false, true, 'pendiente',
         (extract(year from j.fecha_nacimiento)::int <> v_anio), 'maestra'
  from competencias.inscripcion_lbf i
  join competencias.jugador_maestro j on j.id = i.jugador_id
  where i.equipo_id = p_fuente
    and not exists (select 1 from competencias.inscripcion_lbf x
                    where x.jugador_id = i.jugador_id and x.categoria_id = v_cat);
  get diagnostics v_copiados = row_count;
  return jsonb_build_object('ok', true, 'copiados', v_copiados, 'omitidos', v_total - v_copiados);
end $$;
revoke execute on function competencias.copiar_plantel(uuid,uuid) from public, anon;
grant  execute on function competencias.copiar_plantel(uuid,uuid) to authenticated;

notify pgrst, 'reload schema';

-- Verificación: fuentes que vería TALES ACADEMY 2015 de NOVA CUP (como super)
select 'rpcs copiar plantel' as objeto, count(*) as existe
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='competencias'
  and p.proname in ('norm_club','acceso_club_fuente','fuentes_copiar_plantel','copiar_plantel');
