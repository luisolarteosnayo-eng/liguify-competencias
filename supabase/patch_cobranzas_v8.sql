-- ============================================================================
-- 💰 COBRANZAS v8 · FIX: coordinador buscado en TODAS las fichas del club
-- Un club (TALES) existe en varias marcas con el mismo erp_club_id; el
-- coordinador está en una sola ficha. v7 elegía una ficha al azar → a veces
-- coord_email salía null y el correo iba solo al email del ERP. v8 agrega
-- todas las fichas del org: coordinador = primer no-nulo entre ellas.
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
  sel as (
    select s.* from competencias.erp_saldos(p_org) s
    where exists (select 1 from perm)
      and s.erp_club_id in (select club_id from it)
      and s.saldo > 0
  ),
  ccl as (
    select cl.erp_club_id,
           (array_agg(cl.id order by (ce.coord_email is null), cl.id))[1] as comp_club_id,
           (array_agg(nullif(trim(cl.contacto_email),''))
              filter (where nullif(trim(cl.contacto_email),'') is not null))[1] as email_comp,
           (array_agg(ce.coord_email)
              filter (where ce.coord_email is not null))[1] as coord_email
    from competencias.club cl
    join competencias.marca m on m.id = cl.marca_id and m.erp_org_id = p_org
    left join lateral (
      select up.email as coord_email
      from competencias.usuario_club uc
      join competencias.usuario_perfil up on up.id = uc.usuario_id
      where uc.club_id = cl.id and uc.rol = 'coordinador'
      order by up.email limit 1
    ) ce on true
    where cl.erp_club_id is not null
    group by cl.erp_club_id
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
