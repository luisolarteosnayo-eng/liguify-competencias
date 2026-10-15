-- ============================================================================
-- ⛔ SANCIÓN DE JUGADOR POR MARCA (suplantación, deudas, indisciplina…)
-- El ADMIN la define desde la LBF (botón ⛔ del jugador). Aplica a TODA la
-- marca (todos sus torneos), por un plazo definido o indefinido:
--   vigente = desde ≤ hoy ≤ hasta (hasta NULL = indefinida, hasta levantarla).
-- La validación en cancha muestra ⛔ SANCIONADO POR LA ORGANIZACIÓN y no
-- permite grabar asistencia. Distinta de sancion_global (plataforma, solo
-- super-admin) y de las suspensiones por roja (por N fechas).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create table if not exists competencias.sancion_marca(
  id             uuid primary key default gen_random_uuid(),
  marca_id       uuid not null references competencias.marca(id) on delete cascade,
  jugador_id     uuid not null references competencias.jugador_maestro(id) on delete cascade,
  motivo         text not null,
  vigencia_desde date not null default current_date,
  vigencia_hasta date,                    -- null = indefinida
  emitida_por    uuid,
  levantada_por  uuid,                    -- auditoría si se levanta antes del plazo
  levantada_at   timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists sancion_marca_jug on competencias.sancion_marca(marca_id, jugador_id);

alter table competencias.sancion_marca enable row level security;
drop policy if exists sm_sel on competencias.sancion_marca;
drop policy if exists sm_ins on competencias.sancion_marca;
drop policy if exists sm_upd on competencias.sancion_marca;
drop policy if exists sm_del on competencias.sancion_marca;
-- lee el staff (admin + mesa, para la validación); escribe SOLO el admin
create policy sm_sel on competencias.sancion_marca for select to authenticated
  using ( competencias.es_staff_marca(marca_id) );
create policy sm_ins on competencias.sancion_marca for insert to authenticated
  with check ( competencias.es_admin_marca(marca_id) );
create policy sm_upd on competencias.sancion_marca for update to authenticated
  using ( competencias.es_admin_marca(marca_id) );
create policy sm_del on competencias.sancion_marca for delete to authenticated
  using ( competencias.es_admin_marca(marca_id) );
grant select, insert, update, delete on competencias.sancion_marca to authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'tabla sancion_marca' as objeto, count(*)::text as existe
from information_schema.tables
where table_schema='competencias' and table_name='sancion_marca';
