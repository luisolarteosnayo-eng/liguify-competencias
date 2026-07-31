-- ============================================================================
-- FIX: recursión infinita (42P17) en políticas que consultan usuario_perfil
-- La política self_read de usuario_perfil se referenciaba a sí misma.
-- Solución: función es_super() SECURITY DEFINER (bypasa RLS, rompe el ciclo).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.es_super()
returns boolean language sql stable security definer
set search_path = competencias as $$
  select exists (select 1 from usuario_perfil where id = auth.uid() and es_super)
$$;
revoke execute on function competencias.es_super() from public, anon;
grant  execute on function competencias.es_super() to authenticated;

-- 1) usuario_perfil: leer mi propio perfil, o todos si soy super
drop policy if exists self_read on competencias.usuario_perfil;
create policy self_read on competencias.usuario_perfil for select
  using (id = auth.uid() or competencias.es_super());

-- 2) marca: crear solo super
drop policy if exists adm_ins on competencias.marca;
create policy adm_ins on competencias.marca for insert
  with check (competencias.es_super());

-- 3) jugador_maestro: editar solo si no verificado, o super (misma bomba latente)
drop policy if exists jug_upd on competencias.jugador_maestro;
create policy jug_upd on competencias.jugador_maestro for update
  using ((not verificado) or competencias.es_super());

-- 4) sancion_global: escribir solo super (misma bomba latente)
drop policy if exists super_all on competencias.sancion_global;
create policy super_all on competencias.sancion_global for all
  using (competencias.es_super()) with check (competencias.es_super());

notify pgrst, 'reload schema';
