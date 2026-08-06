-- ============================================================================
-- PATCH: FOTOS DEL DOCUMENTO (frontal y reverso) — storage PRIVADO (T7)
-- El DNI nunca va al bucket público: bucket 'documentos' (privado), se guarda
-- la RUTA y se visualiza con URL firmada temporal (solo autenticados).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Bucket privado
insert into storage.buckets (id, name, public)
values ('documentos', 'documentos', false)
on conflict (id) do nothing;

-- 2) Políticas: autenticados suben/reemplazan/leen bajo documentos/jugadores/
do $$ begin
  create policy documentos_jug_ins on storage.objects for insert to authenticated
    with check (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'jugadores');
exception when duplicate_object then null; end $$;
do $$ begin
  create policy documentos_jug_upd on storage.objects for update to authenticated
    using (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'jugadores')
    with check (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'jugadores');
exception when duplicate_object then null; end $$;
do $$ begin
  create policy documentos_jug_read on storage.objects for select to authenticated
    using (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'jugadores');
exception when duplicate_object then null; end $$;

-- 3) Guardar las rutas en la maestra (mismo alcance que la foto del jugador)
create or replace function competencias.actualizar_docs_jugador(p_jugador uuid, p_frente text, p_reverso text)
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
    raise exception 'Sin permiso para actualizar los documentos de este jugador';
  end if;
  update competencias.jugador_maestro set
    doc_scan_frente_url  = coalesce(p_frente,  doc_scan_frente_url),
    doc_scan_reverso_url = coalesce(p_reverso, doc_scan_reverso_url)
  where id = p_jugador;
end $$;

revoke execute on function competencias.actualizar_docs_jugador(uuid,text,text) from public, anon;
grant  execute on function competencias.actualizar_docs_jugador(uuid,text,text) to authenticated;

notify pgrst, 'reload schema';
