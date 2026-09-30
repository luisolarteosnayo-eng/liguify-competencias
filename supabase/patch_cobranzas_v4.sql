-- ============================================================================
-- 💰 COBRANZAS v4 · FALLBACK DE EMAIL AL COORDINADOR
-- Caso TALES: el club no tiene email ni en Competencias (contacto_email) ni
-- en el ERP (clubes.email), pero SÍ tiene coordinador con cuenta en el módulo
-- CLUB. Prioridad del destinatario del cobro:
--   1) competencias.club.contacto_email  2) public.clubes.email
--   3) email del COORDINADOR del club (usuario_club rol 'coordinador')
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
    select (x->>'club_id')::bigint as club_id, (x->>'torneo_id')::bigint as torneo_id
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x
  ),
  mk as (
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
  ccl as (   -- club de Competencias vinculado: email propio + email del coordinador
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
         coalesce(c.email_comp, nullif(trim(s.club_email),''), c.coord_email),
         case when (select cobranza_cc_coordinador from mk) then c.coord_email end,
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

-- VERIFICACIÓN + DIAGNÓSTICO: clubes con deuda y QUÉ email se usaría
-- (reemplaza 1 por tu org si tuvieras varias; muestra todos los clubes del org)
select cl.nombre as club,
       nullif(trim(cl.email),'') as email_erp,
       (select nullif(trim(k.contacto_email),'') from competencias.club k
        where k.erp_club_id = cl.id limit 1) as email_competencias,
       (select up.email from competencias.club k
        join competencias.usuario_club uc on uc.club_id = k.id and uc.rol='coordinador'
        join competencias.usuario_perfil up on up.id = uc.usuario_id
        where k.erp_club_id = cl.id limit 1) as email_coordinador
from public.clubes cl
where cl.org_id = (select erp_org_id from competencias.marca
                   where erp_org_id is not null order by created_at limit 1)
order by cl.nombre;
