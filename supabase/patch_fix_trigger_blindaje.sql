-- ============================================================================
-- FIX DE SEGURIDAD: los triggers de blindaje NO existen en la BD (detectado en
-- QA: un delegado pudo cambiar estado/inhabilitado directamente). Se recrean.
-- Las funciones ya están actualizadas (incluyen la vía de autorización).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

drop trigger if exists t_proteger_lbf on competencias.inscripcion_lbf;
create trigger t_proteger_lbf before update on competencias.inscripcion_lbf
for each row execute function competencias.proteger_lbf_estado();

drop trigger if exists t_proteger_ct on competencias.comando_tecnico;
create trigger t_proteger_ct before update on competencias.comando_tecnico
for each row execute function competencias.proteger_ct_estado();

notify pgrst, 'reload schema';
