-- ============================================================================
-- 🟥 SUSPENSIONES POR TARJETA ROJA — SIN TRIGGER (proceso de revisión)
--  Flujo operativo:
--   1) Terminada la fecha, el staff abre 📊 REPORTES → TARJETAS Y SUSPENSIONES,
--      elige la fecha y pulsa GENERAR SUSPENSIONES: cada roja de esa fecha crea
--      su suspensión con 1 fecha por defecto (las ya existentes no se duplican).
--   2) En esa misma revisión el ADMIN ajusta el N° de fechas (faltas graves)
--      o elimina una suspensión si corresponde.
--   3) La validación de jugadores muestra ⛔ SUSPENDIDO y no deja grabar
--      asistencia mientras cumple la sanción.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create table if not exists competencias.suspension(
  id uuid primary key default gen_random_uuid(),
  inscripcion_id uuid not null references competencias.inscripcion_lbf(id) on delete cascade,
  partido_id uuid not null references competencias.partido(id) on delete cascade,
  fechas int not null default 1 check (fechas between 1 and 99),
  motivo text not null default 'Tarjeta roja',
  origen text not null default 'revision' check (origen in ('revision','manual')),
  created_at timestamptz not null default now(),
  updated_by uuid,
  unique(inscripcion_id, partido_id)
);

-- Marca (empresa) dueña del torneo de una inscripción — para las policies
create or replace function competencias.marca_de_inscripcion(p_ins uuid)
returns uuid language sql stable security definer
set search_path = competencias, public as $$
  select t.marca_id
  from competencias.inscripcion_lbf i
  join competencias.categoria c on c.id = i.categoria_id
  join competencias.torneo t on t.id = c.torneo_id
  where i.id = p_ins
$$;

alter table competencias.suspension enable row level security;
drop policy if exists susp_sel on competencias.suspension;
drop policy if exists susp_ins on competencias.suspension;
drop policy if exists susp_upd on competencias.suspension;
drop policy if exists susp_del on competencias.suspension;

-- staff de la marca (admin + mesa) ve; el CLUB solo VE las de sus equipos;
-- crear/ampliar/eliminar: staff de la marca
create policy susp_sel on competencias.suspension for select to authenticated
  using ( competencias.es_staff_marca(competencias.marca_de_inscripcion(inscripcion_id))
       or exists (select 1 from competencias.inscripcion_lbf i
                  where i.id = inscripcion_id and competencias.gestiona_equipo(i.equipo_id)) );
create policy susp_ins on competencias.suspension for insert to authenticated
  with check ( competencias.es_staff_marca(competencias.marca_de_inscripcion(inscripcion_id)) );
create policy susp_upd on competencias.suspension for update to authenticated
  using ( competencias.es_staff_marca(competencias.marca_de_inscripcion(inscripcion_id)) );
create policy susp_del on competencias.suspension for delete to authenticated
  using ( competencias.es_staff_marca(competencias.marca_de_inscripcion(inscripcion_id)) );
grant select, insert, update, delete on competencias.suspension to authenticated;

-- PROCESO DE REVISIÓN: genera las suspensiones de las rojas de UNA fecha del
-- torneo (1 fecha por defecto). Idempotente: no duplica ni pisa ajustes.
create or replace function competencias.generar_suspensiones_fecha(p_torneo uuid, p_numero int)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_marca uuid; v_nuevas int; v_rojas int;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null then raise exception 'Torneo no encontrado'; end if;
  if not competencias.es_staff_marca(v_marca) then
    raise exception 'Solo el staff del torneo puede generar suspensiones';
  end if;
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
  return jsonb_build_object('ok', true, 'rojas', v_rojas, 'nuevas', v_nuevas,
                            'existentes', v_rojas - v_nuevas);
end $$;
revoke execute on function competencias.generar_suspensiones_fecha(uuid,int) from public, anon;
grant  execute on function competencias.generar_suspensiones_fecha(uuid,int) to authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN: objetos creados
select 'tabla suspension' as objeto, count(*)::text as detalle from competencias.suspension
union all
select 'rpc generar_suspensiones_fecha', count(*)::text
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='competencias' and p.proname='generar_suspensiones_fecha';
