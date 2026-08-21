-- ============================================================================
-- CORREGIR N° DE DOCUMENTO (solo ADMIN de la marca, o super)
--
-- Caso Eyhal Sánchez: un DNI mal digitado ocupa el número del dueño real y
-- nadie podía corregirlo desde la app. Ahora ✏️ EDITAR JUGADOR permite al
-- admin cambiar tipo/país/número. La RPC:
--   · exige ser admin de una marca donde el jugador esté inscrito (o super);
--   · si el número ya lo ocupa OTRA ficha, lo dice con nombre y apellido;
--   · deja rastro en auditoría (valor anterior → nuevo, quién y cuándo).
-- ============================================================================
create or replace function competencias.corregir_documento_jugador(
  p_jugador uuid, p_tipo text, p_pais text, p_nro text)
returns text language plpgsql security definer
set search_path = competencias, public as $$
declare v_old record; v_dueno text; v_marca uuid;
begin
  if p_nro is null or trim(p_nro) = '' then
    raise exception 'El número de documento no puede quedar vacío';
  end if;
  if not (competencias.es_super() or exists (
      select 1 from competencias.inscripcion_lbf i
      where i.jugador_id = p_jugador
        and competencias.es_admin_marca(competencias.marca_de_categoria(i.categoria_id)))) then
    raise exception 'Solo el admin de la marca puede corregir el documento';
  end if;
  select competencias.marca_de_categoria(i.categoria_id) into v_marca
  from competencias.inscripcion_lbf i where i.jugador_id = p_jugador limit 1;

  select nombres || ' ' || apellidos into v_dueno
  from competencias.jugador_maestro
  where pais_documento = upper(trim(p_pais)) and nro_documento = trim(p_nro)
    and id <> p_jugador;
  if v_dueno is not null then
    return 'OCUPADO: ese número ya pertenece a ' || v_dueno;
  end if;

  select tipo_documento, pais_documento, nro_documento into v_old
  from competencias.jugador_maestro where id = p_jugador;

  update competencias.jugador_maestro set
    tipo_documento = coalesce(nullif(trim(p_tipo),''), tipo_documento),
    pais_documento = upper(trim(p_pais)),
    nro_documento  = trim(p_nro)
  where id = p_jugador;

  insert into competencias.auditoria (usuario_id, marca_id, entidad, entidad_id, accion, detalle)
  values (auth.uid(), v_marca, 'jugador_maestro', p_jugador::text, 'corregir_documento',
          jsonb_build_object('antes', jsonb_build_object('tipo',v_old.tipo_documento,'pais',v_old.pais_documento,'nro',v_old.nro_documento),
                             'despues', jsonb_build_object('tipo',coalesce(nullif(trim(p_tipo),''),v_old.tipo_documento),'pais',upper(trim(p_pais)),'nro',trim(p_nro))));
  return 'OK';
end $$;
revoke execute on function competencias.corregir_documento_jugador(uuid,text,text,text) from public, anon;
grant  execute on function competencias.corregir_documento_jugador(uuid,text,text,text) to authenticated;

notify pgrst, 'reload schema';
select 'corregir_documento_jugador creada' as resultado;
