-- Storage: carpeta padres/ del bucket PRIVADO 'documentos' (DNI del padre).
-- Se completan las políticas (insert + update + lectura autenticada), igual
-- que la carpeta jugadores/. Idempotente.
do $$ begin
  create policy documentos_padres_ins on storage.objects for insert to authenticated
    with check (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'padres');
exception when duplicate_object then null; end $$;

do $$ begin
  create policy documentos_padres_upd on storage.objects for update to authenticated
    using (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'padres')
    with check (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'padres');
exception when duplicate_object then null; end $$;

do $$ begin
  create policy documentos_padres_read on storage.objects for select to authenticated
    using (bucket_id = 'documentos' and (storage.foldername(name))[1] = 'padres');
exception when duplicate_object then null; end $$;

-- Verificación: deben salir las 3 políticas de padres
select policyname, cmd
from pg_policies
where schemaname = 'storage' and tablename = 'objects' and policyname like 'documentos_padres%'
order by policyname;
