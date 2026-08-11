-- ============================================================================
-- AUTORIZACIÓN DE PADRE/TUTOR
-- · torneo.requiere_autorizacion: si está activo, el modal del jugador (admin
--   y club) muestra el campo para subir la autorización (PDF o foto).
-- · El documento es ÚNICO POR JUGADOR (jugador_maestro): se sube una vez y
--   vale para todos los torneos. Se guarda la RUTA en el bucket PRIVADO
--   'documentos' (se ve con URL firmada, igual que el DNI).
-- · Al subirla: el jugador pasa a ACTIVO en esa inscripción (si el torneo
--   la exige) y se registra el consentimiento de imagen (foto a COLOR).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.torneo
  add column if not exists requiere_autorizacion boolean not null default false;

alter table competencias.jugador_maestro
  add column if not exists autorizacion_url   text,
  add column if not exists autorizacion_fecha timestamptz;

-- El blindaje LBF revierte en silencio los cambios de estado hechos por el
-- club; la RPC de autorización habilita SOLO pendiente→activo vía set_config.
create or replace function competencias.proteger_lbf_estado()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if competencias.es_staff_marca(competencias.marca_de_categoria(new.categoria_id)) then
    return new;
  end if;
  if coalesce(current_setting('competencias.activar_por_autorizacion', true),'') = '1'
     and old.estado = 'pendiente' and new.estado = 'activo' then
    new.inhabilitado      := old.inhabilitado;
    new.fecha_apto_medico := old.fecha_apto_medico;
    new.es_excepcion      := old.es_excepcion;
    return new;
  end if;
  new.estado            := old.estado;
  new.inhabilitado      := old.inhabilitado;
  new.fecha_apto_medico := old.fecha_apto_medico;
  new.es_excepcion      := old.es_excepcion;
  return new;
end $$;

-- Sube/registra la autorización y activa la inscripción si el torneo la exige.
-- p_ruta null = el jugador YA tiene autorización (subida en otro torneo) y
-- solo se activa esta inscripción.
create or replace function competencias.subir_autorizacion_jugador(p_jugador uuid, p_inscripcion uuid, p_ruta text default null)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare
  v_ins record; v_req boolean; v_url text; v_activado boolean := false;
begin
  select i.id, i.equipo_id, i.categoria_id, i.estado, c.torneo_id
    into v_ins
  from competencias.inscripcion_lbf i
  join competencias.categoria c on c.id = i.categoria_id
  where i.id = p_inscripcion and i.jugador_id = p_jugador;
  if v_ins.id is null or not competencias.gestiona_equipo(v_ins.equipo_id, v_ins.categoria_id) then
    raise exception 'Sin permiso sobre esta inscripción';
  end if;

  if p_ruta is not null then
    update competencias.jugador_maestro set
      autorizacion_url      = p_ruta,
      autorizacion_fecha    = now(),
      consentimiento_imagen = true,
      consentimiento_fecha  = coalesce(consentimiento_fecha, now())
    where id = p_jugador;
  end if;

  select autorizacion_url into v_url from competencias.jugador_maestro where id = p_jugador;
  if v_url is null then
    raise exception 'El jugador aún no tiene autorización subida';
  end if;

  select t.requiere_autorizacion into v_req
  from competencias.torneo t where t.id = v_ins.torneo_id;
  if coalesce(v_req, false) and v_ins.estado = 'pendiente' then
    perform set_config('competencias.activar_por_autorizacion', '1', true);
    update competencias.inscripcion_lbf set estado = 'activo' where id = p_inscripcion;
    perform set_config('competencias.activar_por_autorizacion', '', true);
    v_activado := true;
  end if;

  return jsonb_build_object('ok', true, 'activado', v_activado, 'autorizacion_url', v_url);
end $$;

revoke execute on function competencias.subir_autorizacion_jugador(uuid,uuid,text) from public, anon;
grant  execute on function competencias.subir_autorizacion_jugador(uuid,uuid,text) to authenticated;

notify pgrst, 'reload schema';
