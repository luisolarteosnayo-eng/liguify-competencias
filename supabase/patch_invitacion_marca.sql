-- ============================================================================
-- INVITACIONES DE MARCA (admin_marca / mesa_control) — mismo flujo que el
-- coordinador de club: el invitado recibe un email con su enlace de acceso,
-- entra (crea su contraseña o usa Google) y ACEPTA la invitación; recién ahí
-- se le asigna el rol. Se acabó el "debe haber iniciado sesión antes".
-- ============================================================================

create table if not exists competencias.invitacion_marca (
  id           uuid primary key default gen_random_uuid(),
  email        text not null,
  marca_id     uuid not null references competencias.marca(id) on delete cascade,
  rol          text not null check (rol in ('admin_marca','mesa_control')),
  estado       text not null default 'pendiente' check (estado in ('pendiente','aceptada','revocada')),
  invitado_por uuid,
  usuario_id   uuid,
  created_at   timestamptz not null default now(),
  aceptada_at  timestamptz
);
alter table competencias.invitacion_marca enable row level security;
-- sin policies: todo pasa por las RPC (security definer)

-- 1) Invitar (solo admin de la marca)
create or replace function competencias.invitar_usuario_marca(p_marca uuid, p_email text, p_rol text)
returns uuid language plpgsql security definer
set search_path = competencias, public as $$
declare v_id uuid;
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  if p_rol not in ('admin_marca','mesa_control') then
    raise exception 'Rol inválido';
  end if;
  if coalesce(trim(p_email),'') = '' then
    raise exception 'El email es obligatorio';
  end if;
  if exists (select 1 from competencias.invitacion_marca
             where marca_id = p_marca and lower(email) = lower(trim(p_email))
               and rol = p_rol and estado = 'pendiente') then
    raise exception 'Ya hay una invitación pendiente para ese email con ese rol';
  end if;
  insert into competencias.invitacion_marca (email, marca_id, rol, invitado_por)
  values (lower(trim(p_email)), p_marca, p_rol, auth.uid())
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function competencias.invitar_usuario_marca(uuid,text,text) from public, anon;
grant  execute on function competencias.invitar_usuario_marca(uuid,text,text) to authenticated;

-- 2) Mis invitaciones pendientes (el invitado, tras entrar con su email)
create or replace function competencias.mis_invitaciones_marca()
returns table(id uuid, marca text, rol text, created_at timestamptz)
language sql stable security definer
set search_path = competencias, public as $$
  select i.id, m.nombre, i.rol, i.created_at
  from competencias.invitacion_marca i
  join competencias.marca m on m.id = i.marca_id
  where i.estado = 'pendiente'
    and lower(i.email) = lower(coalesce((select email from auth.users where id = auth.uid()),''))
  order by i.created_at
$$;
revoke execute on function competencias.mis_invitaciones_marca() from public, anon;
grant  execute on function competencias.mis_invitaciones_marca() to authenticated;

-- 3) Aceptar (valida que el email de la sesión coincida)
create or replace function competencias.aceptar_invitacion_marca(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v record; v_email text;
begin
  select email into v_email from auth.users where id = auth.uid();
  select * into v from competencias.invitacion_marca
  where id = p_id and estado = 'pendiente' and lower(email) = lower(coalesce(v_email,''));
  if v.id is null then
    return jsonb_build_object('ok', false, 'msg', 'Invitación no encontrada, ya usada o no corresponde a tu email');
  end if;
  insert into competencias.usuario_perfil(id, email) values (auth.uid(), coalesce(v_email,''))
    on conflict (id) do nothing;
  insert into competencias.usuario_marca(usuario_id, marca_id, rol)
    values (auth.uid(), v.marca_id, v.rol)
    on conflict do nothing;
  update competencias.invitacion_marca
    set estado = 'aceptada', aceptada_at = now(), usuario_id = auth.uid()
    where id = v.id;
  return jsonb_build_object('ok', true, 'rol', v.rol);
end $$;
revoke execute on function competencias.aceptar_invitacion_marca(uuid) from public, anon;
grant  execute on function competencias.aceptar_invitacion_marca(uuid) to authenticated;

-- 4) Listar y revocar (admin de la marca)
create or replace function competencias.invitaciones_de_marca(p_marca uuid)
returns table(id uuid, email text, rol text, estado text, created_at timestamptz)
language sql stable security definer
set search_path = competencias, public as $$
  select i.id, i.email, i.rol, i.estado, i.created_at
  from competencias.invitacion_marca i
  where i.marca_id = p_marca and competencias.es_admin_marca(p_marca)
  order by (i.estado = 'pendiente') desc, i.created_at desc
$$;
revoke execute on function competencias.invitaciones_de_marca(uuid) from public, anon;
grant  execute on function competencias.invitaciones_de_marca(uuid) to authenticated;

create or replace function competencias.revocar_invitacion_marca(p_id uuid)
returns void language plpgsql security definer
set search_path = competencias, public as $$
declare v_marca uuid;
begin
  select marca_id into v_marca from competencias.invitacion_marca where id = p_id;
  if v_marca is null or not competencias.es_admin_marca(v_marca) then
    raise exception 'Sin permiso sobre esta invitación';
  end if;
  update competencias.invitacion_marca set estado = 'revocada'
  where id = p_id and estado = 'pendiente';
end $$;
revoke execute on function competencias.revocar_invitacion_marca(uuid) from public, anon;
grant  execute on function competencias.revocar_invitacion_marca(uuid) to authenticated;

notify pgrst, 'reload schema';
select 'invitacion_marca lista' as resultado;
