-- ============================================================================
-- DURACIÓN DEL PARTIDO POR CATEGORÍA: cada categoría puede fijar sus minutos
-- (ej. INTI CUP ORO: 40' las menores, 50' las mayores). Si está vacía, hereda
-- torneo.duracion_partido (que pasa a ser el valor por defecto del torneo).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.categoria
  add column if not exists duracion_partido int;   -- null = hereda del torneo

notify pgrst, 'reload schema';
