-- ============================================================================
-- 📧 AVISO DE PROGRAMACIÓN A LOS EQUIPOS
-- Permite al organizador comunicar por email, a todos los clubes de un torneo,
-- que la programación de una fecha ya está disponible. Cada club recibe SUS
-- partidos (hora, rival y cancha) y un recordatorio si su plantel está
-- incompleto. El envío lo hace la Edge Function 'enviar-aviso-programacion'
-- (Resend); aquí van los datos y el registro de lo enviado.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Registro de avisos enviados (para saber a quién y cuándo se comunicó)
create table if not exists competencias.aviso_programacion (
  id            uuid primary key default gen_random_uuid(),
  torneo_id     uuid not null references competencias.torneo(id) on delete cascade,
  fecha_numero  int  not null,
  destinatarios int  not null default 0,
  enviados      int  not null default 0,
  detalle       jsonb,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists aviso_programacion_idx
  on competencias.aviso_programacion (torneo_id, fecha_numero, created_at desc);

alter table competencias.aviso_programacion enable row level security;
drop policy if exists ap_staff on competencias.aviso_programacion;
create policy ap_staff on competencias.aviso_programacion for all
  using (exists (select 1 from competencias.torneo t
                 where t.id = aviso_programacion.torneo_id
                   and competencias.es_staff_marca(t.marca_id)))
  with check (exists (select 1 from competencias.torneo t
                      where t.id = aviso_programacion.torneo_id
                        and competencias.es_staff_marca(t.marca_id)));
grant select, insert on competencias.aviso_programacion to authenticated;

-- 2) Destinatarios + contenido por club para una fecha del torneo.
--    Solo staff de la marca. Un club sin correos registrados sale con
--    emails vacío para que el organizador lo vea en la vista previa.
create or replace function competencias.destinatarios_programacion(p_torneo uuid, p_fecha int)
returns table (club_id uuid, club text, emails text[], partidos jsonb,
               lbf_total int, lbf_pendientes int)
language plpgsql security definer stable
set search_path = competencias, public
as $$
#variable_conflict use_column
declare v_marca uuid;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null then raise exception 'Torneo no encontrado'; end if;
  if not competencias.es_staff_marca(v_marca) then
    raise exception 'Solo el organizador puede enviar avisos de este torneo';
  end if;

  return query
  with cat as (
    select c.id, c.nombre_display, c.anio_nacimiento, c.modalidad
    from competencias.categoria c where c.torneo_id = p_torneo
  ), jor as (
    select j.id, j.numero, j.fecha, j.categoria_id
    from competencias.jornada j
    join cat on cat.id = j.categoria_id
    where j.numero = p_fecha
  ), eq as (                              -- equipos activos del torneo
    select e.id, e.club_id, e.categoria_id, coalesce(e.nombre, cl.nombre) as nombre
    from competencias.equipo e
    join competencias.club cl on cl.id = e.club_id
    join cat on cat.id = e.categoria_id
    where e.estado = 'activo'
  ), pj as (                              -- partidos de esa fecha, por club
    select eq.club_id,
           jsonb_build_object(
             'categoria', coalesce(cat.nombre_display, 'Cat. '||cat.anio_nacimiento||'/'||cat.modalidad),
             'hora',      to_char(p.hora, 'HH24:MI'),
             'dia',       p.fecha,
             'local',     coalesce(el.nombre, cll.nombre),
             'visita',    coalesce(ev.nombre, clv.nombre),
             'es_local',  (p.local_id = eq.id),
             'rival',     case when p.local_id = eq.id then coalesce(ev.nombre, clv.nombre)
                               else coalesce(el.nombre, cll.nombre) end,
             'cancha',    p.cancha, 'sede', p.sede) as info,
           p.hora as orden_hora
    from competencias.partido p
    join jor on jor.id = p.jornada_id
    join cat on cat.id = p.categoria_id
    join eq  on eq.id in (p.local_id, p.visita_id) and eq.categoria_id = p.categoria_id
    left join competencias.equipo el on el.id = p.local_id
    left join competencias.club   cll on cll.id = el.club_id
    left join competencias.equipo ev on ev.id = p.visita_id
    left join competencias.club   clv on clv.id = ev.club_id
  ), mails as (                           -- coordinadores, sub-coordinadores y delegados
    select i.club_id, lower(trim(i.email)) as email
    from competencias.invitacion_club i
    where i.torneo_id = p_torneo and i.estado in ('pendiente','aceptada')
      and coalesce(i.email,'') <> ''
    union
    select uc.club_id, lower(trim(up.email))
    from competencias.usuario_club uc
    join competencias.usuario_perfil up on up.id = uc.usuario_id
    where coalesce(up.email,'') <> ''
      and uc.club_id in (select distinct eq.club_id from eq)
    union
    select ucc.club_id, lower(trim(up.email))
    from competencias.usuario_club_categoria ucc
    join competencias.usuario_perfil up on up.id = ucc.usuario_id
    join cat on cat.id = ucc.categoria_id
    where coalesce(up.email,'') <> ''
  ), lbf as (
    select eq.club_id,
           count(*)::int as total,
           count(*) filter (where i.estado = 'pendiente')::int as pend
    from competencias.inscripcion_lbf i
    join eq on eq.id = i.equipo_id
    where i.en_lbf
    group by eq.club_id
  )
  select cl.id, cl.nombre,
         coalesce((select array_agg(distinct m.email) from mails m where m.club_id = cl.id), '{}'),
         coalesce((select jsonb_agg(x.info order by x.orden_hora nulls last)
                   from pj x where x.club_id = cl.id), '[]'::jsonb),
         coalesce((select l.total from lbf l where l.club_id = cl.id), 0),
         coalesce((select l.pend  from lbf l where l.club_id = cl.id), 0)
  from competencias.club cl
  where cl.id in (select distinct eq.club_id from eq)
  order by cl.nombre;
end $$;

revoke execute on function competencias.destinatarios_programacion(uuid,int) from public, anon;
grant  execute on function competencias.destinatarios_programacion(uuid,int) to authenticated;

notify pgrst, 'reload schema';
