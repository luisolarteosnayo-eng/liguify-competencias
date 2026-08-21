-- ============================================================================
-- PERFIL PÚBLICO DE JUGADOR (piloto)
--
-- · El admin habilita el perfil de un jugador (⭐ en su fila de la LBF) y
--   obtiene un link para compartir: liguify.com/jugador/<token>.
-- · El padre/madre accede con su email (Google o email+contraseña) y puede:
--   editar bio y redes (IG/Facebook/TikTok), subir hasta 3 fotos y agregar
--   links de videos propios (máx 8).
-- · Las ESTADÍSTICAS son oficiales (planilla de partidos): se calculan solas
--   y no se editan a mano. El historial de partidos incluye el 📺 video del
--   partido cuando el admin lo cargó.
-- · El token es secreto: las tablas NO son legibles por el público; todo lo
--   público sale por la RPC perfil_publico(token).
-- ============================================================================

-- 1) Tablas -----------------------------------------------------------------
create table if not exists competencias.perfil_jugador (
  jugador_id uuid primary key references competencias.jugador_maestro(id) on delete cascade,
  token      text not null unique default encode(gen_random_bytes(8),'hex'),
  habilitado boolean not null default true,
  bio        text,
  instagram  text,
  facebook   text,
  tiktok     text,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists competencias.perfil_media (
  id         uuid primary key default gen_random_uuid(),
  jugador_id uuid not null references competencias.jugador_maestro(id) on delete cascade,
  tipo       text not null check (tipo in ('foto','video')),
  url        text not null,
  titulo     text,
  orden      int  not null default 0,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table if not exists competencias.usuario_jugador (
  usuario_id uuid not null references competencias.usuario_perfil(id) on delete cascade,
  jugador_id uuid not null references competencias.jugador_maestro(id) on delete cascade,
  rol        text not null default 'padre' check (rol in ('padre')),
  created_at timestamptz not null default now(),
  primary key (usuario_id, jugador_id)
);

-- 2) Permiso de gestión: padre asignado, o admin de una marca donde el
--    jugador está inscrito, o super.
create or replace function competencias.gestiona_perfil(p_jugador uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (select 1 from usuario_jugador
                 where usuario_id = auth.uid() and jugador_id = p_jugador)
      or exists (select 1 from inscripcion_lbf i
                 where i.jugador_id = p_jugador
                   and competencias.es_admin_marca(competencias.marca_de_categoria(i.categoria_id)))
      or competencias.es_super()
$$;
revoke execute on function competencias.gestiona_perfil(uuid) from public, anon;
grant  execute on function competencias.gestiona_perfil(uuid) to authenticated;

-- 3) Límites: 3 fotos y 8 videos por jugador --------------------------------
create or replace function competencias.limite_perfil_media()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
declare n int;
begin
  select count(*) into n from competencias.perfil_media
  where jugador_id = new.jugador_id and tipo = new.tipo;
  if new.tipo = 'foto'  and n >= 3 then raise exception 'Máximo 3 fotos: elimina una para subir otra.'; end if;
  if new.tipo = 'video' and n >= 8 then raise exception 'Máximo 8 videos: elimina uno para agregar otro.'; end if;
  new.created_by := auth.uid();
  return new;
end $$;
drop trigger if exists t_limite_perfil_media on competencias.perfil_media;
create trigger t_limite_perfil_media before insert on competencias.perfil_media
for each row execute function competencias.limite_perfil_media();

-- 4) RLS: nada legible por el público (el token es secreto) -----------------
alter table competencias.perfil_jugador enable row level security;
alter table competencias.perfil_media   enable row level security;
alter table competencias.usuario_jugador enable row level security;

drop policy if exists perfil_rw on competencias.perfil_jugador;
create policy perfil_rw on competencias.perfil_jugador for all
  using (competencias.gestiona_perfil(jugador_id))
  with check (competencias.gestiona_perfil(jugador_id));

drop policy if exists media_rw on competencias.perfil_media;
create policy media_rw on competencias.perfil_media for all
  using (competencias.gestiona_perfil(jugador_id))
  with check (competencias.gestiona_perfil(jugador_id));

drop policy if exists uj_read on competencias.usuario_jugador;
create policy uj_read on competencias.usuario_jugador for select
  using (usuario_id = auth.uid() or competencias.es_super());

grant select, insert, update, delete on competencias.perfil_jugador, competencias.perfil_media to authenticated;
grant select on competencias.usuario_jugador to authenticated;

-- 5) Fotos del perfil: carpeta propia en el bucket público ------------------
do $$ begin
  create policy publico_perfil_ins on storage.objects for insert to authenticated
    with check (bucket_id = 'publico' and (storage.foldername(name))[1] = 'perfil');
exception when duplicate_object then null; end $$;

-- 6) RPCs de gestión --------------------------------------------------------
create or replace function competencias.habilitar_perfil_jugador(p_jugador uuid)
returns text language plpgsql security definer
set search_path = competencias, public as $$
declare v_token text;
begin
  if not competencias.gestiona_perfil(p_jugador) then
    raise exception 'Sin permiso sobre este jugador';
  end if;
  insert into competencias.perfil_jugador (jugador_id) values (p_jugador)
  on conflict (jugador_id) do update set habilitado = true, updated_at = now();
  select token into v_token from competencias.perfil_jugador where jugador_id = p_jugador;
  return v_token;
end $$;
revoke execute on function competencias.habilitar_perfil_jugador(uuid) from public, anon;
grant  execute on function competencias.habilitar_perfil_jugador(uuid) to authenticated;

create or replace function competencias.asignar_padre_jugador(p_email text, p_jugador uuid)
returns text language plpgsql security definer
set search_path = competencias, public as $$
declare v_uid uuid; v_email text;
begin
  if not (competencias.es_super() or exists (
      select 1 from competencias.inscripcion_lbf i
      where i.jugador_id = p_jugador
        and competencias.es_admin_marca(competencias.marca_de_categoria(i.categoria_id)))) then
    raise exception 'Solo el organizador puede asignar el acceso del padre/madre';
  end if;
  select id, email into v_uid, v_email
  from auth.users where lower(email) = lower(p_email) limit 1;
  if v_uid is null then return 'NO_EXISTE'; end if;
  insert into competencias.usuario_perfil(id, email) values (v_uid, v_email)
    on conflict (id) do nothing;
  insert into competencias.usuario_jugador(usuario_id, jugador_id)
    values (v_uid, p_jugador) on conflict do nothing;
  return 'OK';
end $$;
revoke execute on function competencias.asignar_padre_jugador(text,uuid) from public, anon;
grant  execute on function competencias.asignar_padre_jugador(text,uuid) to authenticated;

create or replace function competencias.padres_de_jugador(p_jugador uuid)
returns table(usuario_id uuid, email text) language sql stable security definer
set search_path = competencias, public as $$
  select uj.usuario_id, up.email
  from competencias.usuario_jugador uj
  join competencias.usuario_perfil up on up.id = uj.usuario_id
  where uj.jugador_id = p_jugador and competencias.gestiona_perfil(p_jugador)
$$;
revoke execute on function competencias.padres_de_jugador(uuid) from public, anon;
grant  execute on function competencias.padres_de_jugador(uuid) to authenticated;

create or replace function competencias.quitar_padre_jugador(p_usuario uuid, p_jugador uuid)
returns void language plpgsql security definer
set search_path = competencias, public as $$
begin
  if not (competencias.es_super() or exists (
      select 1 from competencias.inscripcion_lbf i
      where i.jugador_id = p_jugador
        and competencias.es_admin_marca(competencias.marca_de_categoria(i.categoria_id)))) then
    raise exception 'Solo el organizador puede quitar este acceso';
  end if;
  delete from competencias.usuario_jugador
  where usuario_id = p_usuario and jugador_id = p_jugador;
end $$;
revoke execute on function competencias.quitar_padre_jugador(uuid,uuid) from public, anon;
grant  execute on function competencias.quitar_padre_jugador(uuid,uuid) to authenticated;

-- Para el padre logueado: sus hijos con perfil
create or replace function competencias.mis_perfiles()
returns table(jugador_id uuid, token text, nombres text, apellidos text, foto_url text)
language sql stable security definer
set search_path = competencias, public as $$
  select j.id, p.token, j.nombres, j.apellidos, j.foto_url
  from competencias.usuario_jugador uj
  join competencias.jugador_maestro j on j.id = uj.jugador_id
  join competencias.perfil_jugador  p on p.jugador_id = j.id
  where uj.usuario_id = auth.uid()
$$;
revoke execute on function competencias.mis_perfiles() from public, anon;
grant  execute on function competencias.mis_perfiles() to authenticated;

-- 7) LA RPC PÚBLICA: todo el perfil por token -------------------------------
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

notify pgrst, 'reload schema';

-- Verificación
select 'perfil_jugador' as tabla, count(*) as filas from competencias.perfil_jugador
union all select 'usuario_jugador', count(*) from competencias.usuario_jugador;
