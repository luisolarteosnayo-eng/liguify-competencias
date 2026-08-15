-- ============================================================================
-- CARNET DEL COMANDO TÉCNICO + PÁGINA PÚBLICA DE VERIFICACIÓN (/verificar)
-- · comando_tecnico.qr_token: código de seguridad del carnet (antifalsificación:
--   el QR lleva a liguify.com/verificar?ct=<token> y la validez se comprueba
--   EN VIVO contra la BD — un carnet falsificado no resuelve).
-- · verificar_carnet_ct / verificar_carnet_jugador: RPCs PÚBLICAS (anon) que
--   devuelven solo datos seguros (documento censurado). El token es el secreto.
--   La de jugador activa por fin la página del carnet QR ya impreso en los
--   carnets de acreditación (/verificar?c=<token>).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.comando_tecnico
  add column if not exists qr_token text;
create unique index if not exists ct_qr_token_unico
  on competencias.comando_tecnico (qr_token) where qr_token is not null;

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
      'foto_url', j.foto_url,
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

create or replace function competencias.verificar_carnet_jugador(p_token text)
returns jsonb
language sql security definer stable
set search_path = competencias, public
as $$
  select coalesce((
    select jsonb_build_object(
      'tipo','jugador',
      'valido', (i.en_lbf and i.estado = 'activo' and not i.inhabilitado and not exists (
        select 1 from competencias.sancion_global s
        where s.jugador_id = j.id and s.vigencia_desde <= current_date
          and (s.vigencia_hasta is null or s.vigencia_hasta >= current_date))),
      'en_lbf', i.en_lbf, 'estado', i.estado, 'inhabilitado', i.inhabilitado,
      'sancion_global', exists (
        select 1 from competencias.sancion_global s
        where s.jugador_id = j.id and s.vigencia_desde <= current_date
          and (s.vigencia_hasta is null or s.vigencia_hasta >= current_date)),
      'verificado', j.verificado, 'es_excepcion', i.es_excepcion,
      'dorsal', i.dorsal,
      'nombres', j.nombres, 'apellidos', j.apellidos,
      'foto_url', j.foto_url, 'consentimiento_imagen', j.consentimiento_imagen,
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

revoke all on function competencias.verificar_carnet_ct(text)      from public;
revoke all on function competencias.verificar_carnet_jugador(text) from public;
grant execute on function competencias.verificar_carnet_ct(text)      to anon, authenticated;
grant execute on function competencias.verificar_carnet_jugador(text) to anon, authenticated;

notify pgrst, 'reload schema';
