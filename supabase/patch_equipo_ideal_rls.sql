-- equipo_ideal: recrear políticas RLS de forma robusta
-- (el insert fallaba con "new row violates row-level security policy")
create or replace function competencias.staff_de_jornada(p_jornada uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select coalesce(
    (select competencias.es_staff_marca(competencias.marca_de_categoria(j.categoria_id))
     from competencias.jornada j where j.id = p_jornada), false)
$$;
revoke execute on function competencias.staff_de_jornada(uuid) from public, anon;
grant  execute on function competencias.staff_de_jornada(uuid) to authenticated;

alter table competencias.equipo_ideal enable row level security;
drop policy if exists ei_read  on competencias.equipo_ideal;
drop policy if exists ei_write on competencias.equipo_ideal;
create policy ei_read  on competencias.equipo_ideal for select using (true);
create policy ei_write on competencias.equipo_ideal for all
  using (competencias.staff_de_jornada(jornada_id))
  with check (competencias.staff_de_jornada(jornada_id));

grant select on competencias.equipo_ideal to anon, authenticated;
grant insert, update, delete on competencias.equipo_ideal to authenticated;

drop trigger if exists t_sellar_equipo_ideal on competencias.equipo_ideal;
create trigger t_sellar_equipo_ideal before insert on competencias.equipo_ideal
for each row execute function competencias.sellar_created_by();

notify pgrst, 'reload schema';

-- Verificación: deben salir las 2 políticas
select policyname, cmd, coalesce(qual, with_check) as condicion
from pg_policies where schemaname = 'competencias' and tablename = 'equipo_ideal'
order by policyname;
