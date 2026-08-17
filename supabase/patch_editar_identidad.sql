-- ============================================================================
-- CORREGIR ERRORES DE TIPEO EN LA IDENTIDAD DEL JUGADOR (nombres, apellidos,
-- fecha de nacimiento) desde el admin Y el módulo club.
-- Protección anti-suplantación: si la identidad ya está VERIFICADA, solo el
-- STAFF de la marca puede corregirla (el club edita solo no-verificados).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.actualizar_identidad_jugador(p_jugador uuid, p_nombres text, p_apellidos text, p_fecha date)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_verificado boolean;
begin
  if coalesce(trim(p_nombres),'') = '' or coalesce(trim(p_apellidos),'') = '' then
    raise exception 'Nombres y apellidos son obligatorios';
  end if;
  if p_fecha is null or p_fecha > current_date or p_fecha < date '1940-01-01' then
    raise exception 'Fecha de nacimiento inválida';
  end if;
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para editar los datos de esta persona';
  end if;
  select verificado into v_verificado from competencias.jugador_maestro where id = p_jugador;
  if coalesce(v_verificado,false) and not (
       exists (select 1 from competencias.inscripcion_lbf i
               where i.jugador_id = p_jugador
                 and competencias.es_staff_marca(competencias.marca_de_categoria(i.categoria_id)))
    or exists (select 1 from competencias.comando_tecnico ct
               where ct.persona_id = p_jugador
                 and competencias.es_staff_marca(competencias.marca_de_categoria(ct.categoria_id))) ) then
    raise exception 'Identidad VERIFICADA: solo el organizador puede corregirla';
  end if;
  update competencias.jugador_maestro
  set nombres = trim(p_nombres), apellidos = trim(p_apellidos), fecha_nacimiento = p_fecha
  where id = p_jugador;
end $$;

revoke execute on function competencias.actualizar_identidad_jugador(uuid,text,text,date) from public, anon;
grant  execute on function competencias.actualizar_identidad_jugador(uuid,text,text,date) to authenticated;

notify pgrst, 'reload schema';
