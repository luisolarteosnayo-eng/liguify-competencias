-- ============================================================================
-- 🎓 TARJETAS DEL COMANDO TÉCNICO POR PARTIDO
-- El CT (entrenador, asistente, etc.) puede recibir amarillas y rojas en un
-- partido. Se cargan desde CARGAR RESULTADO y figuran en la planilla impresa.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create table if not exists competencias.planilla_ct(
  partido_id uuid not null references competencias.partido(id) on delete cascade,
  ct_id      uuid not null references competencias.comando_tecnico(id) on delete cascade,
  amarillas  int not null default 0,
  rojas      int not null default 0,
  primary key (partido_id, ct_id)
);

alter table competencias.planilla_ct enable row level security;
drop policy if exists pct_sel on competencias.planilla_ct;
drop policy if exists pct_mod on competencias.planilla_ct;

-- lectura pública (el detalle del partido podría mostrarlas a futuro)
create policy pct_sel on competencias.planilla_ct for select using (true);
-- escritura: solo staff de la marca del torneo del partido
create policy pct_mod on competencias.planilla_ct for all to authenticated
  using (exists (select 1 from competencias.partido p
                 join competencias.categoria c on c.id = p.categoria_id
                 join competencias.torneo t on t.id = c.torneo_id
                 where p.id = partido_id and competencias.es_staff_marca(t.marca_id)))
  with check (exists (select 1 from competencias.partido p
                 join competencias.categoria c on c.id = p.categoria_id
                 join competencias.torneo t on t.id = c.torneo_id
                 where p.id = partido_id and competencias.es_staff_marca(t.marca_id)));

grant select on competencias.planilla_ct to anon, authenticated;
grant insert, update, delete on competencias.planilla_ct to authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'tabla planilla_ct' as objeto, count(*)::text as existe
from information_schema.tables where table_schema='competencias' and table_name='planilla_ct';
