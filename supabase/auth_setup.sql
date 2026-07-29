-- ============================================================================
--  LIGUIFY COMPETENCIAS — Vinculación de usuarios reales + CIERRE de la
--  política temporal de escritura anónima.
--
--  1) Vincula a Luis (luisolarteosnayo@gmail.com) como SUPER-ADMIN de la
--     plataforma y ADMIN de la marca INTI CUP.
--  2) Vincula al usuario QA mesa@inticup.pe como MESA DE CONTROL de INTI CUP
--     (fixture de prueba, contraseña Liguify2026! — borrable a futuro).
--  3) BORRA la política poc_write_partido y revoca el UPDATE anónimo:
--     desde aquí, escribir requiere sesión con rol (RLS por marca).
-- ============================================================================

do $$
declare v_luis uuid; v_mesa uuid; v_marca uuid;
begin
  select id into v_marca from competencias.marca where slug = 'inticup';

  -- Luis: super-admin + admin de INTI CUP
  select id into v_luis from auth.users
  where lower(email) = 'luisolarteosnayo@gmail.com' order by created_at limit 1;
  if v_luis is not null then
    insert into competencias.usuario_perfil (id, email, nombre, es_super)
    values (v_luis, 'luisolarteosnayo@gmail.com', 'Luis Olarte', true)
    on conflict (id) do update set es_super = true, nombre = excluded.nombre;
    insert into competencias.usuario_marca (usuario_id, marca_id, rol)
    values (v_luis, v_marca, 'admin_marca') on conflict do nothing;
    update competencias.marca set owner_id = v_luis where id = v_marca;
  else
    raise notice 'AVISO: no existe auth.users para luisolarteosnayo@gmail.com';
  end if;

  -- Usuario QA de mesa de control
  select id into v_mesa from auth.users where lower(email) = 'mesa@inticup.pe' limit 1;
  if v_mesa is not null then
    insert into competencias.usuario_perfil (id, email, nombre)
    values (v_mesa, 'mesa@inticup.pe', 'Mesa de Control QA') on conflict (id) do nothing;
    insert into competencias.usuario_marca (usuario_id, marca_id, rol)
    values (v_mesa, v_marca, 'mesa_control') on conflict do nothing;
  else
    raise notice 'AVISO: aún no existe mesa@inticup.pe (créalo desde poc-sync.html y re-ejecuta)';
  end if;
end $$;

-- CIERRE de la puerta anónima
drop policy if exists poc_write_partido on competencias.partido;
revoke update on competencias.partido from anon;

notify pgrst, 'reload schema';

-- Verificación
select
  (select count(*) from pg_policies
    where schemaname='competencias' and tablename='partido'
      and policyname='poc_write_partido')                       as politica_poc_restante,  -- debe ser 0
  (select string_agg(up.email || ' → ' || um.rol, '  ·  ')
     from competencias.usuario_marca um
     join competencias.usuario_perfil up on up.id = um.usuario_id) as membresias;
