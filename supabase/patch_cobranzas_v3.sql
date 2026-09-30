-- ============================================================================
-- 💰 COBRANZAS v3 · ENVÍO MANUAL DESDE EL ERP (Cuentas por Cobrar)
-- Decisión: el correo de cobranza NO es automático — el organizador entra a
-- Cuentas por Cobrar en el ERP, SELECCIONA los cobros (club+torneo) y envía
-- el estado de cuenta solo a los seleccionados.
--  · cobranza_datos(p_org, p_items): datos del correo para los cobros
--    seleccionados; el que llama debe pertenecer a la organización del ERP.
--  · Se elimina el modo automático (cobranzas_pendientes + columnas de
--    activación/día/mínimo). Se conservan: instrucciones de pago y CC al
--    coordinador (se configuran en Competencias → EDITAR MARCA).
--  · El banner del módulo CLUB (mi_saldo_erp) no cambia.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Fuera el modo automático
drop function if exists competencias.cobranzas_pendientes();
alter table competencias.marca
  drop column if exists cobranza_activa,
  drop column if exists cobranza_dia,
  drop column if exists cobranza_min;
-- el log puede existir sin marca (org sin marca vinculada)
alter table competencias.cobranza_aviso alter column marca_id drop not null;

-- 2) Datos del correo para los cobros SELECCIONADOS (lo llama la Edge Function
--    con el token del usuario del ERP; el permiso se valida aquí)
create or replace function competencias.cobranza_datos(p_org bigint, p_items jsonb)
returns table(marca_id uuid, empresa text, erp_club_id bigint, club_id uuid,
              club text, email text, cc_email text,
              saldo_total numeric, detalle jsonb, instrucciones text)
language sql security definer stable
set search_path = competencias, public as $$
  with perm as (
    select 1 from public.organizaciones o
    where o.id = p_org
      and (o.owner_user_id = auth.uid()
           or exists (select 1 from public.profiles pr
                      where pr.id = auth.uid() and pr.org_id = o.id and pr.activo))
  ),
  it as (
    select (x->>'club_id')::bigint as club_id, (x->>'torneo_id')::bigint as torneo_id
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x
  ),
  mk as (   -- marca de referencia del org (instrucciones, CC y log)
    select m.id, m.cobranza_cc_coordinador,
           (select m2.cobranza_instrucciones from competencias.marca m2
            where m2.erp_org_id = p_org and m2.cobranza_instrucciones is not null
            order by m2.created_at limit 1) as instrucciones
    from competencias.marca m where m.erp_org_id = p_org
    order by m.created_at limit 1
  ),
  sel as (
    select s.* from competencias.erp_saldos(p_org) s
    join it on it.club_id = s.erp_club_id and it.torneo_id = s.erp_torneo_id
    where exists (select 1 from perm)
  ),
  ccl as (   -- club de Competencias vinculado (email alternativo + coordinador)
    select distinct on (cl.erp_club_id) cl.erp_club_id, cl.id as comp_club_id,
           nullif(trim(cl.contacto_email),'') as email_comp
    from competencias.club cl
    join competencias.marca m on m.id = cl.marca_id and m.erp_org_id = p_org
    where cl.erp_club_id is not null
    order by cl.erp_club_id, (nullif(trim(cl.contacto_email),'') is null)
  )
  select (select id from mk),
         (select o.nombre from public.organizaciones o where o.id = p_org),
         s.erp_club_id, c.comp_club_id, s.club_nombre,
         coalesce(c.email_comp, nullif(trim(s.club_email),'')),
         case when (select cobranza_cc_coordinador from mk) then
           (select up.email from competencias.usuario_club uc
            join competencias.usuario_perfil up on up.id = uc.usuario_id
            where uc.club_id = c.comp_club_id and uc.rol = 'coordinador' limit 1) end,
         sum(s.saldo),
         jsonb_agg(jsonb_build_object('torneo',s.torneo,'cargos',s.cargos,
           'abonos',s.abonos,'saldo',s.saldo,'equipos',s.equipos) order by s.torneo),
         (select instrucciones from mk)
  from sel s
  left join ccl c on c.erp_club_id = s.erp_club_id
  group by s.erp_club_id, c.comp_club_id, s.club_nombre,
           coalesce(c.email_comp, nullif(trim(s.club_email),''))
$$;
revoke execute on function competencias.cobranza_datos(bigint,jsonb) from public, anon;
grant  execute on function competencias.cobranza_datos(bigint,jsonb) to authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'cobranza_datos' as objeto, count(*)::text as existe from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='competencias' and p.proname='cobranza_datos'
union all
select 'cobranzas_pendientes (eliminada)', count(*)::text from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='competencias' and p.proname='cobranzas_pendientes'
union all
select 'config marca (quedan 2)', count(*)::text from information_schema.columns
  where table_schema='competencias' and table_name='marca' and column_name like 'cobranza%';
