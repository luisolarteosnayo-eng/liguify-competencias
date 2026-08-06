-- ============================================================================
-- PATCH: FOTO DEL JUGADOR desde club y admin
-- La política de jugador_maestro solo permite editar si NO está verificado (o
-- super). Esta RPC permite actualizar SOLO la foto a quien tenga gestión LBF
-- sobre alguna inscripción del jugador (staff de marca, coordinador, delegado
-- de su equipo o sub-coordinador de su categoría).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.actualizar_foto_jugador(p_jugador uuid, p_url text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not exists (
    select 1
    from competencias.inscripcion_lbf i
    join competencias.equipo e on e.id = i.equipo_id
    where i.jugador_id = p_jugador
      and ( competencias.es_staff_marca(competencias.marca_de_categoria(i.categoria_id))
            or competencias.es_coordinador_club(e.club_id)
            or exists (select 1 from competencias.usuario_club uc
                       where uc.usuario_id = auth.uid() and uc.club_id = e.club_id
                         and uc.rol = 'delegado' and uc.equipo_id = e.id)
            or exists (select 1 from competencias.usuario_club_categoria ucc
                       where ucc.usuario_id = auth.uid() and ucc.club_id = e.club_id
                         and ucc.categoria_id = i.categoria_id) )
  ) then
    raise exception 'Sin permiso para actualizar la foto de este jugador';
  end if;
  update competencias.jugador_maestro set foto_url = p_url where id = p_jugador;
end $$;

revoke execute on function competencias.actualizar_foto_jugador(uuid,text) from public, anon;
grant  execute on function competencias.actualizar_foto_jugador(uuid,text) to authenticated;

-- Storage: permitir subir/reemplazar fotos bajo publico/jugadores/ (authenticated)
do $$ begin
  create policy competencias_pub_jugadores_ins on storage.objects for insert to authenticated
    with check (bucket_id = 'publico' and (storage.foldername(name))[1] = 'jugadores');
exception when duplicate_object then null; end $$;
do $$ begin
  create policy competencias_pub_jugadores_upd on storage.objects for update to authenticated
    using (bucket_id = 'publico' and (storage.foldername(name))[1] = 'jugadores')
    with check (bucket_id = 'publico' and (storage.foldername(name))[1] = 'jugadores');
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
