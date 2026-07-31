-- ============================================================================
-- PATCH: una organización ERP puede vincularse a VARIAS marcas
-- (caso real: una org financiera opera varias marcas, ej. IDV LIMA + INTI CUP)
-- Los vínculos club/equipo y la idempotencia del import pasan a ser POR MARCA.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) marca ↔ org: de 1:1 a N:1
alter table competencias.marca  drop constraint if exists marca_erp_org_id_key;

-- 2) club: el mismo club ERP puede existir en varias marcas (uno por marca)
alter table competencias.club   drop constraint if exists club_erp_club_id_key;
alter table competencias.club   add constraint club_marca_erp_uk unique (marca_id, erp_club_id);

-- 3) equipo: idempotencia por marca (se valida en la función, no global)
alter table competencias.equipo drop constraint if exists equipo_erp_equipo_id_key;
create index if not exists equipo_erp_idx on competencias.equipo(erp_equipo_id);

-- 4) erp_equipos_torneo: "ya_importado" ahora se evalúa dentro de la marca
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
         exists (select 1 from competencias.equipo q
                 join competencias.categoria cc on cc.id = q.categoria_id
                 join competencias.torneo tt on tt.id = cc.torneo_id
                 where tt.marca_id = p_marca and q.erp_equipo_id = e.id),
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

-- 5) importar: idempotencia por marca
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
    if exists (select 1 from competencias.equipo q
               join competencias.categoria cc on cc.id = q.categoria_id
               join competencias.torneo tt on tt.id = cc.torneo_id
               where tt.marca_id = v_marca and q.erp_equipo_id = r.eq_id) then
      n_omitidos := n_omitidos + 1; continue;   -- re-importar no duplica (dentro de la marca)
    end if;
    select id into v_club from competencias.club
    where marca_id = v_marca and erp_club_id = r.club_id;
    if v_club is not null then
      n_reusados := n_reusados + 1;
    else
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

notify pgrst, 'reload schema';
