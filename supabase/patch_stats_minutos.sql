-- ============================================================================
-- ESTADÍSTICAS POR JUGADOR: minutos jugados y asistencias por partido, y
-- duración del partido configurable por torneo (para % participación y
-- métricas por-90'). Se capturan en CARGAR RESULTADO (admin) y se muestran
-- agregadas en el plantel del módulo Club.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.torneo
  add column if not exists duracion_partido int not null default 90;  -- minutos

alter table competencias.planilla_partido
  add column if not exists minutos     int not null default 0,
  add column if not exists asistencias int not null default 0;

notify pgrst, 'reload schema';
