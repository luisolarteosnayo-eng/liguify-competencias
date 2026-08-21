-- ============================================================================
-- TRAZABILIDAD: ¿quién registró la ficha y cada inscripción?
--
-- Caso Eyhal Sánchez (doc 79002986 mal digitado): no se pudo saber quién creó
-- la ficha porque jugador_maestro no guardaba el usuario creador.
--
-- · jugador_maestro.created_by e inscripcion_lbf.created_by: se llenan solos
--   con el usuario logueado en cada INSERT (trigger; no confía en el cliente).
-- · RPC quien_registro(jugador): para el staff de la marca — fecha y email de
--   quien creó la ficha y cada inscripción (las anteriores a hoy salen sin
--   autor: "antes de la trazabilidad").
-- ============================================================================

alter table competencias.jugador_maestro add column if not exists created_by uuid;
alter table competencias.inscripcion_lbf add column if not exists created_by uuid;

create or replace function competencias.sellar_created_by()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
begin
  if auth.uid() is not null then
    new.created_by := auth.uid();   -- siempre el usuario real, no lo que mande el cliente
  end if;
  return new;
end $$;

drop trigger if exists t_sellar_jugador on competencias.jugador_maestro;
create trigger t_sellar_jugador before insert on competencias.jugador_maestro
for each row execute function competencias.sellar_created_by();

drop trigger if exists t_sellar_inscripcion on competencias.inscripcion_lbf;
create trigger t_sellar_inscripcion before insert on competencias.inscripcion_lbf
for each row execute function competencias.sellar_created_by();

-- Solo staff de una marca donde el jugador está inscrito (o super) puede ver
-- los emails de registro.
create or replace function competencias.quien_registro(p_jugador uuid)
returns table(tipo text, ref_id uuid, detalle text, fecha timestamptz, email text)
language sql stable security definer
set search_path = competencias, public as $$
  with permiso as (
    select competencias.es_super()
        or exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.es_staff_marca(competencias.marca_de_categoria(i.categoria_id))) as ok
  )
  select 'ficha'::text, j.id, 'Ficha maestra (origen '||j.origen||')', j.created_at,
         coalesce(au.email::text, case when j.created_by is null then null else j.created_by::text end)
  from competencias.jugador_maestro j
  left join auth.users au on au.id = j.created_by
  where j.id = p_jugador and (select ok from permiso)
  union all
  select 'inscripcion', i.id,
         coalesce(nullif(e.nombre,''), cl.nombre) || ' · ' || t.nombre,
         i.created_at,
         coalesce(au.email::text, case when i.created_by is null then null else i.created_by::text end)
  from competencias.inscripcion_lbf i
  join competencias.equipo e on e.id = i.equipo_id
  join competencias.club cl  on cl.id = e.club_id
  join competencias.categoria c on c.id = i.categoria_id
  join competencias.torneo t on t.id = c.torneo_id
  left join auth.users au on au.id = i.created_by
  where i.jugador_id = p_jugador and (select ok from permiso)
  order by 4
$$;
revoke execute on function competencias.quien_registro(uuid) from public, anon;
grant  execute on function competencias.quien_registro(uuid) to authenticated;

notify pgrst, 'reload schema';

-- Verificación: columnas y triggers creados
select 'jugador_maestro.created_by' as objeto,
       count(*) as existe from information_schema.columns
where table_schema='competencias' and table_name='jugador_maestro' and column_name='created_by'
union all
select 'inscripcion_lbf.created_by', count(*) from information_schema.columns
where table_schema='competencias' and table_name='inscripcion_lbf' and column_name='created_by'
union all
select 'triggers', count(*) from pg_trigger
where tgname in ('t_sellar_jugador','t_sellar_inscripcion');
