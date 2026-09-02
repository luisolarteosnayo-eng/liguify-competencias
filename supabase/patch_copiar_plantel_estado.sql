-- ============================================================================
-- ⬇ COPIAR PLANTEL: estado inteligente al copiar.
-- La autorización de padre/tutor es ÚNICA por jugador (vale en todos los
-- torneos), así que al copiar:
--   · torneo destino NO exige autorización            → ACTIVO
--   · el jugador YA tiene su autorización cargada     → ACTIVO
--   · exige autorización y el jugador no la tiene     → PENDIENTE
-- ============================================================================
create or replace function competencias.copiar_plantel(p_destino uuid, p_fuente uuid)
returns jsonb language plpgsql security definer
set search_path = competencias, public as $$
declare v_club text; v_club_f text; v_cat uuid; v_anio int; v_req boolean;
        v_total int; v_copiados int; v_activos int;
begin
  if not competencias.gestiona_equipo(p_destino) then
    raise exception 'No gestionas el equipo destino';
  end if;
  select competencias.norm_club(cl.nombre), e.categoria_id, c.anio_nacimiento,
         coalesce(t.requiere_autorizacion, false)
    into v_club, v_cat, v_anio, v_req
  from competencias.equipo e
  join competencias.club cl on cl.id = e.club_id
  join competencias.categoria c on c.id = e.categoria_id
  join competencias.torneo t on t.id = c.torneo_id
  where e.id = p_destino;
  select competencias.norm_club(cl.nombre) into v_club_f
  from competencias.equipo e join competencias.club cl on cl.id = e.club_id
  where e.id = p_fuente;
  if v_club_f is null or v_club_f <> v_club then
    raise exception 'La fuente no corresponde al mismo club';
  end if;
  if not competencias.acceso_club_fuente((select club_id from competencias.equipo where id = p_fuente)) then
    raise exception 'Sin acceso al club de origen';
  end if;
  select count(*) into v_total from competencias.inscripcion_lbf where equipo_id = p_fuente;
  insert into competencias.inscripcion_lbf
    (equipo_id, jugador_id, categoria_id, dorsal, capitan, en_lbf, estado,
     fecha_apto_medico, es_excepcion, origen)
  select p_destino, i.jugador_id, v_cat, i.dorsal, false, true,
         case when (not v_req) or j.autorizacion_url is not null then 'activo' else 'pendiente' end,
         case when (not v_req) or j.autorizacion_url is not null then current_date end,
         (extract(year from j.fecha_nacimiento)::int <> v_anio), 'maestra'
  from competencias.inscripcion_lbf i
  join competencias.jugador_maestro j on j.id = i.jugador_id
  where i.equipo_id = p_fuente
    and not exists (select 1 from competencias.inscripcion_lbf x
                    where x.jugador_id = i.jugador_id and x.categoria_id = v_cat);
  get diagnostics v_copiados = row_count;
  select count(*) into v_activos from competencias.inscripcion_lbf
  where equipo_id = p_destino and estado = 'activo';
  return jsonb_build_object('ok', true, 'copiados', v_copiados,
    'omitidos', v_total - v_copiados, 'activos', v_activos);
end $$;

notify pgrst, 'reload schema';

-- Arreglo de la copia que ya hiciste en NOVA CUP: activa a los copiados que
-- ya tienen autorización (o si su torneo no la exige)
update competencias.inscripcion_lbf i
   set estado = 'activo', fecha_apto_medico = current_date
from competencias.jugador_maestro j,
     competencias.categoria c join competencias.torneo t on t.id = c.torneo_id
where j.id = i.jugador_id and c.id = i.categoria_id
  and i.estado = 'pendiente' and i.origen = 'maestra'
  and ((not coalesce(t.requiere_autorizacion,false)) or j.autorizacion_url is not null);

-- Verificación: cuántos quedaron activos por el arreglo
select count(*) filter (where estado='activo') as activos,
       count(*) filter (where estado='pendiente') as pendientes
from competencias.inscripcion_lbf i
join competencias.categoria c on c.id = i.categoria_id
join competencias.torneo t on t.id = c.torneo_id
join competencias.marca m on m.id = t.marca_id
where m.nombre ilike '%NOVA%' and i.origen = 'maestra';
