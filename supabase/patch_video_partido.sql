-- ============================================================================
-- VIDEO DEL PARTIDO: URL (YouTube u otro) por partido, cargada por el ADMIN
-- en CARGAR RESULTADO y visible para todos en el detalle del partido del
-- público y del club (queda enlazada al historial de partidos).
-- La tabla partido ya tiene select para anon y escritura staff por RLS.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.partido add column if not exists video_url text;

notify pgrst, 'reload schema';
