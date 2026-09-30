-- ============================================================================
-- 💰 COBRANZAS v2 · FIX DE DUPLICACIÓN POR ORGANIZACIÓN
-- Varias marcas (INTI CUP, NOVA CUP, IDV LIMA) pueden apuntar a LA MISMA
-- organización del ERP, y un club (TALES) existe en cada marca con el mismo
-- erp_club_id → el saldo salía repetido una vez por marca.
-- La cuenta corriente es de la EMPRESA (organización ERP), no de la marca:
--  · mi_saldo_erp: una sola fila por (organización, club ERP, torneo ERP),
--    con el nombre de la EMPRESA para el encabezado.
--  · cobranzas_pendientes: UNA sola marca "cobradora" por organización
--    (la más antigua con cobranza activa) y dedupe del aviso por club ERP
--    global (ya no por marca) → un solo correo por club por semana.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

drop function if exists competencias.mi_saldo_erp();
create or replace function competencias.mi_saldo_erp()
returns table(empresa text, club text, torneo text,
              cargos numeric, abonos numeric, saldo numeric,
              equipos jsonb, instrucciones text)
language sql security definer stable
set search_path = competencias, public as $$
  select distinct on (mk.erp_org_id, cl.erp_club_id, s.erp_torneo_id)
         o.nombre, cl.nombre, s.torneo, s.cargos, s.abonos, s.saldo, s.equipos,
         (select mk2.cobranza_instrucciones from competencias.marca mk2
          where mk2.erp_org_id = mk.erp_org_id and mk2.cobranza_instrucciones is not null
          order by mk2.created_at limit 1)
  from competencias.usuario_club uc
  join competencias.club  cl on cl.id = uc.club_id and cl.erp_club_id is not null
  join competencias.marca mk on mk.id = cl.marca_id and mk.erp_org_id is not null
  join public.organizaciones o on o.id = mk.erp_org_id
  cross join lateral competencias.erp_saldos(mk.erp_org_id) s
  where uc.usuario_id = auth.uid() and uc.rol = 'coordinador'
    and s.erp_club_id = cl.erp_club_id
  order by mk.erp_org_id, cl.erp_club_id, s.erp_torneo_id
$$;
revoke execute on function competencias.mi_saldo_erp() from public, anon;
grant  execute on function competencias.mi_saldo_erp() to authenticated;

create or replace function competencias.cobranzas_pendientes()
returns table(marca_id uuid, marca text, club_id uuid, erp_club_id bigint,
              club text, email text, cc_email text,
              saldo_total numeric, detalle jsonb, instrucciones text)
language sql security definer stable
set search_path = competencias, public as $$
  with mk1 as (   -- una sola marca "cobradora" por organización ERP (la más antigua activa hoy)
    select distinct on (erp_org_id) id, nombre, erp_org_id,
           cobranza_cc_coordinador, cobranza_min, cobranza_instrucciones
    from competencias.marca
    where cobranza_activa and erp_org_id is not null
      and cobranza_dia = extract(dow from (now() at time zone 'America/Lima'))::int
    order by erp_org_id, created_at
  ),
  clx as (        -- clubes del org, dedupe por erp_club_id entre TODAS las marcas del org
    select distinct on (mk1.erp_org_id, cl.erp_club_id)
           mk1.id as marca_id, mk1.nombre as marca, mk1.erp_org_id,
           cl.id as club_id, cl.erp_club_id, cl.nombre as club,
           nullif(trim(cl.contacto_email),'') as email_comp,
           mk1.cobranza_cc_coordinador, mk1.cobranza_min, mk1.cobranza_instrucciones
    from mk1
    join competencias.marca mall on mall.erp_org_id = mk1.erp_org_id
    join competencias.club cl on cl.marca_id = mall.id and cl.erp_club_id is not null
    order by mk1.erp_org_id, cl.erp_club_id, (nullif(trim(cl.contacto_email),'') is null)
  ),
  base as (
    select clx.*, s.torneo, s.cargos, s.abonos, s.saldo, s.equipos, s.club_email
    from clx
    cross join lateral competencias.erp_saldos(clx.erp_org_id) s
    where s.erp_club_id = clx.erp_club_id
  )
  select b.marca_id, b.marca, b.club_id, b.erp_club_id, b.club,
         coalesce(b.email_comp, b.club_email) as email,
         case when b.cobranza_cc_coordinador then
           (select up.email from competencias.usuario_club uc
            join competencias.usuario_perfil up on up.id = uc.usuario_id
            where uc.club_id = b.club_id and uc.rol = 'coordinador' limit 1) end,
         sum(b.saldo),
         jsonb_agg(jsonb_build_object('torneo',b.torneo,'cargos',b.cargos,
           'abonos',b.abonos,'saldo',b.saldo,'equipos',b.equipos) order by b.torneo),
         min(b.cobranza_instrucciones)
  from base b
  where coalesce(b.email_comp, b.club_email) is not null
  group by b.marca_id, b.marca, b.club_id, b.erp_club_id, b.club,
           coalesce(b.email_comp, b.club_email), b.cobranza_cc_coordinador, b.cobranza_min
  having sum(b.saldo) >= min(b.cobranza_min)
     and not exists (select 1 from competencias.cobranza_aviso a
                     where a.erp_club_id = b.erp_club_id
                       and a.enviado_at > now() - interval '6 days')
$$;
revoke execute on function competencias.cobranzas_pendientes() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- VERIFICACIÓN: mi_saldo_erp ahora devuelve columna "empresa"
select p.proname, pg_get_function_result(p.oid) like '%empresa%' as con_empresa
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='competencias' and p.proname in ('mi_saldo_erp','cobranzas_pendientes');
