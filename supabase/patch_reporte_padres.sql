-- ============================================================================
-- 👨‍👩‍👦 REPORTE DE PADRES DE FAMILIA (a nivel de marca) + limpieza de prueba
-- ============================================================================

-- 1) RPC: todos los padres registrados en perfiles de jugadores de la marca
--    (solo admin de la marca o super). Incluye datos de contacto, origen del
--    registro (auto = autoservicio / admin = asignado por el organizador),
--    fecha de aceptación de términos y rutas privadas de su DNI.
create or replace function competencias.reporte_padres(p_marca uuid)
returns table(
  usuario_id uuid, email text, nombre text, telefono text, origen text,
  terminos_at timestamptz, registrado_at timestamptz,
  jugador_id uuid, jugador text, documento text, clubes text, perfil_token text,
  dni_frente_url text, dni_reverso_url text)
language sql stable security definer
set search_path = competencias, public as $$
  select uj.usuario_id,
         coalesce(au.email::text, up.email)           as email,
         uj.nombre, uj.telefono, uj.origen,
         uj.terminos_at, uj.created_at                as registrado_at,
         j.id                                         as jugador_id,
         j.nombres || ' ' || j.apellidos              as jugador,
         j.pais_documento || ' ' || j.nro_documento   as documento,
         (select string_agg(distinct cl.nombre, ' · ')
          from competencias.inscripcion_lbf i
          join competencias.equipo e on e.id = i.equipo_id
          join competencias.club cl  on cl.id = e.club_id
          join competencias.categoria c on c.id = i.categoria_id
          join competencias.torneo t on t.id = c.torneo_id
          where i.jugador_id = j.id and t.marca_id = p_marca)  as clubes,
         pj.token                                     as perfil_token,
         uj.dni_frente_url, uj.dni_reverso_url
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
  order by uj.created_at desc
$$;
revoke execute on function competencias.reporte_padres(uuid) from public, anon;
grant  execute on function competencias.reporte_padres(uuid) to authenticated;

-- 2) LIMPIEZA DE PRUEBA: quitar a Luis como padre de Enzo Nicolás Mendoza
--    Torres (perfil e26aa3763244d153). Solo ese vínculo; nada más.
delete from competencias.usuario_jugador uj
using competencias.perfil_jugador pj, auth.users au
where pj.jugador_id = uj.jugador_id
  and pj.token = 'e26aa3763244d153'
  and au.id = uj.usuario_id
  and lower(au.email) = 'luisolarteosnayo@gmail.com';

notify pgrst, 'reload schema';

-- Verificación: padres que quedan en ese perfil (debe salir 0 filas)
select au.email, uj.nombre, uj.origen
from competencias.usuario_jugador uj
join competencias.perfil_jugador pj on pj.jugador_id = uj.jugador_id
left join auth.users au on au.id = uj.usuario_id
where pj.token = 'e26aa3763244d153';
