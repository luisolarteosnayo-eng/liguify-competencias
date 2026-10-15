-- ============================================================================
-- 🟥🎓 SUSPENSIONES DEL COMANDO TÉCNICO
-- Las rojas del CT (planilla_ct, cargadas en CARGAR RESULTADO) no entraban al
-- proceso de revisión: el reporte y generar_suspensiones_fecha solo leían la
-- planilla de jugadores. Este patch:
--  1) Crea suspension_ct (espejo de suspension, apuntando a comando_tecnico).
--  2) Extiende generar_suspensiones_fecha para generar también las del CT.
--  3) La validación del carnet CT mostrará ⛔ SUSPENDIDO (cambio de frontend).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create table if not exists competencias.suspension_ct(
  id uuid primary key default gen_random_uuid(),
  ct_id uuid not null references competencias.comando_tecnico(id) on delete cascade,
  partido_id uuid not null references competencias.partido(id) on delete cascade,
  fechas int not null default 1 check (fechas between 1 and 99),
  motivo text not null default 'Tarjeta roja',
  origen text not null default 'revision' check (origen in ('revision','manual')),
  created_at timestamptz not null default now(),
  updated_by uuid,
  unique(ct_id, partido_id)
);

create or replace function competencias.marca_de_ct(p_ct uuid)
returns uuid language sql stable security definer
set search_path = competencias, public as $$
  select t.marca_id
  from competencias.comando_tecnico ct
  join competencias.categoria c on c.id = ct.categoria_id
  join competencias.torneo t on t.id = c.torneo_id
  where ct.id = p_ct
$$;

alter table competencias.suspension_ct enable row level security;
drop policy if exists suspct_sel on competencias.suspension_ct;
drop policy if exists suspct_ins on competencias.suspension_ct;
drop policy if exists suspct_upd on competencias.suspension_ct;
drop policy if exists suspct_del on competencias.suspension_ct;
create policy suspct_sel on competencias.suspension_ct for select to authenticated
  using ( competencias.es_staff_marca(competencias.marca_de_ct(ct_id))
       or exists (select 1 from competencias.comando_tecnico x
                  where x.id = ct_id and competencias.gestiona_equipo(x.equipo_id)) );
create policy suspct_ins on competencias.suspension_ct for insert to authenticated
  with check ( competencias.es_staff_marca(competencias.marca_de_ct(ct_id)) );
create policy suspct_upd on competencias.suspension_ct for update to authenticated
  using ( competencias.es_staff_marca(competencias.marca_de_ct(ct_id)) );
create policy suspct_del on competencias.suspension_ct for delete to authenticated
  using ( competencias.es_staff_marca(competencias.marca_de_ct(ct_id)) );
grant select, insert, update, delete on competencias.suspension_ct to authenticated;

-- RPC: ahora genera las suspensiones de JUGADORES y del COMANDO TÉCNICO
create or replace function competencias.generar_suspensiones_fecha(p_torneo uuid, p_numero int)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_marca uuid; v_nuevas int; v_rojas int; v_rojas_ct int; v_nuevas_ct int;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null then raise exception 'Torneo no encontrado'; end if;
  if not competencias.es_staff_marca(v_marca) then
    raise exception 'Solo el staff del torneo puede generar suspensiones';
  end if;

  -- jugadores
  select count(*) into v_rojas
  from competencias.planilla_partido pl
  join competencias.partido pa on pa.id = pl.partido_id
  join competencias.jornada jo on jo.id = pa.jornada_id and jo.numero = p_numero
  join competencias.categoria c on c.id = pa.categoria_id and c.torneo_id = p_torneo
  where coalesce(pl.rojas,0) > 0;

  insert into competencias.suspension(inscripcion_id, partido_id, updated_by)
  select pl.inscripcion_id, pl.partido_id, auth.uid()
  from competencias.planilla_partido pl
  join competencias.partido pa on pa.id = pl.partido_id
  join competencias.jornada jo on jo.id = pa.jornada_id and jo.numero = p_numero
  join competencias.categoria c on c.id = pa.categoria_id and c.torneo_id = p_torneo
  where coalesce(pl.rojas,0) > 0
  on conflict (inscripcion_id, partido_id) do nothing;
  get diagnostics v_nuevas = row_count;

  -- comando técnico
  select count(*) into v_rojas_ct
  from competencias.planilla_ct pc
  join competencias.partido pa on pa.id = pc.partido_id
  join competencias.jornada jo on jo.id = pa.jornada_id and jo.numero = p_numero
  join competencias.categoria c on c.id = pa.categoria_id and c.torneo_id = p_torneo
  where coalesce(pc.rojas,0) > 0;

  insert into competencias.suspension_ct(ct_id, partido_id, updated_by)
  select pc.ct_id, pc.partido_id, auth.uid()
  from competencias.planilla_ct pc
  join competencias.partido pa on pa.id = pc.partido_id
  join competencias.jornada jo on jo.id = pa.jornada_id and jo.numero = p_numero
  join competencias.categoria c on c.id = pa.categoria_id and c.torneo_id = p_torneo
  where coalesce(pc.rojas,0) > 0
  on conflict (ct_id, partido_id) do nothing;
  get diagnostics v_nuevas_ct = row_count;

  return jsonb_build_object('ok', true,
    'rojas', v_rojas, 'nuevas', v_nuevas, 'existentes', v_rojas - v_nuevas,
    'rojas_ct', v_rojas_ct, 'nuevas_ct', v_nuevas_ct, 'existentes_ct', v_rojas_ct - v_nuevas_ct);
end $$;
revoke execute on function competencias.generar_suspensiones_fecha(uuid,int) from public, anon;
grant  execute on function competencias.generar_suspensiones_fecha(uuid,int) to authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'tabla suspension_ct' as objeto, count(*)::text as detalle
from information_schema.tables where table_schema='competencias' and table_name='suspension_ct'
union all
select 'rpc generar_suspensiones_fecha (con CT)',
       (pg_get_functiondef(p.oid) like '%suspension_ct%')::text
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='competencias' and p.proname='generar_suspensiones_fecha';
