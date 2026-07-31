-- ============================================================================
-- PATCH: ALTA DE MARCAS (super-admin) + GESTIÓN DE ROLES POR EMAIL
-- Ejecutar en Supabase SQL Editor (proyecto bpsczjjomgzhnjxnzmhj)
-- ============================================================================

-- 1) Crear marcas: SOLO super-admin (antes: cualquier autenticado)
drop policy if exists adm_ins on competencias.marca;
create policy adm_ins on competencias.marca for insert
  with check (exists (select 1 from competencias.usuario_perfil p
                      where p.id = auth.uid() and p.es_super));

-- 2) Asignar rol en una marca por EMAIL (super o admin de esa marca).
--    El usuario debe haberse registrado antes (Google/email) → si no, 'NO_EXISTE'.
--    Si el rol es admin_marca y la marca no tiene dueño, lo registra como owner.
create or replace function competencias.asignar_rol_marca(p_email text, p_marca uuid, p_rol text)
returns text
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_uid uuid; v_email text;
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  if p_rol not in ('admin_marca','mesa_control') then
    raise exception 'Rol inválido';
  end if;
  select id, email into v_uid, v_email
  from auth.users where lower(email) = lower(p_email) limit 1;
  if v_uid is null then
    return 'NO_EXISTE';
  end if;
  insert into competencias.usuario_perfil(id, email) values (v_uid, v_email)
    on conflict (id) do nothing;
  insert into competencias.usuario_marca(usuario_id, marca_id, rol)
    values (v_uid, p_marca, p_rol)
    on conflict do nothing;
  if p_rol = 'admin_marca' then
    update competencias.marca set owner_id = coalesce(owner_id, v_uid) where id = p_marca;
  end if;
  return 'OK';
end $$;

-- 3) Quitar un rol (super o admin de esa marca)
create or replace function competencias.quitar_rol_marca(p_usuario uuid, p_marca uuid, p_rol text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  delete from competencias.usuario_marca
  where usuario_id = p_usuario and marca_id = p_marca and rol = p_rol;
end $$;

-- 4) Listar usuarios de una marca (solo super o admin de esa marca)
create or replace function competencias.usuarios_de_marca(p_marca uuid)
returns table(usuario_id uuid, email text, nombre text, rol text)
language sql security definer stable
set search_path = competencias, public
as $$
  select um.usuario_id, up.email, up.nombre, um.rol
  from competencias.usuario_marca um
  join competencias.usuario_perfil up on up.id = um.usuario_id
  where um.marca_id = p_marca
    and competencias.es_admin_marca(p_marca)
  order by up.email, um.rol;
$$;

-- 5) Permisos: solo usuarios autenticados
revoke execute on function competencias.asignar_rol_marca(text,uuid,text) from public, anon;
revoke execute on function competencias.quitar_rol_marca(uuid,uuid,text)  from public, anon;
revoke execute on function competencias.usuarios_de_marca(uuid)           from public, anon;
grant  execute on function competencias.asignar_rol_marca(text,uuid,text) to authenticated;
grant  execute on function competencias.quitar_rol_marca(uuid,uuid,text)  to authenticated;
grant  execute on function competencias.usuarios_de_marca(uuid)           to authenticated;

notify pgrst, 'reload schema';
