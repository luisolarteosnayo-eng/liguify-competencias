-- ============================================================================
-- PATCH: COORDINADORES DE CLUB POR INVITACIÓN + SUB-COORDINADORES POR CATEGORÍA
-- Incluye y reemplaza a patch_modulo_club.sql (correr este solo es suficiente;
-- si ya corriste el anterior, este es idempotente).
-- Flujo: admin invita coordinador (nombre/teléfono/email) → email con enlace
-- de acceso → el coordinador ACEPTA la invitación al torneo → gestiona la LBF
-- de todas las categorías de su club, y puede invitar SUB-COORDINADORES
-- limitados a 1+ categorías específicas (mismo proceso de email).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- ---------- 1) Invitaciones ----------
create table if not exists competencias.invitacion_club (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  nombre      text,
  telefono    text,
  club_id     uuid not null references competencias.club(id)   on delete cascade,
  torneo_id   uuid not null references competencias.torneo(id) on delete cascade,
  rol         text not null check (rol in ('coordinador','subcoordinador')),
  categorias  uuid[],                        -- solo subcoordinador: categorías habilitadas
  estado      text not null default 'pendiente' check (estado in ('pendiente','aceptada','revocada')),
  invitado_por uuid,
  usuario_id  uuid,                          -- se fija al aceptar
  created_at  timestamptz not null default now(),
  aceptada_at timestamptz
);
alter table competencias.invitacion_club enable row level security;
-- sin policies ni grants directos: TODO el acceso es vía funciones security definer

-- ---------- 2) Alcance del sub-coordinador: club + categoría ----------
create table if not exists competencias.usuario_club_categoria (
  usuario_id   uuid not null references competencias.usuario_perfil(id) on delete cascade,
  club_id      uuid not null references competencias.club(id)      on delete cascade,
  categoria_id uuid not null references competencias.categoria(id) on delete cascade,
  primary key (usuario_id, club_id, categoria_id)
);
alter table competencias.usuario_club_categoria enable row level security;
drop policy if exists self_read on competencias.usuario_club_categoria;
create policy self_read on competencias.usuario_club_categoria for select
  using (usuario_id = auth.uid());
grant select on competencias.usuario_club_categoria to authenticated;

-- ---------- 3) LBF: escritura con ALCANCE correcto ----------
-- coordinador → todo el club · delegado por código → su equipo ·
-- sub-coordinador → equipos del club en SUS categorías
drop policy if exists lbf_write on competencias.inscripcion_lbf;
create policy lbf_write on competencias.inscripcion_lbf for all
  using (
    competencias.es_staff_marca(competencias.marca_de_categoria(categoria_id))
    or exists (select 1 from competencias.usuario_club uc
               join competencias.equipo e on e.id = equipo_id
               where uc.usuario_id = auth.uid() and uc.club_id = e.club_id
                 and (uc.rol = 'coordinador' or uc.equipo_id = e.id))
    or exists (select 1 from competencias.usuario_club_categoria ucc
               join competencias.equipo e2 on e2.id = equipo_id
               where ucc.usuario_id = auth.uid() and ucc.club_id = e2.club_id
                 and ucc.categoria_id = inscripcion_lbf.categoria_id)
  )
  with check (auth.uid() is not null);

-- ---------- 4) Invitar (admin → coordinador) ----------
create or replace function competencias.invitar_coordinador(p_torneo uuid, p_club uuid, p_email text, p_nombre text, p_telefono text)
returns uuid
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_marca uuid; v_id uuid;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null or not competencias.es_admin_marca(v_marca) then
    raise exception 'Sin permiso sobre este torneo';
  end if;
  if not exists (select 1 from competencias.club where id = p_club and marca_id = v_marca) then
    raise exception 'El club no pertenece a la marca del torneo';
  end if;
  if coalesce(trim(p_email),'') = '' then
    raise exception 'El email es obligatorio';
  end if;
  insert into competencias.invitacion_club(email, nombre, telefono, club_id, torneo_id, rol, invitado_por)
  values (lower(trim(p_email)), nullif(trim(p_nombre),''), nullif(trim(p_telefono),''), p_club, p_torneo, 'coordinador', auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- ---------- 5) Invitar (admin o coordinador del club → sub-coordinador) ----------
create or replace function competencias.invitar_subcoordinador(p_torneo uuid, p_club uuid, p_email text, p_nombre text, p_telefono text, p_categorias uuid[])
returns uuid
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_marca uuid; v_id uuid;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null then raise exception 'Torneo inválido'; end if;
  if not ( competencias.es_admin_marca(v_marca)
           or exists (select 1 from competencias.usuario_club
                      where usuario_id = auth.uid() and club_id = p_club and rol = 'coordinador') ) then
    raise exception 'Solo el admin o el coordinador del club pueden invitar sub-coordinadores';
  end if;
  if coalesce(trim(p_email),'') = '' then raise exception 'El email es obligatorio'; end if;
  if p_categorias is null or array_length(p_categorias,1) is null then
    raise exception 'Elige al menos una categoría';
  end if;
  if exists (select 1 from unnest(p_categorias) x
             where not exists (select 1 from competencias.categoria c where c.id = x and c.torneo_id = p_torneo)) then
    raise exception 'Hay categorías que no pertenecen a este torneo';
  end if;
  insert into competencias.invitacion_club(email, nombre, telefono, club_id, torneo_id, rol, categorias, invitado_por)
  values (lower(trim(p_email)), nullif(trim(p_nombre),''), nullif(trim(p_telefono),''), p_club, p_torneo, 'subcoordinador', p_categorias, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- ---------- 6) Mis invitaciones pendientes (por MI email) ----------
create or replace function competencias.mis_invitaciones()
returns table(id uuid, rol text, club text, torneo text, marca text, nombre text, categorias text[])
language sql security definer stable
set search_path = competencias, public
as $$
  select i.id, i.rol, c.nombre, t.nombre, m.nombre, i.nombre,
         (select array_agg(coalesce(cat.nombre_display, 'Cat. '||cat.anio_nacimiento||'/'||cat.modalidad))
          from competencias.categoria cat where cat.id = any(i.categorias))
  from competencias.invitacion_club i
  join competencias.club c   on c.id = i.club_id
  join competencias.torneo t on t.id = i.torneo_id
  join competencias.marca m  on m.id = t.marca_id
  where i.estado = 'pendiente'
    and lower(i.email) = lower((select email from auth.users where id = auth.uid()))
  order by i.created_at desc
$$;

-- ---------- 7) Aceptar invitación (confirma el acceso al torneo) ----------
create or replace function competencias.aceptar_invitacion(p_id uuid)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare v record; v_email text;
begin
  select email into v_email from auth.users where id = auth.uid();
  select * into v from competencias.invitacion_club
  where id = p_id and estado = 'pendiente' and lower(email) = lower(coalesce(v_email,''));
  if v.id is null then
    return jsonb_build_object('ok', false, 'msg', 'Invitación no encontrada, ya usada o no corresponde a tu email');
  end if;
  insert into competencias.usuario_perfil(id, email, nombre)
    values (auth.uid(), coalesce(v_email,''), v.nombre)
    on conflict (id) do nothing;
  if v.rol = 'coordinador' then
    insert into competencias.usuario_club(usuario_id, club_id, rol)
      values (auth.uid(), v.club_id, 'coordinador')
      on conflict do nothing;
  else
    insert into competencias.usuario_club_categoria(usuario_id, club_id, categoria_id)
      select auth.uid(), v.club_id, unnest(v.categorias)
      on conflict do nothing;
  end if;
  update competencias.invitacion_club
    set estado = 'aceptada', aceptada_at = now(), usuario_id = auth.uid()
    where id = v.id;
  return jsonb_build_object('ok', true, 'rol', v.rol);
end $$;

-- ---------- 8) Listar y revocar invitaciones (admin o coordinador del club) ----------
create or replace function competencias.invitaciones_de_club(p_torneo uuid, p_club uuid)
returns table(id uuid, email text, nombre text, telefono text, rol text, estado text, categorias text[], created_at timestamptz)
language sql security definer stable
set search_path = competencias, public
as $$
  select i.id, i.email, i.nombre, i.telefono, i.rol, i.estado,
         (select array_agg(coalesce(cat.nombre_display, 'Cat. '||cat.anio_nacimiento||'/'||cat.modalidad))
          from competencias.categoria cat where cat.id = any(i.categorias)),
         i.created_at
  from competencias.invitacion_club i
  join competencias.torneo t on t.id = i.torneo_id
  where i.torneo_id = p_torneo and i.club_id = p_club
    and ( competencias.es_admin_marca(t.marca_id)
          or exists (select 1 from competencias.usuario_club
                     where usuario_id = auth.uid() and club_id = p_club and rol = 'coordinador') )
  order by i.created_at desc
$$;

create or replace function competencias.revocar_invitacion(p_id uuid)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
declare v record;
begin
  select i.*, t.marca_id into v
  from competencias.invitacion_club i join competencias.torneo t on t.id = i.torneo_id
  where i.id = p_id;
  if v.id is null then raise exception 'Invitación no encontrada'; end if;
  if not ( competencias.es_admin_marca(v.marca_id)
           or exists (select 1 from competencias.usuario_club
                      where usuario_id = auth.uid() and club_id = v.club_id and rol = 'coordinador') ) then
    raise exception 'Sin permiso para revocar esta invitación';
  end if;
  if v.estado <> 'pendiente' then raise exception 'Solo se pueden revocar invitaciones pendientes'; end if;
  update competencias.invitacion_club set estado = 'revocada' where id = p_id;
end $$;

-- ---------- 9) Mis equipos (Hub) — ahora incluye sub-coordinadores ----------
create or replace function competencias.mis_equipos_club()
returns table(equipo_id uuid, equipo_nombre text, equipo_estado text,
              club_id uuid, club_nombre text, escudo_url text, color text,
              categoria_id uuid, categoria text, anio int, modalidad text,
              torneo_id uuid, torneo text, torneo_estado text,
              marca text, marca_slug text,
              permitir_delegados boolean, cargar_lbf boolean, lbf_max int, rol text)
language sql security definer stable
set search_path = competencias, public
as $$
  with acceso as (
    select e.id as eq_id, uc.rol,
           case uc.rol when 'coordinador' then 0 else 1 end as prio
    from competencias.usuario_club uc
    join competencias.equipo e on e.club_id = uc.club_id
         and (uc.rol = 'coordinador' or uc.equipo_id = e.id)
    where uc.usuario_id = auth.uid()
    union all
    select e.id, 'subcoordinador', 2
    from competencias.usuario_club_categoria ucc
    join competencias.equipo e on e.club_id = ucc.club_id and e.categoria_id = ucc.categoria_id
    where ucc.usuario_id = auth.uid()
  )
  select distinct on (e.id)
         e.id, coalesce(e.nombre, c.nombre), e.estado,
         c.id, c.nombre, c.escudo_url, c.color,
         cat.id, coalesce(cat.nombre_display, 'Categoría '||cat.anio_nacimiento||' / '||cat.modalidad),
         cat.anio_nacimiento, cat.modalidad,
         t.id, t.nombre, t.estado, m.nombre, m.slug,
         t.permitir_delegados, t.cargar_lbf, t.lbf_max_jugadores, a.rol
  from acceso a
  join competencias.equipo e on e.id = a.eq_id
  join competencias.club c   on c.id = e.club_id
  join competencias.categoria cat on cat.id = e.categoria_id
  join competencias.torneo t on t.id = cat.torneo_id
  join competencias.marca m  on m.id = t.marca_id
  order by e.id, a.prio
$$;

-- ---------- 10) Canje por código de equipo (delegado) — sin cambios ----------
create or replace function competencias.canjear_codigo_delegado(p_codigo text)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_eq record; v_email text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select e.id, e.club_id, c.nombre as club_nombre into v_eq
  from competencias.equipo e join competencias.club c on c.id = e.club_id
  where upper(trim(e.delegado_codigo)) = upper(trim(p_codigo)) limit 1;
  if v_eq.id is null then
    return jsonb_build_object('ok', false, 'msg', 'Código inválido o ya utilizado');
  end if;
  select email into v_email from auth.users where id = auth.uid();
  insert into competencias.usuario_perfil(id, email) values (auth.uid(), coalesce(v_email,'')) on conflict (id) do nothing;
  insert into competencias.usuario_club(usuario_id, club_id, rol, equipo_id)
    values (auth.uid(), v_eq.club_id, 'delegado', v_eq.id) on conflict do nothing;
  update competencias.equipo set delegado_id = auth.uid(), delegado_codigo = null where id = v_eq.id;
  return jsonb_build_object('ok', true, 'club', v_eq.club_nombre);
end $$;

-- ---------- 11) Permisos ----------
revoke execute on function competencias.invitar_coordinador(uuid,uuid,text,text,text)                 from public, anon;
revoke execute on function competencias.invitar_subcoordinador(uuid,uuid,text,text,text,uuid[])       from public, anon;
revoke execute on function competencias.mis_invitaciones()                                            from public, anon;
revoke execute on function competencias.aceptar_invitacion(uuid)                                      from public, anon;
revoke execute on function competencias.invitaciones_de_club(uuid,uuid)                               from public, anon;
revoke execute on function competencias.revocar_invitacion(uuid)                                      from public, anon;
revoke execute on function competencias.mis_equipos_club()                                            from public, anon;
revoke execute on function competencias.canjear_codigo_delegado(text)                                 from public, anon;
grant  execute on function competencias.invitar_coordinador(uuid,uuid,text,text,text)                 to authenticated;
grant  execute on function competencias.invitar_subcoordinador(uuid,uuid,text,text,text,uuid[])       to authenticated;
grant  execute on function competencias.mis_invitaciones()                                            to authenticated;
grant  execute on function competencias.aceptar_invitacion(uuid)                                      to authenticated;
grant  execute on function competencias.invitaciones_de_club(uuid,uuid)                               to authenticated;
grant  execute on function competencias.revocar_invitacion(uuid)                                      to authenticated;
grant  execute on function competencias.mis_equipos_club()                                            to authenticated;
grant  execute on function competencias.canjear_codigo_delegado(text)                                 to authenticated;

notify pgrst, 'reload schema';
