-- ============================================================================
--  Liguify Competencias — PRUEBA DE CONCEPTO de arquitectura multi-usuario
--  Ejecutar en Supabase SQL Editor (proyecto bpsczjjomgzhnjxnzmhj)
--
--  Crea el esquema `competencias` (aislado de `public`/ERP y de `academias`)
--  con un núcleo mínimo: marca → torneo → categoría → club → equipo → partido,
--  datos semilla de INTI CUP ORO, lectura pública y escritura de resultados.
--
--  ⚠ POLÍTICA "poc_write_partido": permite UPDATE anónimo SOLO en partido,
--    únicamente para esta prueba. BORRARLA antes de producción:
--    drop policy poc_write_partido on competencias.partido;
--
--  Re-ejecutable: borra y recrea SOLO el esquema competencias (no toca ERP ni academias).
-- ============================================================================

drop schema if exists competencias cascade;
create schema competencias;

-- ----------------------------------------------------------------------------
-- Tablas (núcleo mínimo del modelo verificado en ANALISIS_PUBLICO_ADMIN.md)
-- ----------------------------------------------------------------------------
create table competencias.marca (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  slug       text not null unique,
  created_at timestamptz not null default now()
);

create table competencias.torneo (
  id       uuid primary key default gen_random_uuid(),
  marca_id uuid not null references competencias.marca(id),
  nombre   text not null,
  anio     int  not null default 2026
);

create table competencias.categoria (
  id              uuid primary key default gen_random_uuid(),
  torneo_id       uuid not null references competencias.torneo(id),
  anio_nacimiento int  not null,
  modalidad       text not null check (modalidad in ('F7','F9','F11')),
  unique (torneo_id, anio_nacimiento, modalidad)   -- llave año + modalidad
);

create table competencias.club (
  id       uuid primary key default gen_random_uuid(),
  marca_id uuid not null references competencias.marca(id),  -- club ÚNICO POR MARCA (C1)
  nombre   text not null,
  color    text not null default '#1d4ed8',
  unique (marca_id, nombre)
);

create table competencias.equipo (
  id           uuid primary key default gen_random_uuid(),
  categoria_id uuid not null references competencias.categoria(id),
  club_id      uuid not null references competencias.club(id),
  nombre       text,              -- libre; null = nombre del club
  zona         text not null default 'A'
);

create table competencias.partido (
  id           uuid primary key default gen_random_uuid(),
  categoria_id uuid not null references competencias.categoria(id),
  zona         text not null default 'A',
  jornada      int  not null default 1,
  local_id     uuid not null references competencias.equipo(id),
  visita_id    uuid not null references competencias.equipo(id),
  goles_local  int,
  goles_visita int,
  estado       text not null default 'programado'
               check (estado in ('programado','en_vivo','finalizado','suspendido','walkover')),
  updated_at   timestamptz not null default now(),
  check (local_id <> visita_id)
);

-- ----------------------------------------------------------------------------
-- Permisos de API (PostgREST) + RLS
-- ----------------------------------------------------------------------------
grant usage on schema competencias to anon, authenticated;
grant select on all tables in schema competencias to anon, authenticated;
grant update (goles_local, goles_visita, estado, updated_at)
  on competencias.partido to anon, authenticated;

alter table competencias.marca     enable row level security;
alter table competencias.torneo    enable row level security;
alter table competencias.categoria enable row level security;
alter table competencias.club      enable row level security;
alter table competencias.equipo    enable row level security;
alter table competencias.partido   enable row level security;

-- Lectura pública (el módulo público lee sin login)
create policy poc_read on competencias.marca     for select using (true);
create policy poc_read on competencias.torneo    for select using (true);
create policy poc_read on competencias.categoria for select using (true);
create policy poc_read on competencias.club      for select using (true);
create policy poc_read on competencias.equipo    for select using (true);
create policy poc_read on competencias.partido   for select using (true);

-- ⚠ SOLO PARA LA PRUEBA: escritura anónima de resultados
create policy poc_write_partido on competencias.partido
  for update using (true) with check (true);

-- Realtime: los cambios en partido se empujan a los clientes suscritos
alter publication supabase_realtime add table competencias.partido;

-- ----------------------------------------------------------------------------
-- Datos semilla: INTI CUP ORO · Categoría 2017/F7 · Zona A
-- ----------------------------------------------------------------------------
do $$
declare
  v_marca uuid; v_torneo uuid; v_cat uuid;
  c_acar uuid; c_alsur uuid; c_sbsa uuid; c_amsmp uuid;
  e_acar uuid; e_alsur uuid; e_sbsa uuid; e_amsmp uuid;
begin
  insert into competencias.marca (nombre, slug) values ('INTI CUP','inticup') returning id into v_marca;
  insert into competencias.torneo (marca_id, nombre) values (v_marca,'INTI CUP ORO') returning id into v_torneo;
  insert into competencias.categoria (torneo_id, anio_nacimiento, modalidad) values (v_torneo, 2017,'F7') returning id into v_cat;

  insert into competencias.club (marca_id, nombre, color) values (v_marca,'ACAR','#1d4ed8') returning id into c_acar;
  insert into competencias.club (marca_id, nombre, color) values (v_marca,'Alianza Lima Surquillo','#d9232e') returning id into c_alsur;
  insert into competencias.club (marca_id, nombre, color) values (v_marca,'Sport Boys Sor Ana','#7c3aed') returning id into c_sbsa;
  insert into competencias.club (marca_id, nombre, color) values (v_marca,'Amigos SMP','#0d9488') returning id into c_amsmp;

  insert into competencias.equipo (categoria_id, club_id) values (v_cat, c_acar)  returning id into e_acar;
  insert into competencias.equipo (categoria_id, club_id) values (v_cat, c_alsur) returning id into e_alsur;
  insert into competencias.equipo (categoria_id, club_id) values (v_cat, c_sbsa)  returning id into e_sbsa;
  insert into competencias.equipo (categoria_id, club_id) values (v_cat, c_amsmp) returning id into e_amsmp;

  insert into competencias.partido (categoria_id, zona, jornada, local_id, visita_id, goles_local, goles_visita, estado)
  values (v_cat,'A',1, e_acar,  e_alsur, 2, 1, 'finalizado'),
         (v_cat,'A',1, e_sbsa,  e_amsmp, null, null, 'programado'),
         (v_cat,'A',2, e_acar,  e_sbsa,  null, null, 'programado'),
         (v_cat,'A',2, e_alsur, e_amsmp, null, null, 'programado');
end $$;

-- Verificación rápida
select 'OK: esquema competencias creado' as resultado,
       (select count(*) from competencias.partido) as partidos_semilla;
