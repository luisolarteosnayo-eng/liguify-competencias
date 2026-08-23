-- Reaplicar permisos de equipo_ideal (la lectura pública salía denegada)
grant usage on schema competencias to anon, authenticated;
grant select on competencias.equipo_ideal to anon, authenticated;
grant insert, update, delete on competencias.equipo_ideal to authenticated;
notify pgrst, 'reload schema';

-- Verificación: privilegios efectivos por rol
select grantee, string_agg(privilege_type, ', ' order by privilege_type) as privilegios
from information_schema.role_table_grants
where table_schema = 'competencias' and table_name = 'equipo_ideal'
group by grantee order by grantee;
