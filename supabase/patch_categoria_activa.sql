-- ============================================================================
-- 🚫 INACTIVAR CATEGORÍAS DE UN TORNEO
-- El admin puede inactivar una categoría: se oculta del público y deja de
-- contar en KPIs/tabla general del torneo, conservando TODO su historial
-- (fixture, resultados, jugadores). Reactivable en cualquier momento.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.categoria
  add column if not exists activa boolean not null default true;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'columna categoria.activa' as objeto, count(*)::text as existe
from information_schema.columns
where table_schema='competencias' and table_name='categoria' and column_name='activa';
