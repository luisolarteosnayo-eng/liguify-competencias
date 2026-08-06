-- ============================================================================
-- PATCH: el COORDINADOR de un club ve TODOS los torneos del club, incluso en
-- otras marcas — SOLO si ambas marcas pertenecen a la MISMA organización real
-- (mismo erp_org_id) y el club se llama igual (nombre normalizado).
-- Entre organizadores distintos no hay extensión (protección de cartera C1).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Helper: ¿soy coordinador de este club? (directo o por club homónimo de
--    otra marca de la misma organización)
create or replace function competencias.es_coordinador_club(p_club uuid)
returns boolean
language sql stable security definer
set search_path = competencias
as $$
  select exists (select 1 from usuario_club
                 where usuario_id = auth.uid() and club_id = p_club and rol = 'coordinador')
      or exists (
        select 1
        from usuario_club uc
        join club  c0 on c0.id = uc.club_id
        join marca m0 on m0.id = c0.marca_id and m0.erp_org_id is not null
        join club  c1 on c1.id = p_club
        join marca m1 on m1.id = c1.marca_id and m1.erp_org_id = m0.erp_org_id
        where uc.usuario_id = auth.uid() and uc.rol = 'coordinador'
          and lower(trim(c1.nombre)) = lower(trim(c0.nombre)))
$$;
revoke execute on function competencias.es_coordinador_club(uuid) from public, anon;
grant  execute on function competencias.es_coordinador_club(uuid) to authenticated;

-- 2) LBF: la escritura del coordinador usa el helper (alcance multimarca)
drop policy if exists lbf_write on competencias.inscripcion_lbf;
create policy lbf_write on competencias.inscripcion_lbf for all
  using (
    competencias.es_staff_marca(competencias.marca_de_categoria(categoria_id))
    or exists (select 1 from competencias.equipo e
               where e.id = equipo_id and competencias.es_coordinador_club(e.club_id))
    or exists (select 1 from competencias.usuario_club uc
               join competencias.equipo e on e.id = equipo_id
               where uc.usuario_id = auth.uid() and uc.club_id = e.club_id
                 and uc.rol = 'delegado' and uc.equipo_id = e.id)
    or exists (select 1 from competencias.usuario_club_categoria ucc
               join competencias.equipo e2 on e2.id = equipo_id
               where ucc.usuario_id = auth.uid() and ucc.club_id = e2.club_id
                 and ucc.categoria_id = inscripcion_lbf.categoria_id)
  )
  with check (auth.uid() is not null);

-- 3) Hub: mis equipos incluye los clubes homónimos de la misma organización
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
    select e.id as eq_id, 'coordinador'::text as rol, 0 as prio
    from competencias.club c
    join competencias.equipo e on e.club_id = c.id
    where competencias.es_coordinador_club(c.id)
    union all
    select e.id, uc.rol, 1
    from competencias.usuario_club uc
    join competencias.equipo e on e.club_id = uc.club_id and uc.equipo_id = e.id
    where uc.usuario_id = auth.uid() and uc.rol = 'delegado'
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

-- 4) Sub-coordinadores e invitaciones: el coordinador extendido también puede
create or replace function competencias.invitar_subcoordinador(p_torneo uuid, p_club uuid, p_email text, p_nombre text, p_telefono text, p_categorias uuid[])
returns uuid
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_marca uuid; v_id uuid;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null then raise exception 'Torneo inválido'; end if;
  if not ( competencias.es_admin_marca(v_marca) or competencias.es_coordinador_club(p_club) ) then
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
    and ( competencias.es_admin_marca(t.marca_id) or competencias.es_coordinador_club(p_club) )
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
  if not ( competencias.es_admin_marca(v.marca_id) or competencias.es_coordinador_club(v.club_id) ) then
    raise exception 'Sin permiso para revocar esta invitación';
  end if;
  if v.estado <> 'pendiente' then raise exception 'Solo se pueden revocar invitaciones pendientes'; end if;
  update competencias.invitacion_club set estado = 'revocada' where id = p_id;
end $$;

notify pgrst, 'reload schema';
