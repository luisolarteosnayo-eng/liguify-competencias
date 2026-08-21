-- ============================================================================
-- PERFIL SCOUT (etapa 1 de 2)
--
-- HOY: queda registrado el rol 'scout' (acceso privilegiado a información de
-- equipos y jugadores — se desarrollará después) y el perfil público del
-- jugador muestra cuántos scouts lo vieron: "🔭 1 scout de equipo profesional
-- vio este perfil". Se siembra 1 vista de prueba en cada perfil activo.
--
-- FUTURO: cuando existan usuarios scout, cada visita suya al perfil quedará
-- registrada sola (la RPC registrar_vista_scout ya está lista y la página ya
-- la llama; para cualquier usuario que no sea scout es un no-op).
-- ============================================================================

-- 1) El rol scout existe desde ya en usuario_marca
alter table competencias.usuario_marca drop constraint if exists usuario_marca_rol_check;
alter table competencias.usuario_marca
  add constraint usuario_marca_rol_check check (rol in ('admin_marca','mesa_control','scout'));

-- 2) Registro de vistas de scout a perfiles
create table if not exists competencias.scout_vista (
  id           uuid primary key default gen_random_uuid(),
  jugador_id   uuid not null references competencias.jugador_maestro(id) on delete cascade,
  scout_id     uuid references competencias.usuario_perfil(id),  -- null en vistas sembradas
  scout_equipo text not null default 'equipo profesional',
  visto_at     timestamptz not null default now(),
  unique (jugador_id, scout_id)
);
alter table competencias.scout_vista enable row level security;

-- Solo quien gestiona el perfil (padre/admin) puede ver el detalle;
-- el público solo recibe el CONTEO vía perfil_publico().
drop policy if exists sv_read on competencias.scout_vista;
create policy sv_read on competencias.scout_vista for select
  using (competencias.gestiona_perfil(jugador_id));
grant select on competencias.scout_vista to authenticated;

-- 3) ¿El usuario logueado es scout?
create or replace function competencias.es_scout()
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (select 1 from usuario_marca
                 where usuario_id = auth.uid() and rol = 'scout')
$$;
revoke execute on function competencias.es_scout() from public, anon;
grant  execute on function competencias.es_scout() to authenticated;

-- 4) Registrar la vista (la página la llama al abrir el perfil; no-op si el
--    usuario no es scout; una sola vez por scout y jugador)
create or replace function competencias.registrar_vista_scout(p_token text)
returns boolean language plpgsql security definer
set search_path = competencias, public as $$
declare v_jug uuid;
begin
  if not competencias.es_scout() then return false; end if;
  select jugador_id into v_jug from competencias.perfil_jugador
  where token = p_token and habilitado;
  if v_jug is null then return false; end if;
  insert into competencias.scout_vista (jugador_id, scout_id)
  values (v_jug, auth.uid())
  on conflict (jugador_id, scout_id) do nothing;
  return true;
end $$;
revoke execute on function competencias.registrar_vista_scout(text) from public, anon;
grant  execute on function competencias.registrar_vista_scout(text) to authenticated;

-- 5) perfil_publico ahora incluye el conteo 'scout_vistas'
create or replace function competencias.perfil_publico(p_token text)
returns jsonb language plpgsql stable security definer
set search_path = competencias, public as $$
declare v jsonb; v_jug uuid;
begin
  select jugador_id into v_jug
  from competencias.perfil_jugador
  where token = p_token and habilitado;
  if v_jug is null then return null; end if;

  select jsonb_build_object(
    'scout_vistas', (select count(*) from scout_vista sv where sv.jugador_id = v_jug),
    'jugador', (select jsonb_build_object(
        'nombres', j.nombres, 'apellidos', j.apellidos,
        'anio', extract(year from j.fecha_nacimiento),
        'posicion', j.posicion, 'pie', j.pie_habil,
        'foto_url', j.foto_url)
      from jugador_maestro j where j.id = v_jug),
    'perfil', (select jsonb_build_object(
        'bio', p.bio, 'instagram', p.instagram, 'facebook', p.facebook, 'tiktok', p.tiktok)
      from perfil_jugador p where p.jugador_id = v_jug),
    'media', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'tipo', m.tipo, 'url', m.url, 'titulo', m.titulo) order by m.orden, m.created_at)
      from perfil_media m where m.jugador_id = v_jug), '[]'::jsonb),
    'torneos', coalesce((select jsonb_agg(x order by (x->>'anio') desc nulls last) from (
      select jsonb_build_object(
        'torneo', t.nombre, 'anio', t.anio, 'marca', mk.nombre,
        'categoria', coalesce(c.nombre_display, c.anio_nacimiento::text || ' / ' || c.modalidad),
        'club', cl.nombre, 'escudo', cl.escudo_url, 'color', cl.color,
        'pj',        (select count(*) from planilla_partido pl
                      join partido pa on pa.id = pl.partido_id
                      where pl.inscripcion_id = i.id and pl.jugo
                        and pa.estado in ('finalizado','walkover')),
        'goles',     coalesce((select sum(pl.goles)     from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'amarillas', coalesce((select sum(pl.amarillas) from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'rojas',     coalesce((select sum(pl.rojas)     from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'minutos',   coalesce((select sum(pl.minutos)   from planilla_partido pl where pl.inscripcion_id = i.id),0),
        'asistencias', coalesce((select sum(pl.asistencias) from planilla_partido pl where pl.inscripcion_id = i.id),0)
      ) as x
      from inscripcion_lbf i
      join categoria c on c.id = i.categoria_id
      join torneo t    on t.id = c.torneo_id
      join marca mk    on mk.id = t.marca_id
      join equipo e    on e.id = i.equipo_id
      join club cl     on cl.id = e.club_id
      where i.jugador_id = v_jug and t.estado <> 'borrador'
    ) sub), '[]'::jsonb),
    'partidos', coalesce((select jsonb_agg(y order by (y->>'fecha') desc nulls last) from (
      select jsonb_build_object(
        'fecha', pa.fecha, 'torneo', t.nombre,
        'categoria', coalesce(c.nombre_display, c.anio_nacimiento::text || ' / ' || c.modalidad),
        'mi_club', cl_mio.nombre,
        'rival', coalesce(nullif(e_riv.nombre,''), cl_riv.nombre, 'Por definir'),
        'rival_escudo', cl_riv.escudo_url, 'rival_color', cl_riv.color,
        'local', (pa.local_id = i.equipo_id),
        'gl', pa.goles_local, 'gv', pa.goles_visita, 'estado', pa.estado,
        'video', pa.video_url,
        'goles', coalesce(pl.goles,0), 'amarillas', coalesce(pl.amarillas,0),
        'rojas', coalesce(pl.rojas,0), 'jugo', coalesce(pl.jugo,false)
      ) as y
      from inscripcion_lbf i
      join categoria c on c.id = i.categoria_id
      join torneo t    on t.id = c.torneo_id
      join equipo e_mio on e_mio.id = i.equipo_id
      join club cl_mio  on cl_mio.id = e_mio.club_id
      join partido pa  on pa.categoria_id = c.id
                      and (pa.local_id = i.equipo_id or pa.visita_id = i.equipo_id)
      left join equipo e_riv on e_riv.id = case when pa.local_id = i.equipo_id then pa.visita_id else pa.local_id end
      left join club cl_riv  on cl_riv.id = e_riv.club_id
      left join planilla_partido pl on pl.partido_id = pa.id and pl.inscripcion_id = i.id
      where i.jugador_id = v_jug and t.estado <> 'borrador'
        and pa.visible and pa.estado in ('finalizado','walkover')
      limit 200
    ) sub2), '[]'::jsonb)
  ) into v;
  return v;
end $$;
grant execute on function competencias.perfil_publico(text) to anon, authenticated;

-- 6) PRUEBA: sembrar 1 vista de scout en cada perfil activo (idempotente:
--    solo si el jugador aún no tiene ninguna vista sembrada)
insert into competencias.scout_vista (jugador_id, scout_equipo)
select pj.jugador_id, 'equipo profesional'
from competencias.perfil_jugador pj
where pj.habilitado
  and not exists (select 1 from competencias.scout_vista sv
                  where sv.jugador_id = pj.jugador_id and sv.scout_id is null);

notify pgrst, 'reload schema';

-- Verificación: cada perfil activo con su conteo de vistas
select j.nombres, j.apellidos, count(sv.id) as vistas_scout
from competencias.perfil_jugador pj
join competencias.jugador_maestro j on j.id = pj.jugador_id
left join competencias.scout_vista sv on sv.jugador_id = pj.jugador_id
where pj.habilitado
group by j.nombres, j.apellidos
order by j.nombres;
