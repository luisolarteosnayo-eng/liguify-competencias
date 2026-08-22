-- ============================================================================
-- REGISTRO DE PADRES · SEGURIDAD NIVEL 1
--  1) Límite de intentos en la validación DNI+fecha (5 fallos / hora) con log.
--  2) Email confirmado obligatorio para registrarse (Google ya viene
--     confirmado; con email+contraseña exige el enlace de confirmación —
--     ACTIVAR también en Supabase: Authentication → Providers → Email →
--     "Confirm email" = ON).
--  3) Tope de 2 padres por jugador; el 2º entra PENDIENTE hasta que lo
--     apruebe el padre ya registrado o el organizador.
--  4) Datos para los avisos automáticos (organizador + padre existente) que
--     envía la Edge Function enviar-confirmacion-padre.
-- ============================================================================

-- 1) LOG DE INTENTOS -----------------------------------------------------------
create table if not exists competencias.intento_validacion_padre (
  id         bigint generated always as identity primary key,
  usuario_id uuid not null,
  token      text,
  ok         boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists ix_intento_padre_usuario on competencias.intento_validacion_padre(usuario_id, created_at desc);
alter table competencias.intento_validacion_padre enable row level security;   -- solo RPC

-- 3) ESTADO DEL VÍNCULO ----------------------------------------------------------
alter table competencias.usuario_jugador
  add column if not exists estado text not null default 'aprobado'
    check (estado in ('aprobado','pendiente')),
  add column if not exists aprobado_por uuid,
  add column if not exists aprobado_at  timestamptz;

-- Solo los APROBADOS gestionan el perfil
create or replace function competencias.gestiona_perfil(p_jugador uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (select 1 from usuario_jugador
                 where usuario_id = auth.uid() and jugador_id = p_jugador and estado = 'aprobado')
      or exists (select 1 from inscripcion_lbf i
                 where i.jugador_id = p_jugador
                   and competencias.es_admin_marca(competencias.marca_de_categoria(i.categoria_id)))
      or competencias.es_super()
$$;

-- mis_perfiles devuelve también el estado (el frontend muestra 'pendiente')
drop function if exists competencias.mis_perfiles();
create or replace function competencias.mis_perfiles()
returns table(jugador_id uuid, token text, nombres text, apellidos text, foto_url text, estado text)
language sql stable security definer
set search_path = competencias, public as $$
  select j.id, p.token, j.nombres, j.apellidos, j.foto_url, uj.estado
  from competencias.usuario_jugador uj
  join competencias.jugador_maestro j on j.id = uj.jugador_id
  join competencias.perfil_jugador  p on p.jugador_id = j.id
  where uj.usuario_id = auth.uid()
$$;
revoke execute on function competencias.mis_perfiles() from public, anon;
grant  execute on function competencias.mis_perfiles() to authenticated;

-- 1) VALIDAR con límite de intentos (deja de ser 'stable' porque registra) ----
create or replace function competencias.validar_jugador_padre(p_token text, p_doc text, p_fnac date)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_jug uuid; v_ok boolean; v_fallos int;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select count(*) into v_fallos from competencias.intento_validacion_padre
  where usuario_id = auth.uid() and not ok and created_at > now() - interval '1 hour';
  if v_fallos >= 5 then
    return jsonb_build_object('ok', false, 'msg', 'Demasiados intentos fallidos. Espera una hora y vuelve a intentar, o contacta al organizador.');
  end if;
  select jugador_id into v_jug from competencias.perfil_jugador
  where token = p_token and habilitado;
  if v_jug is null then return jsonb_build_object('ok', false, 'msg', 'Perfil no disponible'); end if;
  if not competencias.club_piloto_perfil(v_jug) then
    return jsonb_build_object('ok', false, 'msg', 'El registro de padres aún no está disponible para este club (etapa piloto)');
  end if;
  select (j.nro_documento = trim(p_doc) and j.fecha_nacimiento = p_fnac) into v_ok
  from competencias.jugador_maestro j where j.id = v_jug;
  insert into competencias.intento_validacion_padre (usuario_id, token, ok)
  values (auth.uid(), p_token, coalesce(v_ok,false));
  if not coalesce(v_ok,false) then
    return jsonb_build_object('ok', false,
      'msg', 'Los datos no coinciden con el jugador. Verifica el N° de documento y la fecha de nacimiento.'
             || case when v_fallos >= 3 then ' (Te quedan ' || (4 - v_fallos) || ' intentos.)' else '' end);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function competencias.validar_jugador_padre(text,text,date) from public, anon;
grant  execute on function competencias.validar_jugador_padre(text,text,date) to authenticated;

-- 2+3) REGISTRAR: email confirmado + tope 2 + 2º pendiente -------------------
create or replace function competencias.registrar_acceso_padre(
  p_token text, p_doc text, p_fnac date,
  p_nombre text, p_telefono text, p_dni_frente text, p_dni_reverso text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_jug uuid; v_ok boolean; v_email text; v_nom_jug text; v_conf timestamptz;
        v_aprobados int; v_fallos int; v_estado text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select email, email_confirmed_at into v_email, v_conf from auth.users where id = auth.uid();
  if v_conf is null then
    return jsonb_build_object('ok', false, 'codigo', 'EMAIL_NO_CONFIRMADO',
      'msg', 'Primero confirma tu correo: abre el enlace que te enviamos al registrarte.');
  end if;
  select count(*) into v_fallos from competencias.intento_validacion_padre
  where usuario_id = auth.uid() and not ok and created_at > now() - interval '1 hour';
  if v_fallos >= 5 then
    return jsonb_build_object('ok', false, 'msg', 'Demasiados intentos fallidos. Espera una hora.');
  end if;
  select jugador_id into v_jug from competencias.perfil_jugador
  where token = p_token and habilitado;
  if v_jug is null then return jsonb_build_object('ok', false, 'msg', 'Perfil no disponible'); end if;
  if not competencias.club_piloto_perfil(v_jug) then
    return jsonb_build_object('ok', false, 'msg', 'El registro de padres aún no está disponible para este club (etapa piloto)');
  end if;
  select (j.nro_documento = trim(p_doc) and j.fecha_nacimiento = p_fnac),
         j.nombres || ' ' || j.apellidos
    into v_ok, v_nom_jug
  from competencias.jugador_maestro j where j.id = v_jug;
  if not coalesce(v_ok,false) then
    insert into competencias.intento_validacion_padre (usuario_id, token, ok) values (auth.uid(), p_token, false);
    return jsonb_build_object('ok', false, 'msg', 'Los datos del jugador no coinciden');
  end if;
  if coalesce(trim(p_nombre),'') = '' then
    return jsonb_build_object('ok', false, 'msg', 'Tu nombre y apellido son obligatorios');
  end if;
  if coalesce(trim(p_telefono),'') = '' then
    return jsonb_build_object('ok', false, 'msg', 'El número de teléfono es obligatorio');
  end if;
  if p_dni_frente is null or p_dni_reverso is null then
    return jsonb_build_object('ok', false, 'msg', 'Sube la foto de tu DNI por ambos lados');
  end if;
  -- tope de padres (sin contar a quien se está registrando)
  select count(*) into v_aprobados from competencias.usuario_jugador
  where jugador_id = v_jug and estado = 'aprobado' and usuario_id <> auth.uid();
  if v_aprobados >= 2 then
    return jsonb_build_object('ok', false, 'msg', 'Este perfil ya tiene 2 padres/madres registrados. Si corresponde, pide al organizador que revise los accesos.');
  end if;
  v_estado := case when v_aprobados = 0 then 'aprobado' else 'pendiente' end;
  insert into competencias.usuario_perfil(id, email, nombre)
    values (auth.uid(), coalesce(v_email,''), trim(p_nombre))
    on conflict (id) do nothing;
  insert into competencias.usuario_jugador
    (usuario_id, jugador_id, nombre, telefono, dni_frente_url, dni_reverso_url, terminos_at, origen, estado,
     aprobado_por, aprobado_at)
  values (auth.uid(), v_jug, trim(p_nombre), trim(p_telefono), p_dni_frente, p_dni_reverso, now(), 'auto', v_estado,
          case when v_estado = 'aprobado' then auth.uid() end, case when v_estado = 'aprobado' then now() end)
  on conflict (usuario_id, jugador_id) do update set
    nombre = excluded.nombre, telefono = excluded.telefono,
    dni_frente_url = excluded.dni_frente_url, dni_reverso_url = excluded.dni_reverso_url,
    terminos_at = coalesce(usuario_jugador.terminos_at, now());
  return jsonb_build_object('ok', true, 'estado', v_estado, 'jugador', v_nom_jug, 'jugador_id', v_jug, 'email', v_email);
end $$;
revoke execute on function competencias.registrar_acceso_padre(text,text,date,text,text,text,text) from public, anon;
grant  execute on function competencias.registrar_acceso_padre(text,text,date,text,text,text,text) to authenticated;

-- 3) APROBAR / RECHAZAR al 2º padre: lo hace un padre aprobado o el organizador
create or replace function competencias.resolver_padre_pendiente(p_usuario uuid, p_jugador uuid, p_aprobar boolean)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
begin
  if not competencias.gestiona_perfil(p_jugador) then
    raise exception 'Solo un padre ya registrado o el organizador puede resolver esta solicitud';
  end if;
  if p_aprobar then
    update competencias.usuario_jugador
       set estado = 'aprobado', aprobado_por = auth.uid(), aprobado_at = now()
     where usuario_id = p_usuario and jugador_id = p_jugador and estado = 'pendiente';
  else
    delete from competencias.usuario_jugador
     where usuario_id = p_usuario and jugador_id = p_jugador and estado = 'pendiente';
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function competencias.resolver_padre_pendiente(uuid,uuid,boolean) from public, anon;
grant  execute on function competencias.resolver_padre_pendiente(uuid,uuid,boolean) to authenticated;

-- Solicitudes pendientes de un jugador (para el padre aprobado y el admin)
create or replace function competencias.padres_pendientes(p_jugador uuid)
returns table(usuario_id uuid, nombre text, telefono text, email text, created_at timestamptz)
language sql stable security definer
set search_path = competencias, public as $$
  select uj.usuario_id, uj.nombre, uj.telefono, au.email::text, uj.created_at
  from competencias.usuario_jugador uj
  left join auth.users au on au.id = uj.usuario_id
  where uj.jugador_id = p_jugador and uj.estado = 'pendiente'
    and competencias.gestiona_perfil(p_jugador)
  order by uj.created_at
$$;
revoke execute on function competencias.padres_pendientes(uuid) from public, anon;
grant  execute on function competencias.padres_pendientes(uuid) to authenticated;

-- Reporte de padres: incluye estado
drop function if exists competencias.reporte_padres(uuid);
create or replace function competencias.reporte_padres(p_marca uuid)
returns table(
  usuario_id uuid, email text, nombre text, telefono text, origen text, estado text,
  terminos_at timestamptz, registrado_at timestamptz,
  jugador_id uuid, jugador text, documento text, clubes text, perfil_token text,
  dni_frente_url text, dni_reverso_url text)
language sql stable security definer
set search_path = competencias, public as $$
  select uj.usuario_id,
         coalesce(au.email::text, up.email)           as email,
         uj.nombre, uj.telefono, uj.origen, uj.estado,
         uj.terminos_at, uj.created_at                as registrado_at,
         j.id, j.nombres || ' ' || j.apellidos,
         j.pais_documento || ' ' || j.nro_documento,
         (select string_agg(distinct cl.nombre, ' · ')
          from competencias.inscripcion_lbf i
          join competencias.equipo e on e.id = i.equipo_id
          join competencias.club cl  on cl.id = e.club_id
          join competencias.categoria c on c.id = i.categoria_id
          join competencias.torneo t on t.id = c.torneo_id
          where i.jugador_id = j.id and t.marca_id = p_marca),
         pj.token, uj.dni_frente_url, uj.dni_reverso_url
  from competencias.usuario_jugador uj
  join competencias.jugador_maestro j on j.id = uj.jugador_id
  left join competencias.perfil_jugador pj on pj.jugador_id = j.id
  left join competencias.usuario_perfil up on up.id = uj.usuario_id
  left join auth.users au on au.id = uj.usuario_id
  where competencias.es_admin_marca(p_marca)
    and exists (select 1 from competencias.inscripcion_lbf i
                join competencias.categoria c on c.id = i.categoria_id
                join competencias.torneo t on t.id = c.torneo_id
                where i.jugador_id = j.id and t.marca_id = p_marca)
  order by (uj.estado = 'pendiente') desc, uj.created_at desc
$$;
revoke execute on function competencias.reporte_padres(uuid) from public, anon;
grant  execute on function competencias.reporte_padres(uuid) to authenticated;

-- Confirmación: el propio usuario ve su estado (la Edge Function redacta según eso)
create or replace function competencias.datos_confirmacion_padre(p_jugador uuid)
returns jsonb language sql stable security definer
set search_path = competencias, public as $$
  select jsonb_build_object(
    'email',  (select email from auth.users where id = auth.uid()),
    'padre',  uj.nombre, 'estado', uj.estado,
    'jugador', j.nombres || ' ' || j.apellidos,
    'token',  p.token)
  from competencias.usuario_jugador uj
  join competencias.jugador_maestro j on j.id = uj.jugador_id
  join competencias.perfil_jugador  p on p.jugador_id = uj.jugador_id
  where uj.usuario_id = auth.uid() and uj.jugador_id = p_jugador
$$;

-- 4) AVISOS: destinatarios del aviso de nuevo registro. SOLO service_role
--    (la Edge Function lo llama con la clave de servicio; ningún usuario
--    puede leer emails de organizadores ni de otros padres).
create or replace function competencias.aviso_nuevo_padre(p_usuario uuid, p_jugador uuid)
returns jsonb language sql stable security definer
set search_path = competencias, public as $$
  select jsonb_build_object(
    'jugador', j.nombres || ' ' || j.apellidos,
    'token', p.token,
    'padre', jsonb_build_object('nombre', uj.nombre, 'telefono', uj.telefono,
                                'email', (select email from auth.users where id = uj.usuario_id),
                                'estado', uj.estado),
    'admins', coalesce((select jsonb_agg(distinct au.email)
               from competencias.inscripcion_lbf i
               join competencias.categoria c on c.id = i.categoria_id
               join competencias.torneo t on t.id = c.torneo_id
               join competencias.usuario_marca um on um.marca_id = t.marca_id and um.rol = 'admin_marca'
               join auth.users au on au.id = um.usuario_id
               where i.jugador_id = p_jugador), '[]'::jsonb),
    'otros_padres', coalesce((select jsonb_agg(distinct au.email)
               from competencias.usuario_jugador o
               join auth.users au on au.id = o.usuario_id
               where o.jugador_id = p_jugador and o.estado = 'aprobado' and o.usuario_id <> p_usuario), '[]'::jsonb))
  from competencias.usuario_jugador uj
  join competencias.jugador_maestro j on j.id = uj.jugador_id
  join competencias.perfil_jugador p on p.jugador_id = uj.jugador_id
  where uj.usuario_id = p_usuario and uj.jugador_id = p_jugador
$$;
revoke execute on function competencias.aviso_nuevo_padre(uuid,uuid) from public, anon, authenticated;
grant  execute on function competencias.aviso_nuevo_padre(uuid,uuid) to service_role;

notify pgrst, 'reload schema';

-- Verificación
select 'usuario_jugador.estado' as objeto, count(*) as existe from information_schema.columns
 where table_schema='competencias' and table_name='usuario_jugador' and column_name='estado'
union all
select 'intento_validacion_padre', count(*) from information_schema.tables
 where table_schema='competencias' and table_name='intento_validacion_padre'
union all
select 'aviso_nuevo_padre (service_role)', count(*) from pg_proc where proname='aviso_nuevo_padre';
