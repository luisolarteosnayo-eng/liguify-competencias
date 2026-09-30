-- ============================================================================
-- 💰 COBRANZAS v7 · EL CORREO LLEVA EL ESTADO DE CUENTA COMPLETO DEL CLUB
-- La selección en Cuentas por Cobrar decide A QUÉ CLUBES se les envía; el
-- correo incluye TODOS los torneos con deuda del club (no solo la fila
-- marcada). Destinatarios (v6): coordinador + email del club, sin duplicar.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

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
    select distinct (x->>'club_id')::bigint as club_id
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x
  ),
  mk as (
    select m.id,
           (select m2.cobranza_instrucciones from competencias.marca m2
            where m2.erp_org_id = p_org and m2.cobranza_instrucciones is not null
            order by m2.created_at limit 1) as instrucciones
    from competencias.marca m where m.erp_org_id = p_org
    order by m.created_at limit 1
  ),
  sel as (   -- TODOS los torneos con deuda de los clubes seleccionados
    select s.* from competencias.erp_saldos(p_org) s
    where exists (select 1 from perm)
      and s.erp_club_id in (select club_id from it)
      and s.saldo > 0
  ),
  ccl as (
    select distinct on (cl.erp_club_id) cl.erp_club_id, cl.id as comp_club_id,
           nullif(trim(cl.contacto_email),'') as email_comp,
           (select up.email from competencias.usuario_club uc
            join competencias.usuario_perfil up on up.id = uc.usuario_id
            where uc.club_id = cl.id and uc.rol = 'coordinador' limit 1) as coord_email
    from competencias.club cl
    join competencias.marca m on m.id = cl.marca_id and m.erp_org_id = p_org
    where cl.erp_club_id is not null
    order by cl.erp_club_id, (nullif(trim(cl.contacto_email),'') is null)
  )
  select (select id from mk),
         (select o.nombre from public.organizaciones o where o.id = p_org),
         s.erp_club_id, c.comp_club_id, s.club_nombre,
         coalesce(c.coord_email, nullif(trim(s.club_email),''), c.email_comp),
         coalesce(nullif(trim(s.club_email),''), c.email_comp),
         sum(s.saldo),
         jsonb_agg(jsonb_build_object('torneo',s.torneo,'cargos',s.cargos,
           'abonos',s.abonos,'saldo',s.saldo,'equipos',s.equipos) order by s.torneo),
         (select instrucciones from mk)
  from sel s
  left join ccl c on c.erp_club_id = s.erp_club_id
  group by s.erp_club_id, c.comp_club_id, s.club_nombre,
           c.email_comp, nullif(trim(s.club_email),''), c.coord_email
$$;
revoke execute on function competencias.cobranza_datos(bigint,jsonb) from public, anon;
grant  execute on function competencias.cobranza_datos(bigint,jsonb) to authenticated;

notify pgrst, 'reload schema';
