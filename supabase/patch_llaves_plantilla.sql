-- ============================================================================
-- PATCH: LLAVES CON PLANTILLA (bracket sembrado) — diseño §13
-- El partido puede nacer como PLACEHOLDER: sin equipos, con cupos jsonb
-- ("1º Zona A", "Ganador SF1"). Resolver = asignar los equipos reales.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Equipos nullables (el check local<>visita pasa con nulls en Postgres)
alter table competencias.partido alter column local_id  drop not null;
alter table competencias.partido alter column visita_id drop not null;

-- 2) Cupos: {t:'zona',zona:'A',puesto:1} | {t:'mejor',puesto:3,rank:1}
--          | {t:'ganador'|'perdedor', partido:'<uuid>'}
alter table competencias.partido add column if not exists local_origen  jsonb;
alter table competencias.partido add column if not exists visita_origen jsonb;

-- 3) Un placeholder no puede ponerse en vivo, finalizarse ni darse por walkover
alter table competencias.partido drop constraint if exists partido_estado_equipos_chk;
alter table competencias.partido add constraint partido_estado_equipos_chk
  check (estado in ('programado','suspendido')
         or (local_id is not null and visita_id is not null));

notify pgrst, 'reload schema';
