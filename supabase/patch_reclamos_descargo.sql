-- ============================================================================
-- ⚖ RECLAMOS · DESCARGO DEL CLUB RECLAMADO
--  · El club al que le reclaman puede subir su RESPUESTA (descargo) y hasta
--    3 imágenes, SOLO mientras el reclamo está EN PROCESO.
--  · Los estados siguen siendo exclusivos del organizador; el reclamante
--    solo maneja borrador → generado (sin cambios).
-- ============================================================================

alter table competencias.reclamo
  add column if not exists descargo text,
  add column if not exists descargo_fotos jsonb not null default '[]',
  add column if not exists descargo_at timestamptz;

-- RPC del descargo (club reclamado, solo en EN PROCESO)
create or replace function competencias.responder_reclamo(p_id uuid, p_descargo text, p_fotos jsonb)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v record;
begin
  select * into v from competencias.reclamo where id = p_id;
  if v.id is null then raise exception 'Reclamo no encontrado'; end if;
  if not competencias.gestiona_equipo(v.equipo_reclamado_id) then
    raise exception 'Solo el club reclamado puede registrar el descargo';
  end if;
  if v.estado <> 'en_proceso' then
    raise exception 'El descargo solo se registra cuando el reclamo está EN PROCESO';
  end if;
  if coalesce(trim(p_descargo),'') = '' then raise exception 'Escribe tu descargo'; end if;
  if jsonb_array_length(coalesce(p_fotos,'[]'::jsonb)) > 3 then raise exception 'Máximo 3 imágenes'; end if;
  update competencias.reclamo set
    descargo = p_descargo, descargo_fotos = coalesce(p_fotos,'[]'::jsonb), descargo_at = now()
  where id = p_id;
  return competencias.detalle_reclamo(p_id);
end $$;
revoke execute on function competencias.responder_reclamo(uuid,text,jsonb) from public, anon;
grant  execute on function competencias.responder_reclamo(uuid,text,jsonb) to authenticated;

-- detalle_reclamo: agrega descargo, sus fotos y el flag puede_descargo
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
    'descargo', r.descargo, 'descargo_fotos', r.descargo_fotos, 'descargo_at', r.descargo_at,
    'puede_descargo', (r.estado = 'en_proceso' and competencias.gestiona_equipo(r.equipo_reclamado_id)),
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

notify pgrst, 'reload schema';

-- Verificación
select 'columnas descargo' as objeto, count(*) as existe from information_schema.columns
 where table_schema='competencias' and table_name='reclamo'
   and column_name in ('descargo','descargo_fotos','descargo_at')
union all
select 'responder_reclamo', count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='competencias' and p.proname='responder_reclamo';
