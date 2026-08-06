-- ============================================================================
-- PATCH: MÓDULO CLUB (The Hub) — acceso de delegados por código de un solo uso
-- El admin genera equipo.delegado_codigo (I4); el delegado se registra en
-- liguify.com/club y canjea el código → usuario_club + vínculo al equipo.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Canjear código (UN SOLO USO: se anula al canjear)
create or replace function competencias.canjear_codigo_delegado(p_codigo text)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_eq record; v_email text;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  select e.id, e.club_id, c.nombre as club_nombre
  into v_eq
  from competencias.equipo e
  join competencias.club c on c.id = e.club_id
  where upper(trim(e.delegado_codigo)) = upper(trim(p_codigo))
  limit 1;
  if v_eq.id is null then
    return jsonb_build_object('ok', false, 'msg', 'Código inválido o ya utilizado');
  end if;
  select email into v_email from auth.users where id = auth.uid();
  insert into competencias.usuario_perfil(id, email)
    values (auth.uid(), coalesce(v_email,''))
    on conflict (id) do nothing;
  insert into competencias.usuario_club(usuario_id, club_id, rol, equipo_id)
    values (auth.uid(), v_eq.club_id, 'delegado', v_eq.id)
    on conflict do nothing;
  update competencias.equipo
    set delegado_id = auth.uid(), delegado_codigo = null
    where id = v_eq.id;
  return jsonb_build_object('ok', true, 'club', v_eq.club_nombre);
end $$;

-- 2) Mis equipos (The Hub): equipos a los que tengo acceso vía usuario_club.
--    coordinador de club = todos los equipos del club; delegado = su equipo.
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
  select e.id, coalesce(e.nombre, c.nombre), e.estado,
         c.id, c.nombre, c.escudo_url, c.color,
         cat.id, coalesce(cat.nombre_display, 'Categoría '||cat.anio_nacimiento||' / '||cat.modalidad),
         cat.anio_nacimiento, cat.modalidad,
         t.id, t.nombre, t.estado, m.nombre, m.slug,
         t.permitir_delegados, t.cargar_lbf, t.lbf_max_jugadores, uc.rol
  from competencias.usuario_club uc
  join competencias.club c   on c.id = uc.club_id
  join competencias.equipo e on e.club_id = c.id
       and (uc.rol = 'coordinador' or uc.equipo_id is null or uc.equipo_id = e.id)
  join competencias.categoria cat on cat.id = e.categoria_id
  join competencias.torneo t on t.id = cat.torneo_id
  join competencias.marca m  on m.id = t.marca_id
  where uc.usuario_id = auth.uid()
  order by t.anio desc, cat.anio_nacimiento desc
$$;

-- 3) Permisos
revoke execute on function competencias.canjear_codigo_delegado(text) from public, anon;
revoke execute on function competencias.mis_equipos_club()             from public, anon;
grant  execute on function competencias.canjear_codigo_delegado(text) to authenticated;
grant  execute on function competencias.mis_equipos_club()             to authenticated;

notify pgrst, 'reload schema';
