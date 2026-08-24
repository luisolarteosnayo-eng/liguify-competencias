-- ============================================================================
-- REGISTRO DE PADRES · SEGURIDAD NIVEL 2: VALIDACIÓN DEL TELÉFONO POR SMS
--
-- El padre debe verificar su celular con un código de 6 dígitos antes de
-- completar el registro:
--   1) El navegador llama a la Edge Function enviar-sms-padre (con su sesión).
--   2) La función crea el código vía crear_codigo_sms (SOLO service_role:
--      el código en claro nunca llega al navegador) y lo envía por Twilio.
--   3) El padre digita el código → verificar_codigo_sms (usuario autenticado).
--   4) registrar_acceso_padre EXIGE un teléfono verificado en las últimas 24h.
--
-- Límites: 3 envíos/hora por usuario Y por teléfono · código vence en 10 min
-- · máximo 5 intentos de verificación por código. Solo celulares de Perú
-- (+51, 9 dígitos, empieza con 9). Los hashes se guardan, nunca el código.
-- ============================================================================

-- 1) Normalización del celular peruano → E.164 (+519########) o NULL
create or replace function competencias.norm_telefono_pe(t text)
returns text language sql immutable as $$
  select case
    when d ~ '^519[0-9]{8}$' then '+' || d
    when d ~ '^9[0-9]{8}$'   then '+51' || d
    else null end
  from (select regexp_replace(coalesce(t,''), '[^0-9]', '', 'g')) x(d)
$$;

-- 2) Códigos (RLS cerrado: nadie lee la tabla directamente)
create table if not exists competencias.codigo_sms (
  id            uuid primary key default gen_random_uuid(),
  usuario_id    uuid not null,
  telefono      text not null,           -- E.164
  codigo_hash   text not null,
  creado_at     timestamptz not null default now(),
  expira_at     timestamptz not null,
  intentos      int  not null default 0,
  verificado_at timestamptz
);
create index if not exists ix_codigo_sms_usuario on competencias.codigo_sms(usuario_id, creado_at desc);
create index if not exists ix_codigo_sms_tel     on competencias.codigo_sms(telefono, creado_at desc);
alter table competencias.codigo_sms enable row level security;
revoke all on competencias.codigo_sms from public, anon, authenticated;

-- 3) CREAR código · SOLO service_role (lo llama la Edge Function)
create or replace function competencias.crear_codigo_sms(p_usuario uuid, p_telefono text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_tel text; v_cod text; v_env_usr int; v_env_tel int;
begin
  v_tel := competencias.norm_telefono_pe(p_telefono);
  if v_tel is null then
    return jsonb_build_object('ok', false, 'msg', 'Número inválido: debe ser un celular peruano de 9 dígitos que empiece con 9.');
  end if;
  select count(*) into v_env_usr from competencias.codigo_sms
   where usuario_id = p_usuario and creado_at > now() - interval '1 hour';
  select count(*) into v_env_tel from competencias.codigo_sms
   where telefono = v_tel and creado_at > now() - interval '1 hour';
  if v_env_usr >= 3 or v_env_tel >= 3 then
    return jsonb_build_object('ok', false, 'msg', 'Límite de envíos alcanzado. Espera una hora y vuelve a intentar.');
  end if;
  v_cod := lpad(floor(random()*1000000)::text, 6, '0');
  insert into competencias.codigo_sms (usuario_id, telefono, codigo_hash, expira_at)
  values (p_usuario, v_tel, md5(v_cod || p_usuario::text), now() + interval '10 minutes');
  return jsonb_build_object('ok', true, 'telefono', v_tel, 'codigo', v_cod);
end $$;
revoke execute on function competencias.crear_codigo_sms(uuid, text) from public, anon, authenticated;
grant  execute on function competencias.crear_codigo_sms(uuid, text) to service_role;

-- 4) VERIFICAR código · usuario autenticado
create or replace function competencias.verificar_codigo_sms(p_telefono text, p_codigo text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_tel text; v_row competencias.codigo_sms%rowtype;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  v_tel := competencias.norm_telefono_pe(p_telefono);
  if v_tel is null then return jsonb_build_object('ok', false, 'msg', 'Número inválido'); end if;
  select * into v_row from competencias.codigo_sms
   where usuario_id = auth.uid() and telefono = v_tel and verificado_at is null
   order by creado_at desc limit 1;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'msg', 'Primero solicita el código con ENVIAR CÓDIGO.');
  end if;
  if v_row.expira_at < now() then
    return jsonb_build_object('ok', false, 'msg', 'El código venció (10 min). Solicita uno nuevo.');
  end if;
  if v_row.intentos >= 5 then
    return jsonb_build_object('ok', false, 'msg', 'Demasiados intentos con este código. Solicita uno nuevo.');
  end if;
  update competencias.codigo_sms set intentos = intentos + 1 where id = v_row.id;
  if v_row.codigo_hash <> md5(trim(coalesce(p_codigo,'')) || auth.uid()::text) then
    return jsonb_build_object('ok', false, 'msg', 'Código incorrecto. Revisa el SMS e inténtalo de nuevo.');
  end if;
  update competencias.codigo_sms set verificado_at = now() where id = v_row.id;
  return jsonb_build_object('ok', true, 'telefono', v_tel);
end $$;
revoke execute on function competencias.verificar_codigo_sms(text, text) from public, anon;
grant  execute on function competencias.verificar_codigo_sms(text, text) to authenticated;

-- 5) ¿Teléfono verificado por este usuario en las últimas 24 h?
create or replace function competencias.sms_verificado(p_usuario uuid, p_telefono text)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (select 1 from competencias.codigo_sms
                 where usuario_id = p_usuario
                   and telefono = competencias.norm_telefono_pe(p_telefono)
                   and verificado_at > now() - interval '24 hours')
$$;

-- 6) REGISTRAR: ahora exige el teléfono verificado por SMS.
--    (idéntica a la versión de nivel 1, salvo el bloque marcado NIVEL 2)
create or replace function competencias.registrar_acceso_padre(
  p_token text, p_doc text, p_fnac date,
  p_nombre text, p_telefono text, p_dni_frente text, p_dni_reverso text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_jug uuid; v_ok boolean; v_email text; v_nom_jug text; v_conf timestamptz;
        v_aprobados int; v_fallos int; v_estado text; v_tel text;
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
  -- ── NIVEL 2: teléfono normalizado y verificado por SMS ──────────────────
  v_tel := competencias.norm_telefono_pe(p_telefono);
  if v_tel is null then
    return jsonb_build_object('ok', false, 'msg', 'Número inválido: debe ser un celular peruano de 9 dígitos que empiece con 9.');
  end if;
  if not competencias.sms_verificado(auth.uid(), v_tel) then
    return jsonb_build_object('ok', false, 'codigo', 'SMS_NO_VERIFICADO',
      'msg', 'Verifica tu celular: pide el código por SMS y digítalo antes de completar el registro.');
  end if;
  -- ─────────────────────────────────────────────────────────────────────────
  if p_dni_frente is null or p_dni_reverso is null then
    return jsonb_build_object('ok', false, 'msg', 'Sube la foto de tu DNI por ambos lados');
  end if;
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
  values (auth.uid(), v_jug, trim(p_nombre), v_tel, p_dni_frente, p_dni_reverso, now(), 'auto', v_estado,
          case when v_estado = 'aprobado' then auth.uid() end, case when v_estado = 'aprobado' then now() end)
  on conflict (usuario_id, jugador_id) do update set
    nombre = excluded.nombre, telefono = excluded.telefono,
    dni_frente_url = excluded.dni_frente_url, dni_reverso_url = excluded.dni_reverso_url,
    terminos_at = coalesce(usuario_jugador.terminos_at, now());
  return jsonb_build_object('ok', true, 'estado', v_estado, 'jugador', v_nom_jug, 'jugador_id', v_jug, 'email', v_email);
end $$;

notify pgrst, 'reload schema';

-- Verificación
select 'codigo_sms' as objeto, count(*) as existe from information_schema.tables
 where table_schema='competencias' and table_name='codigo_sms'
union all
select 'crear_codigo_sms (service_role)', count(*) from pg_proc where proname='crear_codigo_sms'
union all
select 'verificar_codigo_sms', count(*) from pg_proc where proname='verificar_codigo_sms'
union all
select 'norm +51 ok', case when competencias.norm_telefono_pe('987 654 321')='+51987654321' then 1 else 0 end
union all
select 'norm inválido ok', case when competencias.norm_telefono_pe('123456') is null then 1 else 0 end;
