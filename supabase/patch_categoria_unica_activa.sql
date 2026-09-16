-- ============================================================================
-- 🔑 UNICIDAD DE CATEGORÍA SOLO ENTRE ACTIVAS
-- La llave UNIQUE (torneo, año, modalidad) pasa a ser un índice único PARCIAL
-- que solo aplica a categorías ACTIVAS: una categoría inactivada deja de
-- bloquear la llave (puedes editar otra hacia ese año/modalidad). Reactivar
-- una que choque con una activa sigue rechazándose.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

do $$
declare r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    join pg_class t on t.oid = con.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname='competencias' and t.relname='categoria' and con.contype='u'
  loop
    execute format('alter table competencias.categoria drop constraint %I', r.conname);
    raise notice 'Constraint eliminado: %', r.conname;
  end loop;
end $$;

create unique index if not exists categoria_unica_activa
  on competencias.categoria(torneo_id, anio_nacimiento, modalidad)
  where activa;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'indice categoria_unica_activa' as objeto, count(*)::text as existe
from pg_indexes where schemaname='competencias' and indexname='categoria_unica_activa';
