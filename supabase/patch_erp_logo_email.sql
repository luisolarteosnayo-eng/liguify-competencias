-- ============================================================================
-- IMPORTAR DEL ERP: traer también LOGO y EMAIL del club.
-- Regla: si el club de Competencias YA tiene escudo/email/teléfono, NO se
-- sobrescribe (solo se completan los campos vacíos). Requiere haber ejecutado
-- antes el patch del ERP (public.clubes.email / logo_url).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.importar_equipos_erp(p_categoria uuid, p_erp_torneo bigint, p_ids bigint[])
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare
  v_marca uuid; v_org bigint; v_club uuid; v_link bigint; v_creado boolean; r record;
  v_email text;
  n_reusados int := 0; n_adoptados int := 0; n_creados int := 0;
  n_eq int := 0; n_omitidos int := 0;
begin
  v_marca := competencias.marca_de_categoria(p_categoria);
  if v_marca is null or not competencias.es_admin_marca(v_marca) then
    raise exception 'Sin permiso sobre esta categoría';
  end if;
  select erp_org_id into v_org from competencias.marca where id = v_marca;
  if v_org is null then
    raise exception 'La marca no está vinculada al ERP';
  end if;
  if not exists (select 1 from public.torneos t where t.id = p_erp_torneo and t.org_id = v_org) then
    raise exception 'Ese torneo no pertenece a tu organización del ERP';
  end if;

  for r in
    select e.id as eq_id, e.nombre as sub_nombre,
           c.id as club_id, c.nombre as club_nombre, c.telefono as club_tel,
           c.email as club_email, c.logo_url as club_logo
    from public.equipos e
    join public.clubes c on c.id = e.club_id
    where e.torneo_id = p_erp_torneo and e.id = any(p_ids)
  loop
    if exists (select 1 from competencias.equipo q
               join competencias.categoria cc on cc.id = q.categoria_id
               join competencias.torneo tt on tt.id = cc.torneo_id
               where tt.marca_id = v_marca and q.erp_equipo_id = r.eq_id) then
      n_omitidos := n_omitidos + 1; continue;   -- re-importar no duplica (dentro de la marca)
    end if;
    v_creado := false;
    v_email  := nullif(trim(coalesce(r.club_email,'')),'');
    -- 1) reusar club ya vinculado a ESTE club del ERP
    select id into v_club from competencias.club
    where marca_id = v_marca and erp_club_id = r.club_id;
    if v_club is not null then
      n_reusados := n_reusados + 1;
    else
      -- 2) mismo nombre en la marca → USARLO SIEMPRE (el club es único por marca).
      select id, erp_club_id into v_club, v_link from competencias.club
      where marca_id = v_marca
        and lower(trim(nombre)) = lower(trim(r.club_nombre))
      limit 1;
      if v_club is not null then
        if v_link is null then
          update competencias.club set erp_club_id = r.club_id where id = v_club;
          n_adoptados := n_adoptados + 1;
        else
          n_reusados := n_reusados + 1;
        end if;
      else
        -- 3) crear: trae logo, email y teléfono del ERP
        insert into competencias.club (marca_id, nombre, contacto_tel, contacto_email, escudo_url, erp_club_id)
        values (v_marca, trim(r.club_nombre), r.club_tel, v_email, r.club_logo, r.club_id)
        returning id into v_club;
        n_creados := n_creados + 1;
        v_creado := true;
      end if;
    end if;
    -- Club existente: completar SOLO los campos vacíos (nunca sobrescribir)
    if not v_creado then
      update competencias.club set
        escudo_url     = coalesce(escudo_url, r.club_logo),
        contacto_email = coalesce(contacto_email, v_email),
        contacto_tel   = coalesce(contacto_tel, r.club_tel)
      where id = v_club
        and ( (escudo_url is null and r.club_logo is not null)
           or (contacto_email is null and v_email is not null)
           or (contacto_tel is null and r.club_tel is not null) );
    end if;
    insert into competencias.equipo (categoria_id, club_id, nombre, erp_equipo_id)
    values (p_categoria, v_club, nullif(trim(coalesce(r.sub_nombre,'')),''), r.eq_id);
    n_eq := n_eq + 1;
  end loop;

  return jsonb_build_object(
    'clubes_creados', n_creados, 'clubes_adoptados', n_adoptados,
    'clubes_reusados', n_reusados, 'equipos_creados', n_eq, 'omitidos', n_omitidos);
end $$;

notify pgrst, 'reload schema';
