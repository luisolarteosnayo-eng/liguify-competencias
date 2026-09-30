-- ============================================================================
-- 💰 COBRANZAS ERP → MÓDULO CLUB + RECORDATORIO POR EMAIL
--  · El saldo se calcula con LA MISMA FÓRMULA del ERP:
--      cargos = Σ equipos.inscripcion (estado='activo')   [por club y torneo]
--      abonos = Σ pagos.monto (estado='aprobado')
--      saldo  = cargos − abonos
--  · mi_saldo_erp(): el COORDINADOR del club (módulo CLUB) ve su pago
--    pendiente por torneo, con detalle de equipos y pagos.
--  · cobranzas_pendientes(): SOLO service_role — la usa la Edge Function
--    enviar-cobranza para el recordatorio periódico por email.
--  · Configurable por marca: activar, día de la semana, monto mínimo,
--    CC al coordinador e instrucciones de pago (Yape/cuenta).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Configuración de cobranza por marca ------------------------------------
alter table competencias.marca
  add column if not exists cobranza_activa boolean not null default false,
  add column if not exists cobranza_dia smallint not null default 4,      -- 0=Dom 1=Lun … 4=Jue … 6=Sáb
  add column if not exists cobranza_min numeric not null default 20,      -- saldo mínimo para enviar (S/.)
  add column if not exists cobranza_cc_coordinador boolean not null default false,
  add column if not exists cobranza_instrucciones text;                   -- "Yape 9xx · BCP xxx-xxx"

-- 2) Log de avisos enviados (auditoría + no repetir en la misma semana) ------
create table if not exists competencias.cobranza_aviso (
  id          bigint generated always as identity primary key,
  marca_id    uuid not null references competencias.marca(id) on delete cascade,
  club_id     uuid references competencias.club(id) on delete set null,
  erp_club_id bigint,
  email       text not null,
  saldo       numeric not null,
  detalle     jsonb,
  enviado_at  timestamptz not null default now()
);
alter table competencias.cobranza_aviso enable row level security;
drop policy if exists cobr_aviso_admin on competencias.cobranza_aviso;
create policy cobr_aviso_admin on competencias.cobranza_aviso
  for select using (competencias.es_admin_marca(marca_id));
-- (escritura: solo service_role, que omite RLS)

-- 3) Núcleo: saldos de TODOS los clubes de una organización del ERP ----------
--    (interna: sin grants; la usan las funciones de abajo)
create or replace function competencias.erp_saldos(p_org bigint)
returns table(erp_club_id bigint, club_nombre text, club_email text,
              erp_torneo_id bigint, torneo text,
              cargos numeric, abonos numeric, saldo numeric, equipos jsonb)
language sql security definer stable
set search_path = public, competencias as $$
  with car as (
    select e.club_id, e.torneo_id,
           sum(coalesce(e.inscripcion,0)) as cargos,
           jsonb_agg(jsonb_build_object(
             'categoria', cat.nombre,
             'equipo', coalesce(nullif(trim(e.nombre),''), cat.nombre),
             'monto', coalesce(e.inscripcion,0)) order by cat.nombre) as det
    from public.equipos e
    join public.categorias cat on cat.id = e.cat_id
    where e.org_id = p_org and e.estado = 'activo'
    group by e.club_id, e.torneo_id
  ),
  ab as (
    select p.club_id, p.torneo_id, sum(p.monto) as abonos
    from public.pagos p
    where p.org_id = p_org and p.estado = 'aprobado' and p.club_id is not null
    group by p.club_id, p.torneo_id
  )
  select c.id, c.nombre, c.email, t.id, t.nombre,
         coalesce(car.cargos,0), coalesce(ab.abonos,0),
         coalesce(car.cargos,0) - coalesce(ab.abonos,0),
         coalesce(car.det,'[]'::jsonb)
  from car
  full join ab on ab.club_id = car.club_id and ab.torneo_id = car.torneo_id
  join public.clubes  c on c.id = coalesce(car.club_id,  ab.club_id)
  join public.torneos t on t.id = coalesce(car.torneo_id, ab.torneo_id)
$$;
revoke execute on function competencias.erp_saldos(bigint) from public, anon, authenticated;

-- 4) Módulo CLUB: el coordinador ve el saldo de SUS clubes -------------------
create or replace function competencias.mi_saldo_erp()
returns table(marca text, club text, torneo text,
              cargos numeric, abonos numeric, saldo numeric,
              equipos jsonb, instrucciones text)
language sql security definer stable
set search_path = competencias, public as $$
  select mk.nombre, cl.nombre, s.torneo, s.cargos, s.abonos, s.saldo,
         s.equipos, mk.cobranza_instrucciones
  from competencias.usuario_club uc
  join competencias.club  cl on cl.id = uc.club_id and cl.erp_club_id is not null
  join competencias.marca mk on mk.id = cl.marca_id and mk.erp_org_id is not null
  cross join lateral competencias.erp_saldos(mk.erp_org_id) s
  where uc.usuario_id = auth.uid() and uc.rol = 'coordinador'
    and s.erp_club_id = cl.erp_club_id
  order by mk.nombre, s.torneo
$$;
revoke execute on function competencias.mi_saldo_erp() from public, anon;
grant  execute on function competencias.mi_saldo_erp() to authenticated;

-- 5) Para la Edge Function (SOLO service_role): clubes a recordar HOY --------
create or replace function competencias.cobranzas_pendientes()
returns table(marca_id uuid, marca text, club_id uuid, erp_club_id bigint,
              club text, email text, cc_email text,
              saldo_total numeric, detalle jsonb, instrucciones text)
language sql security definer stable
set search_path = competencias, public as $$
  with base as (
    select mk.id as marca_id, mk.nombre as marca, cl.id as club_id,
           cl.erp_club_id, cl.nombre as club,
           coalesce(nullif(trim(cl.contacto_email),''), s.club_email) as email,
           mk.cobranza_cc_coordinador, mk.cobranza_min, mk.cobranza_instrucciones,
           s.torneo, s.cargos, s.abonos, s.saldo, s.equipos
    from competencias.marca mk
    join competencias.club cl on cl.marca_id = mk.id and cl.erp_club_id is not null
    cross join lateral competencias.erp_saldos(mk.erp_org_id) s
    where mk.cobranza_activa and mk.erp_org_id is not null
      and mk.cobranza_dia = extract(dow from (now() at time zone 'America/Lima'))::int
      and s.erp_club_id = cl.erp_club_id
  )
  select b.marca_id, b.marca, b.club_id, b.erp_club_id, b.club, b.email,
         case when b.cobranza_cc_coordinador then
           (select up.email from competencias.usuario_club uc
            join competencias.usuario_perfil up on up.id = uc.usuario_id
            where uc.club_id = b.club_id and uc.rol = 'coordinador' limit 1) end,
         sum(b.saldo),
         jsonb_agg(jsonb_build_object('torneo',b.torneo,'cargos',b.cargos,
           'abonos',b.abonos,'saldo',b.saldo,'equipos',b.equipos) order by b.torneo),
         min(b.cobranza_instrucciones)
  from base b
  where b.email is not null
  group by b.marca_id, b.marca, b.club_id, b.erp_club_id, b.club, b.email,
           b.cobranza_cc_coordinador, b.cobranza_min
  having sum(b.saldo) >= min(b.cobranza_min)
     and not exists (select 1 from competencias.cobranza_aviso a
                     where a.marca_id = b.marca_id and a.erp_club_id = b.erp_club_id
                       and a.enviado_at > now() - interval '6 days')
$$;
revoke execute on function competencias.cobranzas_pendientes() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- 6) ⏰ PROGRAMACIÓN (ejecutar UNA sola vez, después de desplegar la función
--    enviar-cobranza y de crear su secreto COBRANZA_KEY):
--    reemplaza <<CLAVE>> por el MISMO valor del secreto COBRANZA_KEY.
-- create extension if not exists pg_cron;
-- create extension if not exists pg_net;
-- select cron.schedule('cobranzas-diarias','0 14 * * *',   -- 09:00 hora Perú, todos los días
-- $$ select net.http_post(
--      url     := 'https://bpsczjjomgzhnjxnzmhj.supabase.co/functions/v1/enviar-cobranza',
--      headers := jsonb_build_object('Content-Type','application/json','x-cobranza-key','<<CLAVE>>'),
--      body    := '{}'::jsonb) $$);
-- Para detenerlo:  select cron.unschedule('cobranzas-diarias');

-- VERIFICACIÓN
select 'mi_saldo_erp' as objeto, count(*)::text as existe from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='competencias' and p.proname='mi_saldo_erp'
union all
select 'cobranzas_pendientes', count(*)::text from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='competencias' and p.proname='cobranzas_pendientes'
union all
select 'tabla cobranza_aviso', count(*)::text from information_schema.tables
  where table_schema='competencias' and table_name='cobranza_aviso'
union all
select 'config marca (5 columnas)', count(*)::text from information_schema.columns
  where table_schema='competencias' and table_name='marca' and column_name like 'cobranza%';
