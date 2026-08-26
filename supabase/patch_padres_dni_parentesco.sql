-- ============================================================================
-- REGISTRO DE PADRES: se pide N° de DNI del responsable y PARENTESCO
-- (Padre / Madre / Otro). Obligatorios en el registro; visibles en el
-- reporte PADRES del admin y en las solicitudes pendientes del perfil.
-- ============================================================================

-- 1) Columnas
alter table competencias.usuario_jugador
  add column if not exists dni text,
  add column if not exists parentesco text;
do $$ begin
  alter table competencias.usuario_jugador
    add constraint usuario_jugador_parentesco_ck check (parentesco in ('Padre','Madre','Otro'));
exception when duplicate_object then null; end $$;

-- 2) REGISTRAR: nueva firma con p_dni y p_parentesco
drop function if exists competencias.registrar_acceso_padre(text,text,date,text,text,text,text);
create or replace function competencias.registrar_acceso_padre(
  p_token text, p_doc text, p_fnac date,
  p_nombre text, p_telefono text, p_dni_frente text, p_dni_reverso text,
  p_dni text, p_parentesco text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_jug uuid; v_ok boolean; v_email text; v_nom_jug text; v_conf timestamptz;
        v_aprobados int; v_fallos int; v_estado text; v_tel text; v_dni text;
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
    return jsonb_build_object('ok', false, 'msg', 'El registro de padres no está disponible para este club');
  end if;
  select (j.nro_documento = upper(trim(p_doc)) and j.fecha_nacimiento = p_fnac),
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
  -- ── NUEVO: parentesco y DNI del responsable ──────────────────────────────
  if coalesce(p_parentesco,'') not in ('Padre','Madre','Otro') then
    return jsonb_build_object('ok', false, 'msg', 'Indica si eres Padre, Madre u Otro responsable');
  end if;
  v_dni := upper(regexp_replace(coalesce(p_dni,''), '[^0-9A-Za-z]', '', 'g'));
  if v_dni !~ '^[0-9A-Z]{6,15}$' then
    return jsonb_build_object('ok', false, 'msg', 'Escribe tu N° de DNI (o carné de extranjería) válido');
  end if;
  -- ─────────────────────────────────────────────────────────────────────────
  v_tel := competencias.norm_telefono_pe(p_telefono);
  if v_tel is null then
    return jsonb_build_object('ok', false, 'msg', 'Número inválido: debe ser un celular peruano de 9 dígitos que empiece con 9.');
  end if;
  if not competencias.sms_verificado(auth.uid(), v_tel) then
    return jsonb_build_object('ok', false, 'codigo', 'SMS_NO_VERIFICADO',
      'msg', 'Verifica tu celular: pide el código por SMS y digítalo antes de completar el registro.');
  end if;
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
    (usuario_id, jugador_id, nombre, telefono, dni, parentesco,
     dni_frente_url, dni_reverso_url, terminos_at, origen, estado, aprobado_por, aprobado_at)
  values (auth.uid(), v_jug, trim(p_nombre), v_tel, v_dni, p_parentesco,
          p_dni_frente, p_dni_reverso, now(), 'auto', v_estado,
          case when v_estado = 'aprobado' then auth.uid() end, case when v_estado = 'aprobado' then now() end)
  on conflict (usuario_id, jugador_id) do update set
    nombre = excluded.nombre, telefono = excluded.telefono,
    dni = excluded.dni, parentesco = excluded.parentesco,
    dni_frente_url = excluded.dni_frente_url, dni_reverso_url = excluded.dni_reverso_url,
    terminos_at = coalesce(usuario_jugador.terminos_at, now());
  return jsonb_build_object('ok', true, 'estado', v_estado, 'jugador', v_nom_jug, 'jugador_id', v_jug, 'email', v_email);
end $$;
revoke execute on function competencias.registrar_acceso_padre(text,text,date,text,text,text,text,text,text) from public, anon;
grant  execute on function competencias.registrar_acceso_padre(text,text,date,text,text,text,text,text,text) to authenticated;

-- 3) Reporte PADRES: incluye dni y parentesco
drop function if exists competencias.reporte_padres(uuid);
create or replace function competencias.reporte_padres(p_marca uuid)
returns table(
  usuario_id uuid, email text, nombre text, telefono text, dni text, parentesco text,
  origen text, estado text, terminos_at timestamptz, registrado_at timestamptz,
  jugador_id uuid, jugador text, documento text, clubes text, perfil_token text,
  dni_frente_url text, dni_reverso_url text)
language sql stable security definer
set search_path = competencias, public as $$
  select uj.usuario_id,
         coalesce(au.email::text, up.email)           as email,
         uj.nombre, uj.telefono, uj.dni, uj.parentesco,
         uj.origen, uj.estado,
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

-- 4) Solicitudes pendientes: incluye dni y parentesco
drop function if exists competencias.padres_pendientes(uuid);
create or replace function competencias.padres_pendientes(p_jugador uuid)
returns table(usuario_id uuid, nombre text, telefono text, dni text, parentesco text, email text, created_at timestamptz)
language sql stable security definer
set search_path = competencias, public as $$
  select uj.usuario_id, uj.nombre, uj.telefono, uj.dni, uj.parentesco, au.email::text, uj.created_at
  from competencias.usuario_jugador uj
  left join auth.users au on au.id = uj.usuario_id
  where uj.jugador_id = p_jugador and uj.estado = 'pendiente'
    and competencias.gestiona_perfil(p_jugador)
  order by uj.created_at
$$;
revoke execute on function competencias.padres_pendientes(uuid) from public, anon;
grant  execute on function competencias.padres_pendientes(uuid) to authenticated;

notify pgrst, 'reload schema';

-- Verificación
select 'columnas dni/parentesco' as objeto,
       count(*) as existe from information_schema.columns
 where table_schema='competencias' and table_name='usuario_jugador'
   and column_name in ('dni','parentesco')
union all
select 'registrar_acceso_padre (9 args)', count(*) from pg_proc p
 join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='competencias' and p.proname='registrar_acceso_padre' and p.pronargs=9;
