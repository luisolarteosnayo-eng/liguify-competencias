-- ============================================================================
-- HABILITACIÓN DEL JUGADOR SEGÚN LA CONFIG DEL TORNEO (regla de VALIDACIÓN,
-- sin tocar el estado guardado):
--  · Torneo NO exige autorización de Padre/Tutor  → jugador OK (habilitado),
--    aunque su estado sea "pendiente".
--  · Torneo SÍ la exige y el jugador está PENDIENTE → NO habilitado.
--  · Torneo SÍ la exige y el jugador está ACTIVO    → habilitado.
-- Se aplica en la RPC pública del carnet; el verificador del admin y la
-- acreditación usan la misma regla en pantalla.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

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
      'foto_url', case when j.consentimiento_imagen then j.foto_url else null end,
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

notify pgrst, 'reload schema';
