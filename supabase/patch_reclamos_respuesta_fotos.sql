-- ============================================================================
-- ⚖ RECLAMOS · IMÁGENES EN LA RESPUESTA DEL ORGANIZADOR (máx. 3)
-- El organizador, al responder/resolver un reclamo, puede adjuntar hasta 3
-- imágenes de sustento (igual que el descargo del club reclamado). Se ven en
-- el detalle del reclamo del ADMIN y de ambos clubes.
-- OJO: cambia la firma de cambiar_estado_reclamo (se agrega p_fotos con
-- default) → se elimina la firma anterior para no dejar sobrecargas ambiguas.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.reclamo
  add column if not exists respuesta_fotos jsonb not null default '[]';

drop function if exists competencias.cambiar_estado_reclamo(uuid,text,text);

create or replace function competencias.cambiar_estado_reclamo(p_id uuid, p_estado text, p_respuesta text, p_fotos jsonb default null)
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
  if p_fotos is not null and jsonb_array_length(p_fotos) > 3 then
    raise exception 'Máximo 3 imágenes en la respuesta';
  end if;
  update competencias.reclamo set
    estado = p_estado,
    respuesta = coalesce(nullif(trim(coalesce(p_respuesta,'')),''), respuesta),
    respuesta_fotos = coalesce(p_fotos, respuesta_fotos),
    resuelto_at = case when p_estado in ('cerrado','rechazado') then now() else resuelto_at end
  where id = p_id;
  return competencias.detalle_reclamo(p_id);
end $$;
revoke execute on function competencias.cambiar_estado_reclamo(uuid,text,text,jsonb) from public, anon;
grant  execute on function competencias.cambiar_estado_reclamo(uuid,text,text,jsonb) to authenticated;

-- detalle_reclamo: expone respuesta_fotos
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
    'respuesta', r.respuesta, 'respuesta_fotos', r.respuesta_fotos,
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

-- VERIFICACIÓN
select 'columna respuesta_fotos' as objeto, count(*)::text as existe from information_schema.columns
 where table_schema='competencias' and table_name='reclamo' and column_name='respuesta_fotos'
union all
select 'cambiar_estado_reclamo (1 sola firma, 4 args)', count(*)::text
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='competencias' and p.proname='cambiar_estado_reclamo';
