-- Documentos del torneo (reglamento, bases…): lectura pública, gestión del admin
create table if not exists competencias.torneo_documento (
  id         uuid primary key default gen_random_uuid(),
  torneo_id  uuid not null references competencias.torneo(id) on delete cascade,
  titulo     text not null,
  url        text not null,
  created_at timestamptz not null default now()
);
alter table competencias.torneo_documento enable row level security;
drop policy if exists td_read on competencias.torneo_documento;
create policy td_read on competencias.torneo_documento for select using (true);
drop policy if exists td_write on competencias.torneo_documento;
create policy td_write on competencias.torneo_documento for all
  using (competencias.es_admin_marca((select marca_id from competencias.torneo t where t.id = torneo_id)))
  with check (competencias.es_admin_marca((select marca_id from competencias.torneo t where t.id = torneo_id)));
grant select on competencias.torneo_documento to anon, authenticated;
grant insert, update, delete on competencias.torneo_documento to authenticated;

notify pgrst, 'reload schema';
