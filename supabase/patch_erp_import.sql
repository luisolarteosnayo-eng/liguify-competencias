-- ============================================================================
-- PATCH: IMPORTAR EQUIPOS DESDE LIGUIFY FINANCIERO (ERP) — diseño §12
-- Puente competencias ↔ public (ERP). El ERP es OPCIONAL: marca sin vínculo
-- (erp_org_id null) = cero rastro del ERP en la UI.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Columnas de vínculo (F1)
alter table competencias.marca  add column if not exists erp_org_id    bigint unique;
alter table competencias.club   add column if not exists erp_club_id   bigint unique;
alter table competencias.equipo add column if not exists erp_equipo_id bigint unique;

-- 2) Mis organizaciones del ERP (para el botón "Vincular" de Editar Marca)
create or replace function competencias.erp_orgs_disponibles()
returns table(org_id bigint, nombre text)
language sql security definer stable
set search_path = public, competencias
as $$
  select o.id, o.nombre
  from public.organizaciones o
  where o.owner_user_id = auth.uid()
     or exists (select 1 from public.profiles p
                where p.id = auth.uid() and p.org_id = o.id and p.activo)
  order by o.nombre
$$;

-- 3) Vincular / desvincular marca ↔ organización ERP (p_org null = desvincular)
create or replace function competencias.vincular_erp(p_marca uuid, p_org bigint)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  if p_org is not null and not exists (
      select 1 from public.organizaciones o
      where o.id = p_org
        and (o.owner_user_id = auth.uid()
             or exists (select 1 from public.profiles p
                        where p.id = auth.uid() and p.org_id = o.id and p.activo))
  ) then
    raise exception 'No perteneces a esa organización del ERP';
  end if;
  update competencias.marca set erp_org_id = p_org where id = p_marca;
end $$;

-- 4) Torneos del ERP de la organización vinculada
create or replace function competencias.erp_torneos(p_marca uuid)
returns table(torneo_id bigint, nombre text, estado text, inicio date)
language sql security definer stable
set search_path = public, competencias
as $$
  select t.id, t.nombre, t.estado, t.inicio
  from public.torneos t
  join competencias.marca m on m.erp_org_id = t.org_id
  where m.id = p_marca
    and competencias.es_admin_marca(p_marca)
  order by t.created_at desc
$$;

-- 5) Equipos (inscripciones) de un torneo ERP, con su estado de vínculo
create or replace function competencias.erp_equipos_torneo(p_marca uuid, p_torneo bigint)
returns table(erp_equipo_id bigint, erp_club_id bigint, club_nombre text,
              delegado text, telefono text, categoria text, modalidad text,
              sub_nombre text, estado text, invitado boolean,
              ya_importado boolean, club_vinculado boolean, club_adoptable boolean)
language sql security definer stable
set search_path = public, competencias
as $$
  select e.id, c.id, c.nombre, c.delegado, c.telefono,
         cat.nombre,
         coalesce(nullif(e.modalidad,''),
                  (select tc.modalidad from public.torneo_categorias tc
                   where tc.torneo_id = e.torneo_id and tc.cat_id = e.cat_id limit 1), ''),
         nullif(trim(e.nombre),''),
         e.estado, e.invitado,
         exists (select 1 from competencias.equipo q where q.erp_equipo_id = e.id),
         exists (select 1 from competencias.club k
                 where k.marca_id = p_marca and k.erp_club_id = c.id),
         exists (select 1 from competencias.club k
                 where k.marca_id = p_marca and k.erp_club_id is null
                   and lower(trim(k.nombre)) = lower(trim(c.nombre)))
  from public.equipos e
  join public.clubes c     on c.id  = e.club_id
  join public.categorias cat on cat.id = e.cat_id
  join competencias.marca m on m.erp_org_id = e.org_id
  where e.torneo_id = p_torneo and m.id = p_marca
    and competencias.es_admin_marca(p_marca)
  order by cat.nombre, c.nombre, e.id
$$;

-- 6) Importar (algoritmo 12.2: reusar → adoptar por nombre → crear; idempotente)
create or replace function competencias.importar_equipos_erp(p_categoria uuid, p_erp_torneo bigint, p_ids bigint[])
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare
  v_marca uuid; v_org bigint; v_club uuid; r record;
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
           c.id as club_id, c.nombre as club_nombre, c.telefono as club_tel
    from public.equipos e
    join public.clubes c on c.id = e.club_id
    where e.torneo_id = p_erp_torneo and e.id = any(p_ids)
  loop
    if exists (select 1 from competencias.equipo q where q.erp_equipo_id = r.eq_id) then
      n_omitidos := n_omitidos + 1; continue;   -- re-importar no duplica
    end if;
    -- 12.2: 1) reusar club ya vinculado
    select id into v_club from competencias.club
    where marca_id = v_marca and erp_club_id = r.club_id;
    if v_club is not null then
      n_reusados := n_reusados + 1;
    else
      -- 2) adoptar por nombre normalizado (cura duplicados en vez de crearlos)
      select id into v_club from competencias.club
      where marca_id = v_marca and erp_club_id is null
        and lower(trim(nombre)) = lower(trim(r.club_nombre))
      limit 1;
      if v_club is not null then
        update competencias.club
        set erp_club_id = r.club_id, contacto_tel = coalesce(contacto_tel, r.club_tel)
        where id = v_club;
        n_adoptados := n_adoptados + 1;
      else
        -- 3) crear
        insert into competencias.club (marca_id, nombre, contacto_tel, erp_club_id)
        values (v_marca, trim(r.club_nombre), r.club_tel, r.club_id)
        returning id into v_club;
        n_creados := n_creados + 1;
      end if;
    end if;
    insert into competencias.equipo (categoria_id, club_id, nombre, erp_equipo_id)
    values (p_categoria, v_club, nullif(trim(coalesce(r.sub_nombre,'')),''), r.eq_id);
    n_eq := n_eq + 1;
  end loop;

  return jsonb_build_object(
    'clubes_creados', n_creados, 'clubes_adoptados', n_adoptados,
    'clubes_reusados', n_reusados, 'equipos_creados', n_eq, 'omitidos', n_omitidos);
end $$;

-- 7) Permisos: solo autenticados (la validación fina la hacen las funciones)
revoke execute on function competencias.erp_orgs_disponibles()                       from public, anon;
revoke execute on function competencias.vincular_erp(uuid,bigint)                    from public, anon;
revoke execute on function competencias.erp_torneos(uuid)                            from public, anon;
revoke execute on function competencias.erp_equipos_torneo(uuid,bigint)              from public, anon;
revoke execute on function competencias.importar_equipos_erp(uuid,bigint,bigint[])   from public, anon;
grant  execute on function competencias.erp_orgs_disponibles()                       to authenticated;
grant  execute on function competencias.vincular_erp(uuid,bigint)                    to authenticated;
grant  execute on function competencias.erp_torneos(uuid)                            to authenticated;
grant  execute on function competencias.erp_equipos_torneo(uuid,bigint)              to authenticated;
grant  execute on function competencias.importar_equipos_erp(uuid,bigint,bigint[])   to authenticated;

notify pgrst, 'reload schema';
