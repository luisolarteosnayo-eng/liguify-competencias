-- ============================================================================
-- HISTORIAL DE FOTOS DEL JUGADOR (versionado por torneo)
-- · Cada subida de foto queda registrada en competencias.jugador_foto
--   (append-only: no se edita ni se borra — sirve para verificar identidad).
-- · Una foto puede ser específica de un TORNEO (uniforme nuevo). En ese torneo
--   se muestra esa foto; donde el club no actualizó, se muestra la ÚLTIMA foto
--   subida (jugador_maestro.foto_url sigue siendo "la última global").
-- · Los archivos en Storage ya no se pisan: el frontend sube nombres únicos
--   jugadores/{id}-{timestamp}.jpg (los anteriores se conservan).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Tabla de historial (append-only)
create table if not exists competencias.jugador_foto (
  id          uuid primary key default gen_random_uuid(),
  jugador_id  uuid not null references competencias.jugador_maestro(id) on delete cascade,
  torneo_id   uuid references competencias.torneo(id) on delete set null,  -- null = foto general
  url         text not null,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists jugador_foto_idx
  on competencias.jugador_foto (jugador_id, torneo_id, created_at desc);

-- Inmutable salvo super-admin (el historial es evidencia de identidad)
create or replace function competencias.proteger_jugador_foto()
returns trigger language plpgsql as $$
begin
  if not competencias.es_super() then
    raise exception 'El historial de fotos es inmutable';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists t_proteger_jugador_foto on competencias.jugador_foto;
create trigger t_proteger_jugador_foto
before update or delete on competencias.jugador_foto
for each row execute function competencias.proteger_jugador_foto();

-- RLS: leer solo quien gestiona un equipo donde la persona está inscrita
-- (incluye staff de la marca vía gestiona_equipo). Escritura SOLO por RPC.
alter table competencias.jugador_foto enable row level security;
drop policy if exists jf_read on competencias.jugador_foto;
create policy jf_read on competencias.jugador_foto for select
  using ( exists (select 1 from competencias.inscripcion_lbf i
                  where i.jugador_id = jugador_foto.jugador_id
                    and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
       or exists (select 1 from competencias.comando_tecnico ct
                  where ct.persona_id = jugador_foto.jugador_id
                    and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) );
grant select on competencias.jugador_foto to authenticated;

-- 2) Backfill: la foto actual de cada jugador entra al historial como "general"
insert into competencias.jugador_foto (jugador_id, torneo_id, url, created_by)
select j.id, null, j.foto_url, null
from competencias.jugador_maestro j
where j.foto_url is not null
  and not exists (select 1 from competencias.jugador_foto f where f.jugador_id = j.id);

-- 3) Resolución de la foto para un torneo: la última del torneo, o la última global
create or replace function competencias.foto_torneo(p_jugador uuid, p_torneo uuid)
returns text
language sql stable
set search_path = competencias, public
as $$
  select coalesce(
    (select f.url from competencias.jugador_foto f
      where f.jugador_id = p_jugador and f.torneo_id = p_torneo
      order by f.created_at desc limit 1),
    (select j.foto_url from competencias.jugador_maestro j where j.id = p_jugador))
$$;

-- 4) actualizar_foto_jugador ahora recibe el torneo (opcional) y registra historial
drop function if exists competencias.actualizar_foto_jugador(uuid, text);
create or replace function competencias.actualizar_foto_jugador(p_jugador uuid, p_url text, p_torneo uuid default null)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if coalesce(trim(p_url),'') = '' then
    raise exception 'URL de foto inválida';
  end if;
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para actualizar la foto de esta persona';
  end if;
  -- si viene torneo, la persona debe estar inscrita en él (jugador o CT)
  if p_torneo is not null and not (
       exists (select 1 from competencias.inscripcion_lbf i
               join competencias.categoria c on c.id = i.categoria_id
               where i.jugador_id = p_jugador and c.torneo_id = p_torneo)
    or exists (select 1 from competencias.comando_tecnico ct
               join competencias.categoria c on c.id = ct.categoria_id
               where ct.persona_id = p_jugador and c.torneo_id = p_torneo) ) then
    raise exception 'La persona no está inscrita en ese torneo';
  end if;
  insert into competencias.jugador_foto (jugador_id, torneo_id, url)
  values (p_jugador, p_torneo, p_url);
  update competencias.jugador_maestro set foto_url = p_url where id = p_jugador;
end $$;
revoke execute on function competencias.actualizar_foto_jugador(uuid,text,uuid) from public, anon;
grant  execute on function competencias.actualizar_foto_jugador(uuid,text,uuid) to authenticated;

-- 5) Historial para revisión de identidad (staff y gestores del equipo)
create or replace function competencias.historial_fotos_jugador(p_jugador uuid)
returns table (url text, torneo text, created_at timestamptz)
language plpgsql security definer stable
set search_path = competencias, public
as $$
begin
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para ver el historial de fotos de esta persona';
  end if;
  return query
    select f.url, t.nombre, f.created_at
    from competencias.jugador_foto f
    left join competencias.torneo t on t.id = f.torneo_id
    where f.jugador_id = p_jugador
    order by f.created_at desc;
end $$;
revoke execute on function competencias.historial_fotos_jugador(uuid) from public, anon;
grant  execute on function competencias.historial_fotos_jugador(uuid) to authenticated;

-- 6) Vistas y RPC públicas: foto resuelta POR TORNEO (con consentimiento)
create or replace view competencias.vista_lbf_publica as
select i.id as inscripcion_id, i.equipo_id, i.categoria_id, i.dorsal, i.capitan,
       i.es_excepcion, jp.nombres, jp.apellidos, jp.anio_nacimiento,
       case when jp.consentimiento_imagen
            then competencias.foto_torneo(i.jugador_id, cat.torneo_id) else null end as foto_url,
       jp.consentimiento_imagen,
       jp.pie_habil, jp.posicion, jp.mes_nacimiento
from competencias.inscripcion_lbf i
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
join competencias.categoria cat on cat.id = i.categoria_id
where i.en_lbf and not i.inhabilitado;

create or replace view competencias.vista_goleadores as
select i.categoria_id, i.equipo_id, i.id as inscripcion_id,
       jp.nombres, jp.apellidos,
       case when jp.consentimiento_imagen
            then competencias.foto_torneo(i.jugador_id, cat.torneo_id) else null end as foto_url,
       jp.consentimiento_imagen,
       coalesce(e.nombre, c.nombre) as equipo,
       sum(p.goles)::int     as goles,
       sum(p.amarillas)::int as amarillas,
       sum(p.rojas)::int     as rojas
from competencias.planilla_partido p
join competencias.inscripcion_lbf i on i.id = p.inscripcion_id
join competencias.equipo e on e.id = i.equipo_id
join competencias.club c on c.id = e.club_id
join competencias.categoria cat on cat.id = i.categoria_id
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
group by i.categoria_id, i.equipo_id, i.id, i.jugador_id, cat.torneo_id,
         jp.nombres, jp.apellidos, jp.consentimiento_imagen,
         e.nombre, c.nombre
having sum(p.goles) > 0 or sum(p.amarillas) > 0 or sum(p.rojas) > 0;

create or replace function competencias.verificar_carnet_jugador(p_token text)
returns jsonb
language sql security definer stable
set search_path = competencias, public
as $$
  select coalesce((
    select jsonb_build_object(
      'tipo','jugador',
      'valido', (i.en_lbf and not i.inhabilitado
                 and (i.estado = 'activo' or not t.requiere_autorizacion)
                 and not exists (
        select 1 from competencias.sancion_global s
        where s.jugador_id = j.id and s.vigencia_desde <= current_date
          and (s.vigencia_hasta is null or s.vigencia_hasta >= current_date))),
      'habilitado', (i.estado = 'activo' or not t.requiere_autorizacion),
      'requiere_autorizacion', t.requiere_autorizacion,
      'en_lbf', i.en_lbf, 'estado', i.estado, 'inhabilitado', i.inhabilitado,
      'sancion_global', exists (
        select 1 from competencias.sancion_global s
        where s.jugador_id = j.id and s.vigencia_desde <= current_date
          and (s.vigencia_hasta is null or s.vigencia_hasta >= current_date)),
      'verificado', j.verificado, 'es_excepcion', i.es_excepcion,
      'dorsal', i.dorsal,
      'nombres', j.nombres, 'apellidos', j.apellidos,
      'foto_url', case when j.consentimiento_imagen
                       then competencias.foto_torneo(j.id, t.id) else null end,
      'consentimiento_imagen', j.consentimiento_imagen,
      'documento', case when coalesce(j.nro_documento,'')='' then null
                        else left(j.nro_documento,2)||repeat('*', greatest(length(j.nro_documento)-2,4)) end,
      'club', c.nombre, 'escudo_url', c.escudo_url,
      'equipo', coalesce(nullif(e.nombre,''), c.nombre),
      'categoria', cat.nombre_display, 'torneo', t.nombre, 'marca', m.nombre)
    from competencias.inscripcion_lbf i
    join competencias.jugador_maestro j on j.id = i.jugador_id
    join competencias.equipo e on e.id = i.equipo_id
    join competencias.club c on c.id = e.club_id
    join competencias.categoria cat on cat.id = i.categoria_id
    join competencias.torneo t on t.id = cat.torneo_id
    join competencias.marca m on m.id = t.marca_id
    where i.qr_token = p_token and coalesce(p_token,'') <> ''
  ), jsonb_build_object('valido', false, 'error', 'Carnet no encontrado o código inválido'))
$$;

create or replace function competencias.verificar_carnet_ct(p_token text)
returns jsonb
language sql security definer stable
set search_path = competencias, public
as $$
  select coalesce((
    select jsonb_build_object(
      'tipo','ct',
      'valido', (ct.estado = 'activo' and not ct.inhabilitado),
      'estado', ct.estado, 'inhabilitado', ct.inhabilitado,
      'rol', ct.rol,
      'nombres', j.nombres, 'apellidos', j.apellidos,
      'foto_url', competencias.foto_torneo(j.id, t.id),
      'documento', case when coalesce(j.nro_documento,'')='' then null
                        else left(j.nro_documento,2)||repeat('*', greatest(length(j.nro_documento)-2,4)) end,
      'club', c.nombre, 'escudo_url', c.escudo_url,
      'equipo', coalesce(nullif(e.nombre,''), c.nombre),
      'categoria', cat.nombre_display, 'torneo', t.nombre, 'marca', m.nombre)
    from competencias.comando_tecnico ct
    join competencias.jugador_maestro j on j.id = ct.persona_id
    join competencias.equipo e on e.id = ct.equipo_id
    join competencias.club c on c.id = e.club_id
    join competencias.categoria cat on cat.id = ct.categoria_id
    join competencias.torneo t on t.id = cat.torneo_id
    join competencias.marca m on m.id = t.marca_id
    where ct.qr_token = p_token and coalesce(p_token,'') <> ''
  ), jsonb_build_object('valido', false, 'error', 'Carnet no encontrado o código inválido'))
$$;

notify pgrst, 'reload schema';
