-- ============================================================================
-- LICENCIA DEL ENTRENADOR (comando técnico)
-- Foto/imagen de la licencia en el bucket PRIVADO 'documentos' (igual que el
-- DNI: se guarda la RUTA y se visualiza con URL firmada temporal).
-- Única por persona (vale para todos los torneos); solo puede subirla quien
-- gestiona un equipo donde la persona es miembro del CT.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.jugador_maestro add column if not exists licencia_url text;

create or replace function competencias.actualizar_licencia_ct(p_persona uuid, p_ruta text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if coalesce(trim(p_ruta),'') = '' then
    raise exception 'Ruta de licencia inválida';
  end if;
  -- la licencia es del entrenador: exige pertenencia a un COMANDO TÉCNICO gestionado
  if not exists (select 1 from competencias.comando_tecnico ct
                 where ct.persona_id = p_persona
                   and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) then
    raise exception 'Sin permiso: la persona no está en un comando técnico que gestiones';
  end if;
  update competencias.jugador_maestro set licencia_url = p_ruta where id = p_persona;
end $$;

revoke execute on function competencias.actualizar_licencia_ct(uuid,text) from public, anon;
grant  execute on function competencias.actualizar_licencia_ct(uuid,text) to authenticated;

notify pgrst, 'reload schema';
