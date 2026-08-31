-- ============================================================================
-- ⚖ SISTEMA DE RECLAMOS (Club y Admin)
--
--  · Reclamo sobre partidos JUGADOS de la ÚLTIMA fecha jugada o en juego.
--  · Correlativo por torneo: "RECLAMO 2026 0001".
--  · Estados: borrador → generado → en_proceso → pendiente_devolucion →
--    cerrado | (en_proceso → rechazado). Cerrado y rechazado son finales.
--  · Textos configurables por torneo (intro con el costo y datos de pago).
--  · Evidencias: hasta 3 fotos + 1 video + imagen del pago, en el bucket
--    PRIVADO 'documentos' bajo reclamos/.
--  · Los avisos por email (admin + club reclamante + club reclamado) los envía
--    la Edge Function 'enviar-aviso-reclamo' usando datos_email_reclamo
--    (SOLO service_role).
-- ============================================================================

-- 1) Textos configurables del torneo (con los textos por defecto acordados)
alter table competencias.torneo
  add column if not exists reclamo_texto_intro text,
  add column if not exists reclamo_texto_pago  text;
update competencias.torneo set reclamo_texto_intro =
  'A continuación encontrará las indicaciones para completar su reclamo. Le pedimos llenar el formulario con la información solicitada de manera clara. La presentación del reclamo tiene un costo de S/ 100.00. Si la resolución resulta a favor del reclamante, el monto será devuelto en su totalidad. En caso contrario, el monto no será reembolsado y quedará a disposición de la organización del torneo.'
  where reclamo_texto_intro is null;
update competencias.torneo set reclamo_texto_pago =
  'REALIZAR EL ABONO A ESTE NÚMERO DE YAPE: 983 788 038 — VOM SPORT E.I.R.L.'
  where reclamo_texto_pago is null;

-- 2) Tabla de reclamos (RLS cerrado: todo por RPC)
create table if not exists competencias.reclamo (
  id                   uuid primary key default gen_random_uuid(),
  torneo_id            uuid not null references competencias.torneo(id) on delete cascade,
  numero               int  not null,
  codigo               text not null,
  categoria_id         uuid not null references competencias.categoria(id),
  partido_id           uuid not null references competencias.partido(id),
  equipo_reclamante_id uuid not null references competencias.equipo(id),
  equipo_reclamado_id  uuid not null references competencias.equipo(id),
  creado_por           uuid not null,
  estado               text not null default 'borrador'
    check (estado in ('borrador','generado','en_proceso','pendiente_devolucion','cerrado','rechazado')),
  articulo             text,
  descripcion          text,
  solicitud            text,
  fotos                jsonb not null default '[]',
  video_url            text,
  pago_url             text,
  respuesta            text,
  created_at           timestamptz not null default now(),
  enviado_at           timestamptz,
  resuelto_at          timestamptz,
  unique (torneo_id, numero)
);
alter table competencias.reclamo enable row level security;
revoke all on competencias.reclamo from public, anon, authenticated;

-- 3) Helpers ------------------------------------------------------------------
-- ¿El usuario puede actuar por este equipo? (coordinador del club, sub-coord
-- de la categoría del equipo, o staff de la marca)
create or replace function competencias.gestiona_equipo(p_equipo uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (
    select 1 from competencias.equipo e
    join competencias.categoria c on c.id = e.categoria_id
    join competencias.torneo t    on t.id = c.torneo_id
    where e.id = p_equipo
      and ( competencias.es_staff_marca(t.marca_id)
         or exists (select 1 from usuario_club uc
                    where uc.usuario_id = auth.uid() and uc.club_id = e.club_id)
         or exists (select 1 from usuario_club_categoria ucc
                    where ucc.usuario_id = auth.uid() and ucc.club_id = e.club_id
                      and ucc.categoria_id = e.categoria_id) )
  )
$$;

-- Última fecha jugada o en juego de una categoría
create or replace function competencias.ultima_fecha_jugada(p_categoria uuid)
returns int language sql stable security definer
set search_path = competencias, public as $$
  select max(j.numero) from competencias.jornada j
  where j.categoria_id = p_categoria
    and exists (select 1 from competencias.partido p
                where p.jornada_id = j.id and p.visible
                  and p.estado in ('finalizado','walkover','en_vivo'))
$$;

-- ¿El usuario participa en el reclamo o es staff? (para ver el detalle)
create or replace function competencias.participa_reclamo(p_id uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (
    select 1 from competencias.reclamo r
    join competencias.torneo t on t.id = r.torneo_id
    where r.id = p_id
      and ( competencias.es_staff_marca(t.marca_id)
         or competencias.gestiona_equipo(r.equipo_reclamante_id)
         or competencias.gestiona_equipo(r.equipo_reclamado_id) )
  )
$$;

-- 4) Partidos reclamables de un equipo (última fecha jugada de su categoría)
create or replace function competencias.partidos_reclamables(p_equipo uuid)
returns table(partido_id uuid, fecha_numero int, dia date, hora time,
              local text, visita text, gl int, gv int, estado text, rival_equipo_id uuid)
language sql stable security definer
set search_path = competencias, public as $$
  select p.id, j.numero, p.fecha, p.hora,
         coalesce(el.nombre, cll.nombre), coalesce(ev.nombre, clv.nombre),
         p.goles_local, p.goles_visita, p.estado,
         case when p.local_id = p_equipo then p.visita_id else p.local_id end
  from competencias.equipo e
  join competencias.partido p on (p.local_id = e.id or p.visita_id = e.id)
                             and p.categoria_id = e.categoria_id
  join competencias.jornada j on j.id = p.jornada_id
  left join competencias.equipo el on el.id = p.local_id
  left join competencias.club cll  on cll.id = el.club_id
  left join competencias.equipo ev on ev.id = p.visita_id
  left join competencias.club clv  on clv.id = ev.club_id
  where e.id = p_equipo
    and competencias.gestiona_equipo(p_equipo)
    and p.visible and p.estado in ('finalizado','walkover','en_vivo')
    and j.numero = competencias.ultima_fecha_jugada(e.categoria_id)
  order by p.fecha, p.hora
$$;
revoke execute on function competencias.partidos_reclamables(uuid) from public, anon;
grant  execute on function competencias.partidos_reclamables(uuid) to authenticated;

-- 5) Crear (queda en BORRADOR, con su correlativo por torneo)
create or replace function competencias.crear_reclamo(p_partido uuid, p_equipo uuid)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_p record; v_t record; v_cat uuid; v_rival uuid; v_num int; v_cod text; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if not competencias.gestiona_equipo(p_equipo) then
    raise exception 'No gestionas este equipo';
  end if;
  select p.*, c.torneo_id as tid into v_p
  from competencias.partido p join competencias.categoria c on c.id = p.categoria_id
  where p.id = p_partido;
  if v_p.id is null then raise exception 'Partido no encontrado'; end if;
  if v_p.local_id <> p_equipo and v_p.visita_id <> p_equipo then
    raise exception 'Tu equipo no jugó ese partido';
  end if;
  if v_p.estado not in ('finalizado','walkover','en_vivo') then
    raise exception 'Solo se reclama sobre partidos jugados o en juego';
  end if;
  if (select j.numero from competencias.jornada j where j.id = v_p.jornada_id)
     is distinct from competencias.ultima_fecha_jugada(v_p.categoria_id) then
    raise exception 'Solo se puede reclamar sobre la última fecha jugada o en juego';
  end if;
  select * into v_t from competencias.torneo where id = v_p.tid;
  v_rival := case when v_p.local_id = p_equipo then v_p.visita_id else v_p.local_id end;
  perform pg_advisory_xact_lock(hashtext('reclamo-'||v_t.id::text));
  select coalesce(max(numero),0)+1 into v_num from competencias.reclamo where torneo_id = v_t.id;
  v_cod := 'RECLAMO '||coalesce(v_t.anio::text, to_char(now(),'YYYY'))||' '||lpad(v_num::text,4,'0');
  insert into competencias.reclamo
    (torneo_id, numero, codigo, categoria_id, partido_id,
     equipo_reclamante_id, equipo_reclamado_id, creado_por)
  values (v_t.id, v_num, v_cod, v_p.categoria_id, p_partido, p_equipo, v_rival, auth.uid())
  returning id into v_id;
  return competencias.detalle_reclamo(v_id);
end $$;
revoke execute on function competencias.crear_reclamo(uuid,uuid) from public, anon;
grant  execute on function competencias.crear_reclamo(uuid,uuid) to authenticated;

-- 6) Guardar borrador
create or replace function competencias.guardar_reclamo(
  p_id uuid, p_articulo text, p_descripcion text, p_solicitud text,
  p_fotos jsonb, p_video text, p_pago text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v record;
begin
  select * into v from competencias.reclamo where id = p_id;
  if v.id is null then raise exception 'Reclamo no encontrado'; end if;
  if v.estado <> 'borrador' then raise exception 'El reclamo ya fue enviado: no se puede editar'; end if;
  if not competencias.gestiona_equipo(v.equipo_reclamante_id) then raise exception 'No gestionas este equipo'; end if;
  if jsonb_array_length(coalesce(p_fotos,'[]'::jsonb)) > 3 then raise exception 'Máximo 3 fotos'; end if;
  update competencias.reclamo set
    articulo = p_articulo, descripcion = p_descripcion, solicitud = p_solicitud,
    fotos = coalesce(p_fotos,'[]'::jsonb), video_url = nullif(trim(coalesce(p_video,'')),''),
    pago_url = nullif(trim(coalesce(p_pago,'')),'')
  where id = p_id;
  return competencias.detalle_reclamo(p_id);
end $$;
revoke execute on function competencias.guardar_reclamo(uuid,text,text,text,jsonb,text,text) from public, anon;
grant  execute on function competencias.guardar_reclamo(uuid,text,text,text,jsonb,text,text) to authenticated;

-- 7) Enviar a revisión (borrador → generado)
create or replace function competencias.enviar_reclamo(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v record;
begin
  select * into v from competencias.reclamo where id = p_id;
  if v.id is null then raise exception 'Reclamo no encontrado'; end if;
  if v.estado <> 'borrador' then raise exception 'El reclamo ya fue enviado'; end if;
  if not competencias.gestiona_equipo(v.equipo_reclamante_id) then raise exception 'No gestionas este equipo'; end if;
  if coalesce(trim(v.articulo),'') = '' or coalesce(trim(v.descripcion),'') = ''
     or coalesce(trim(v.solicitud),'') = '' then
    raise exception 'Completa el artículo del reglamento, la descripción y lo que solicitas';
  end if;
  if coalesce(v.pago_url,'') = '' then
    raise exception 'Adjunta la imagen del abono para enviar el reclamo';
  end if;
  update competencias.reclamo set estado = 'generado', enviado_at = now() where id = p_id;
  return competencias.detalle_reclamo(p_id);
end $$;
revoke execute on function competencias.enviar_reclamo(uuid) from public, anon;
grant  execute on function competencias.enviar_reclamo(uuid) to authenticated;

-- 8) Cambiar estado (solo el organizador; transiciones válidas)
create or replace function competencias.cambiar_estado_reclamo(p_id uuid, p_estado text, p_respuesta text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v record; v_marca uuid;
begin
  select r.*, t.marca_id into v from competencias.reclamo r
  join competencias.torneo t on t.id = r.torneo_id where r.id = p_id;
  if v.id is null then raise exception 'Reclamo no encontrado'; end if;
  if not competencias.es_staff_marca(v.marca_id) then raise exception 'Solo el organizador'; end if;
  if not ( (v.estado='generado'            and p_estado='en_proceso')
        or (v.estado='en_proceso'          and p_estado in ('pendiente_devolucion','rechazado'))
        or (v.estado='pendiente_devolucion' and p_estado='cerrado') ) then
    raise exception 'Transición no permitida: % → %', v.estado, p_estado;
  end if;
  update competencias.reclamo set
    estado = p_estado,
    respuesta = coalesce(nullif(trim(coalesce(p_respuesta,'')),''), respuesta),
    resuelto_at = case when p_estado in ('cerrado','rechazado') then now() else resuelto_at end
  where id = p_id;
  return competencias.detalle_reclamo(p_id);
end $$;
revoke execute on function competencias.cambiar_estado_reclamo(uuid,text,text) from public, anon;
grant  execute on function competencias.cambiar_estado_reclamo(uuid,text,text) to authenticated;

-- 9) Detalle completo (participantes y staff)
create or replace function competencias.detalle_reclamo(p_id uuid)
returns jsonb language sql stable security definer
set search_path = competencias, public as $$
  select jsonb_build_object(
    'id', r.id, 'codigo', r.codigo, 'estado', r.estado, 'numero', r.numero,
    'torneo', t.nombre, 'torneo_id', t.id,
    'texto_intro', t.reclamo_texto_intro, 'texto_pago', t.reclamo_texto_pago,
    'categoria', coalesce(c.nombre_display, c.anio_nacimiento::text||' / '||c.modalidad),
    'partido', jsonb_build_object('id', p.id, 'fecha', p.fecha, 'hora', to_char(p.hora,'HH24:MI'),
      'local', coalesce(el.nombre, cll.nombre), 'visita', coalesce(ev.nombre, clv.nombre),
      'gl', p.goles_local, 'gv', p.goles_visita, 'fecha_numero', j.numero),
    'reclamante', coalesce(er.nombre, clr.nombre), 'reclamado', coalesce(ed.nombre, cld.nombre),
    'reclamante_id', r.equipo_reclamante_id, 'reclamado_id', r.equipo_reclamado_id,
    'articulo', r.articulo, 'descripcion', r.descripcion, 'solicitud', r.solicitud,
    'fotos', r.fotos, 'video_url', r.video_url, 'pago_url', r.pago_url,
    'respuesta', r.respuesta,
    'created_at', r.created_at, 'enviado_at', r.enviado_at, 'resuelto_at', r.resuelto_at,
    'editable', (r.estado = 'borrador' and competencias.gestiona_equipo(r.equipo_reclamante_id)))
  from competencias.reclamo r
  join competencias.torneo t on t.id = r.torneo_id
  join competencias.categoria c on c.id = r.categoria_id
  join competencias.partido p on p.id = r.partido_id
  left join competencias.jornada j on j.id = p.jornada_id
  left join competencias.equipo el on el.id = p.local_id
  left join competencias.club cll  on cll.id = el.club_id
  left join competencias.equipo ev on ev.id = p.visita_id
  left join competencias.club clv  on clv.id = ev.club_id
  left join competencias.equipo er on er.id = r.equipo_reclamante_id
  left join competencias.club clr  on clr.id = er.club_id
  left join competencias.equipo ed on ed.id = r.equipo_reclamado_id
  left join competencias.club cld  on cld.id = ed.club_id
  where r.id = p_id and competencias.participa_reclamo(p_id)
$$;
revoke execute on function competencias.detalle_reclamo(uuid) from public, anon;
grant  execute on function competencias.detalle_reclamo(uuid) to authenticated;

-- 10) Listas: mis reclamos (club) y todos los del torneo (admin)
create or replace function competencias.mis_reclamos(p_torneo uuid)
returns table(id uuid, codigo text, estado text, categoria text,
              reclamante text, reclamado text, rol text, dia date, created_at timestamptz)
language sql stable security definer
set search_path = competencias, public as $$
  select r.id, r.codigo, r.estado,
         coalesce(c.nombre_display, c.anio_nacimiento::text||' / '||c.modalidad),
         coalesce(er.nombre, clr.nombre), coalesce(ed.nombre, cld.nombre),
         case when competencias.gestiona_equipo(r.equipo_reclamante_id) then 'reclamante' else 'reclamado' end,
         p.fecha, r.created_at
  from competencias.reclamo r
  join competencias.categoria c on c.id = r.categoria_id
  join competencias.partido p on p.id = r.partido_id
  left join competencias.equipo er on er.id = r.equipo_reclamante_id
  left join competencias.club clr  on clr.id = er.club_id
  left join competencias.equipo ed on ed.id = r.equipo_reclamado_id
  left join competencias.club cld  on cld.id = ed.club_id
  where r.torneo_id = p_torneo
    and (competencias.gestiona_equipo(r.equipo_reclamante_id)
      or (r.estado <> 'borrador' and competencias.gestiona_equipo(r.equipo_reclamado_id)))
  order by r.created_at desc
$$;
revoke execute on function competencias.mis_reclamos(uuid) from public, anon;
grant  execute on function competencias.mis_reclamos(uuid) to authenticated;

create or replace function competencias.reclamos_torneo(p_torneo uuid)
returns table(id uuid, codigo text, estado text, categoria text,
              reclamante text, reclamado text, dia date, created_at timestamptz, enviado_at timestamptz)
language sql stable security definer
set search_path = competencias, public as $$
  select r.id, r.codigo, r.estado,
         coalesce(c.nombre_display, c.anio_nacimiento::text||' / '||c.modalidad),
         coalesce(er.nombre, clr.nombre), coalesce(ed.nombre, cld.nombre),
         p.fecha, r.created_at, r.enviado_at
  from competencias.reclamo r
  join competencias.torneo t on t.id = r.torneo_id
  join competencias.categoria c on c.id = r.categoria_id
  join competencias.partido p on p.id = r.partido_id
  left join competencias.equipo er on er.id = r.equipo_reclamante_id
  left join competencias.club clr  on clr.id = er.club_id
  left join competencias.equipo ed on ed.id = r.equipo_reclamado_id
  left join competencias.club cld  on cld.id = ed.club_id
  where r.torneo_id = p_torneo and competencias.es_staff_marca(t.marca_id)
    and r.estado <> 'borrador'
  order by (r.estado in ('generado','en_proceso','pendiente_devolucion')) desc, r.enviado_at desc nulls last
$$;
revoke execute on function competencias.reclamos_torneo(uuid) from public, anon;
grant  execute on function competencias.reclamos_torneo(uuid) to authenticated;

-- 11) Destinatarios del aviso por email — SOLO service_role (Edge Function)
create or replace function competencias.datos_email_reclamo(p_id uuid)
returns jsonb language sql stable security definer
set search_path = competencias, public as $$
  with r as (
    select r.*, t.nombre as torneo, t.marca_id, t.id as tid,
           coalesce(er.nombre, clr.nombre) as reclamante, er.club_id as club_r,
           coalesce(ed.nombre, cld.nombre) as reclamado,  ed.club_id as club_d,
           coalesce(c.nombre_display, c.anio_nacimiento::text||' / '||c.modalidad) as categoria
    from competencias.reclamo r
    join competencias.torneo t on t.id = r.torneo_id
    join competencias.categoria c on c.id = r.categoria_id
    left join competencias.equipo er on er.id = r.equipo_reclamante_id
    left join competencias.club clr  on clr.id = er.club_id
    left join competencias.equipo ed on ed.id = r.equipo_reclamado_id
    left join competencias.club cld  on cld.id = ed.club_id
    where r.id = p_id
  ),
  mails_club as (
    select i.club_id, lower(trim(i.email)) as email
    from competencias.invitacion_club i, r
    where i.torneo_id = r.tid and i.estado in ('pendiente','aceptada') and coalesce(i.email,'')<>''
    union
    select uc.club_id, lower(trim(up.email))
    from competencias.usuario_club uc
    join competencias.usuario_perfil up on up.id = uc.usuario_id
    where coalesce(up.email,'')<>''
    union
    select ucc.club_id, lower(trim(up.email))
    from competencias.usuario_club_categoria ucc
    join competencias.usuario_perfil up on up.id = ucc.usuario_id, r
    where ucc.categoria_id = r.categoria_id and coalesce(up.email,'')<>''
  )
  select jsonb_build_object(
    'codigo', r.codigo, 'estado', r.estado, 'torneo', r.torneo, 'categoria', r.categoria,
    'reclamante', r.reclamante, 'reclamado', r.reclamado,
    'respuesta', r.respuesta, 'solicitud', r.solicitud,
    'admins', coalesce((select jsonb_agg(distinct au.email)
              from competencias.usuario_marca um
              join auth.users au on au.id = um.usuario_id
              where um.marca_id = r.marca_id and um.rol = 'admin_marca'), '[]'::jsonb),
    'emails_reclamante', coalesce((select jsonb_agg(distinct m.email) from mails_club m where m.club_id = r.club_r), '[]'::jsonb),
    'emails_reclamado',  coalesce((select jsonb_agg(distinct m.email) from mails_club m where m.club_id = r.club_d), '[]'::jsonb))
  from r
$$;
revoke execute on function competencias.datos_email_reclamo(uuid) from public, anon, authenticated;
grant  execute on function competencias.datos_email_reclamo(uuid) to service_role;

-- 12) Storage: evidencias en el bucket PRIVADO 'documentos' bajo reclamos/
drop policy if exists documentos_reclamos_ins on storage.objects;
create policy documentos_reclamos_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and name like 'reclamos/%');
drop policy if exists documentos_reclamos_sel on storage.objects;
create policy documentos_reclamos_sel on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and name like 'reclamos/%');

notify pgrst, 'reload schema';

-- Verificación
select 'tabla reclamo' as objeto, count(*) as existe from information_schema.tables
 where table_schema='competencias' and table_name='reclamo'
union all
select 'rpcs reclamo (12)', count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='competencias' and p.proname in
 ('gestiona_equipo','ultima_fecha_jugada','participa_reclamo','partidos_reclamables',
  'crear_reclamo','guardar_reclamo','enviar_reclamo','cambiar_estado_reclamo',
  'detalle_reclamo','mis_reclamos','reclamos_torneo','datos_email_reclamo')
union all
select 'textos configurables', count(*) from information_schema.columns
 where table_schema='competencias' and table_name='torneo'
   and column_name in ('reclamo_texto_intro','reclamo_texto_pago');
