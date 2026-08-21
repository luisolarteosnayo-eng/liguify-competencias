-- ============================================================================
-- REGISTRO DE PADRES EN EL PERFIL DEL JUGADOR (autoservicio · piloto)
--
-- Flujo (jugador.html → ACCESO PADRES):
--   1) El padre entra con su email (Google o email+contraseña).
--   2) Valida DNI + fecha de nacimiento del jugador (contra la BD, sin
--      revelar datos; 'coincide o no coincide').
--   3) Acepta términos y condiciones (queda fecha de aceptación).
--   4) Registra su nombre, teléfono (obligatorio) y foto de SU DNI por ambos
--      lados (bucket PRIVADO 'documentos', carpeta padres/).
--   5) El acceso se aprueba y se le envía el email de confirmación
--      (Edge Function enviar-confirmacion-padre).
--
-- PILOTO: solo jugadores de los clubes SPORTING CRISTAL BASE y TALES ACADEMY
-- (lista en club_piloto_perfil; agregar clubes = editar esa función).
-- ============================================================================

-- 1) Datos del padre en su vínculo con el jugador
alter table competencias.usuario_jugador
  add column if not exists nombre          text,
  add column if not exists telefono        text,
  add column if not exists dni_frente_url  text,   -- ruta en bucket PRIVADO 'documentos'
  add column if not exists dni_reverso_url text,
  add column if not exists terminos_at     timestamptz,
  add column if not exists origen          text not null default 'admin'
      check (origen in ('admin','auto'));

-- 2) DNI del padre: carpeta propia en el bucket privado
do $$ begin
  create policy documentos_padres_ins on storage.objects for insert to authenticated
    with check (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'padres');
exception when duplicate_object then null; end $$;

-- 3) ¿El jugador pertenece a un club del piloto?
create or replace function competencias.club_piloto_perfil(p_jugador uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (
    select 1
    from inscripcion_lbf i
    join equipo e on e.id = i.equipo_id
    join club  cl on cl.id = e.club_id
    where i.jugador_id = p_jugador
      and competencias.norm_txt(cl.nombre) in
          ('sporting cristal base', 'tales academy')   -- PILOTO: ampliar aquí
  )
$$;
revoke execute on function competencias.club_piloto_perfil(uuid) from public, anon;
grant  execute on function competencias.club_piloto_perfil(uuid) to authenticated;

-- 4) Paso 1: validar DNI + fecha de nacimiento del jugador (sin revelar datos)
create or replace function competencias.validar_jugador_padre(p_token text, p_doc text, p_fnac date)
returns jsonb language plpgsql stable security definer
set search_path = competencias, public as $$
declare v_jug uuid; v_ok boolean;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select jugador_id into v_jug from competencias.perfil_jugador
  where token = p_token and habilitado;
  if v_jug is null then return jsonb_build_object('ok', false, 'msg', 'Perfil no disponible'); end if;
  if not competencias.club_piloto_perfil(v_jug) then
    return jsonb_build_object('ok', false, 'msg', 'El registro de padres aún no está disponible para este club (etapa piloto)');
  end if;
  select (j.nro_documento = trim(p_doc) and j.fecha_nacimiento = p_fnac) into v_ok
  from competencias.jugador_maestro j where j.id = v_jug;
  if not coalesce(v_ok,false) then
    return jsonb_build_object('ok', false, 'msg', 'Los datos no coinciden con el jugador. Verifica el N° de documento y la fecha de nacimiento.');
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function competencias.validar_jugador_padre(text,text,date) from public, anon;
grant  execute on function competencias.validar_jugador_padre(text,text,date) to authenticated;

-- 5) Paso final: registrar al padre y aprobar el acceso
create or replace function competencias.registrar_acceso_padre(
  p_token text, p_doc text, p_fnac date,
  p_nombre text, p_telefono text, p_dni_frente text, p_dni_reverso text)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_jug uuid; v_ok boolean; v_email text; v_nom_jug text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  -- re-validación completa en el servidor (no confiar en los pasos del cliente)
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
  select email into v_email from auth.users where id = auth.uid();
  insert into competencias.usuario_perfil(id, email, nombre)
    values (auth.uid(), coalesce(v_email,''), trim(p_nombre))
    on conflict (id) do nothing;
  insert into competencias.usuario_jugador
    (usuario_id, jugador_id, nombre, telefono, dni_frente_url, dni_reverso_url, terminos_at, origen)
  values (auth.uid(), v_jug, trim(p_nombre), trim(p_telefono), p_dni_frente, p_dni_reverso, now(), 'auto')
  on conflict (usuario_id, jugador_id) do update set
    nombre = excluded.nombre, telefono = excluded.telefono,
    dni_frente_url = excluded.dni_frente_url, dni_reverso_url = excluded.dni_reverso_url,
    terminos_at = coalesce(usuario_jugador.terminos_at, now());
  return jsonb_build_object('ok', true, 'jugador', v_nom_jug, 'jugador_id', v_jug, 'email', v_email);
end $$;
revoke execute on function competencias.registrar_acceso_padre(text,text,date,text,text,text,text) from public, anon;
grant  execute on function competencias.registrar_acceso_padre(text,text,date,text,text,text,text) to authenticated;

-- 6) Para la Edge Function del email de confirmación: valida con el token del
--    usuario que el acceso exista y devuelve lo mínimo para redactar el correo.
create or replace function competencias.datos_confirmacion_padre(p_jugador uuid)
returns jsonb language sql stable security definer
set search_path = competencias, public as $$
  select jsonb_build_object(
    'email',  (select email from auth.users where id = auth.uid()),
    'padre',  uj.nombre,
    'jugador', j.nombres || ' ' || j.apellidos,
    'token',  p.token)
  from competencias.usuario_jugador uj
  join competencias.jugador_maestro j on j.id = uj.jugador_id
  join competencias.perfil_jugador  p on p.jugador_id = uj.jugador_id
  where uj.usuario_id = auth.uid() and uj.jugador_id = p_jugador
$$;
revoke execute on function competencias.datos_confirmacion_padre(uuid) from public, anon;
grant  execute on function competencias.datos_confirmacion_padre(uuid) to authenticated;

-- 7) PILOTO: habilitar el perfil de TODOS los jugadores de los dos clubes
--    (idempotente: los que ya tienen perfil no se tocan)
insert into competencias.perfil_jugador (jugador_id)
select distinct i.jugador_id
from competencias.inscripcion_lbf i
join competencias.equipo e on e.id = i.equipo_id
join competencias.club cl  on cl.id = e.club_id
where competencias.norm_txt(cl.nombre) in ('sporting cristal base','tales academy')
on conflict (jugador_id) do nothing;

notify pgrst, 'reload schema';

-- Verificación: perfiles habilitados por club del piloto
select cl.nombre as club, count(distinct pj.jugador_id) as perfiles
from competencias.perfil_jugador pj
join competencias.inscripcion_lbf i on i.jugador_id = pj.jugador_id
join competencias.equipo e on e.id = i.equipo_id
join competencias.club cl  on cl.id = e.club_id
where competencias.norm_txt(cl.nombre) in ('sporting cristal base','tales academy')
group by cl.nombre;
