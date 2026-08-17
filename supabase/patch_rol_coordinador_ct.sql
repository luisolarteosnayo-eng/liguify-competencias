-- ============================================================================
-- COMANDO TÉCNICO: nuevo rol "Coordinador"
-- (el rol tiene CHECK en la tabla — se recrea la constraint con el rol nuevo)
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.comando_tecnico drop constraint if exists comando_tecnico_rol_check;
alter table competencias.comando_tecnico add constraint comando_tecnico_rol_check
  check (rol in ('Entrenador','Asistente Técnico','Preparador físico','Preparador de arqueros','Médico','Coordinador'));

notify pgrst, 'reload schema';
