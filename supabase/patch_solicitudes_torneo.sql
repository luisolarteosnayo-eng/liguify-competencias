-- ============================================================================
-- REGISTRO PÚBLICO DE TORNEOS (leads) + BACKOFFICE DEL SUPER-ADMIN.
-- · En liguify.com cualquier organizador deja: nombre del torneo, contacto,
--   teléfono y el email con el que entrará al sistema (Google u otro).
-- · Solo el SUPER-ADMIN ve y gestiona las solicitudes (nueva → alta/baja/
--   descartada); al dar de alta se vincula con la marca creada.
-- · A futuro: estados de cuenta por marca colgarán de aquí.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create table if not exists competencias.solicitud_torneo (
  id            uuid primary key default gen_random_uuid(),
  nombre_torneo text not null check (char_length(nombre_torneo) between 2 and 80),
  contacto      text not null check (char_length(contacto) between 2 and 80),
  telefono      text not null check (char_length(telefono) between 6 and 25),
  email         text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 120),
  estado        text not null default 'nueva' check (estado in ('nueva','alta','baja','descartada')),
  marca_id      uuid references competencias.marca(id),   -- se llena al dar de alta
  nota          text,                                     -- notas internas del super-admin
  created_at    timestamptz not null default now(),
  atendida_at   timestamptz
);

alter table competencias.solicitud_torneo enable row level security;
create policy sol_ins_publica on competencias.solicitud_torneo for insert
  to anon, authenticated with check (true);
create policy sol_super_read on competencias.solicitud_torneo for select
  using (competencias.es_super());
create policy sol_super_upd on competencias.solicitud_torneo for update
  using (competencias.es_super()) with check (competencias.es_super());

grant insert on competencias.solicitud_torneo to anon, authenticated;
grant select, update on competencias.solicitud_torneo to authenticated;

notify pgrst, 'reload schema';
