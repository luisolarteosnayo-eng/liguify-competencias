-- ============================================================================
-- 🔭 PERFIL SCOUT (etapa 2 — la app)
--  · El scout se invita por email igual que admin/mesa (rol 'scout').
--  · Entra por liguify.com/scout: ve todo el PÚBLICO y además:
--      - ESTADÍSTICAS de los jugadores por equipo (como el modo Club,
--        con nombres completos) — stats_equipo_scout
--      - SEGUIMIENTOS: su lista de jugadores seguidos (nombres completos,
--        club, categoría, posición, ranking y acceso al perfil)
--      - Botón HACER SEGUIMIENTO en la LBF de cada equipo
--  · Todo gated por es_scout(); las visitas del scout a un perfil se siguen
--    registrando con registrar_vista_scout (ya existente).
-- ============================================================================

-- 1) Las invitaciones de marca aceptan el rol scout
alter table competencias.invitacion_marca drop constraint if exists invitacion_marca_rol_check;
alter table competencias.invitacion_marca
  add constraint invitacion_marca_rol_check check (rol in ('admin_marca','mesa_control','scout'));

create or replace function competencias.invitar_usuario_marca(p_marca uuid, p_email text, p_rol text)
returns uuid language plpgsql security definer
set search_path = competencias, public as $$
declare v_id uuid;
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  if p_rol not in ('admin_marca','mesa_control','scout') then
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

-- 2) Seguimientos del scout
create table if not exists competencias.scout_seguimiento (
  usuario_id uuid not null,
  jugador_id uuid not null references competencias.jugador_maestro(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (usuario_id, jugador_id)
);
alter table competencias.scout_seguimiento enable row level security;   -- solo RPC

-- 3) Seguir / dejar de seguir
create or replace function competencias.seguir_jugador(p_jugador uuid, p_seguir boolean)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
begin
  if not competencias.es_scout() then raise exception 'Solo para scouts'; end if;
  if p_seguir then
    insert into competencias.scout_seguimiento (usuario_id, jugador_id)
    values (auth.uid(), p_jugador) on conflict do nothing;
  else
    delete from competencias.scout_seguimiento
    where usuario_id = auth.uid() and jugador_id = p_jugador;
  end if;
  return jsonb_build_object('ok', true,
    'total', (select count(*) from scout_seguimiento where usuario_id = auth.uid()));
end $$;
revoke execute on function competencias.seguir_jugador(uuid,boolean) from public, anon;
grant  execute on function competencias.seguir_jugador(uuid,boolean) to authenticated;

-- 4) IDs seguidos (para pintar los botones)
create or replace function competencias.seguimiento_ids()
returns uuid[] language sql stable security definer
set search_path = competencias, public as $$
  select case when competencias.es_scout()
    then coalesce((select array_agg(jugador_id) from scout_seguimiento where usuario_id = auth.uid()), '{}')
    else '{}' end
$$;
revoke execute on function competencias.seguimiento_ids() from public, anon;
grant  execute on function competencias.seguimiento_ids() to authenticated;

-- 5) Mi lista de seguimientos (nombres COMPLETOS: acceso profesional gated)
create or replace function competencias.mis_seguimientos()
returns table(
  jugador_id uuid, nombres text, apellidos text, posicion text, pie_habil text,
  foto_url text, perfil_token text, clubes text, categorias text,
  puntos int, puesto bigint, puesto_total int, ranking_cat text, seguido_at timestamptz)
language sql stable security definer
set search_path = competencias, public as $$
  select s.jugador_id, j.nombres, j.apellidos, j.posicion, j.pie_habil,
         case when j.consentimiento_imagen then j.foto_url end,
         pj.token,
         (select string_agg(distinct cl.nombre, ' · ')
          from inscripcion_lbf i join equipo e on e.id=i.equipo_id join club cl on cl.id=e.club_id
          where i.jugador_id = s.jugador_id),
         (select string_agg(distinct coalesce(c.nombre_display, c.anio_nacimiento::text||' / '||c.modalidad), ' · ')
          from inscripcion_lbf i join categoria c on c.id=i.categoria_id
          where i.jugador_id = s.jugador_id),
         rk.puntos, rk.puesto, rk.total, rk.cat,
         s.created_at
  from competencias.scout_seguimiento s
  join competencias.jugador_maestro j on j.id = s.jugador_id
  left join competencias.perfil_jugador pj on pj.jugador_id = s.jugador_id and pj.habilitado
  left join lateral (
    select rc.puntos, rc.puesto, rc.total,
           coalesce(c.nombre_display, c.anio_nacimiento::text||' / '||c.modalidad) as cat
    from competencias.mv_ranking_categoria rc
    join competencias.categoria c on c.id = rc.categoria_id
    where rc.jugador_id = s.jugador_id
    order by rc.puntos desc limit 1
  ) rk on true
  where s.usuario_id = auth.uid() and competencias.es_scout()
  order by s.created_at desc
$$;
revoke execute on function competencias.mis_seguimientos() from public, anon;
grant  execute on function competencias.mis_seguimientos() to authenticated;

-- 6) Estadísticas del equipo para el scout (como el modo Club, nombre completo)
create or replace function competencias.stats_equipo_scout(p_equipo uuid)
returns table(
  inscripcion_id uuid, jugador_id uuid, dorsal int, nombres text, apellidos text,
  posicion text, pie_habil text, pj bigint, minutos bigint, goles bigint,
  asistencias bigint, amarillas bigint, rojas bigint, duracion int)
language sql stable security definer
set search_path = competencias, public as $$
  select i.id, i.jugador_id, i.dorsal, j.nombres, j.apellidos, j.posicion, j.pie_habil,
         count(pl.inscripcion_id) filter (where pl.jugo or coalesce(pl.minutos,0) > 0),
         coalesce(sum(pl.minutos),0), coalesce(sum(pl.goles),0),
         coalesce(sum(pl.asistencias),0), coalesce(sum(pl.amarillas),0), coalesce(sum(pl.rojas),0),
         coalesce(c.duracion_partido, t.duracion_partido, 90)
  from competencias.inscripcion_lbf i
  join competencias.jugador_maestro j on j.id = i.jugador_id
  join competencias.categoria c on c.id = i.categoria_id
  join competencias.torneo t    on t.id = c.torneo_id
  left join competencias.planilla_partido pl on pl.inscripcion_id = i.id
  where i.equipo_id = p_equipo and i.en_lbf and not i.inhabilitado
    and competencias.es_scout()
  group by i.id, i.jugador_id, i.dorsal, j.nombres, j.apellidos, j.posicion, j.pie_habil,
           c.duracion_partido, t.duracion_partido
  order by coalesce(sum(pl.minutos),0) desc, i.dorsal nulls last
$$;
revoke execute on function competencias.stats_equipo_scout(uuid) from public, anon;
grant  execute on function competencias.stats_equipo_scout(uuid) to authenticated;

-- es_scout ya existe pero se re-otorga por si acaso
grant execute on function competencias.es_scout() to authenticated;

notify pgrst, 'reload schema';

-- Verificación
select 'scout_seguimiento' as objeto, count(*) as existe from information_schema.tables
 where table_schema='competencias' and table_name='scout_seguimiento'
union all
select 'rpc seguir/lista/stats', count(*) from pg_proc p
 join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='competencias'
   and p.proname in ('seguir_jugador','mis_seguimientos','stats_equipo_scout','seguimiento_ids')
union all
select 'invitaciones aceptan scout', count(*) from information_schema.check_constraints
 where constraint_schema='competencias' and constraint_name='invitacion_marca_rol_check'
   and check_clause like '%scout%';
