-- T3 (diseño original): la foto del jugador SIEMPRE se ve en el público,
-- en BLANCO Y NEGRO mientras no haya consentimiento de imagen (antes se
-- ocultaba por completo). Las vistas encadenadas heredan el cambio.
create or replace view competencias.vista_jugador_publico as
select j.id, j.nombres, j.apellidos,
       extract(year from j.fecha_nacimiento)::int as anio_nacimiento,
       j.foto_url,
       j.consentimiento_imagen,   -- false ⇒ el frontend la muestra en B/N
       j.verificado,
       j.pie_habil, j.posicion,
       extract(month from j.fecha_nacimiento)::int as mes_nacimiento
from competencias.jugador_maestro j;

-- Consentimiento de imagen: lo registra quien gestiona al jugador (admin/club)
create or replace function competencias.actualizar_consentimiento(p_jugador uuid, p_valor boolean)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para registrar el consentimiento de esta persona';
  end if;
  update competencias.jugador_maestro
  set consentimiento_imagen = p_valor,
      consentimiento_fecha  = case when p_valor then now() else null end
  where id = p_jugador;
end $$;
revoke execute on function competencias.actualizar_consentimiento(uuid,boolean) from public, anon;
grant  execute on function competencias.actualizar_consentimiento(uuid,boolean) to authenticated;

notify pgrst, 'reload schema';
