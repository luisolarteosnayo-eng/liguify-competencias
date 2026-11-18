-- ============================================================================
-- 💰 REPORTE DE DEUDA DE JUGADOR (deuda con su club)
-- El CLUB reporta la deuda de un jugador (monto + comentario). Mientras la
-- deuda exista, el jugador NO puede inscribirse en los torneos de la marca
-- que tengan activo el control — hasta que el club la elimine (lo habilita).
--  · torneo.deuda_club_asigna: el club puede asignar/eliminar deudas (UI CLUB)
--  · torneo.deuda_control: al inscribir en LBF se valida la deuda (trigger)
--  · club.vip: ⭐ clubes VIP EXENTOS del control (pueden inscribir jugadores
--    con deuda de otros clubes)
--  · El staff de la marca siempre puede inscribir (canal de excepción).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

alter table competencias.torneo
  add column if not exists deuda_club_asigna boolean not null default false,
  add column if not exists deuda_control boolean not null default false;
alter table competencias.club add column if not exists vip boolean not null default false;

create table if not exists competencias.deuda_jugador(
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references competencias.club(id) on delete cascade,
  jugador_id uuid not null references competencias.jugador_maestro(id) on delete cascade,
  monto      numeric not null default 0,
  comentario text,
  creada_por uuid,
  created_at timestamptz not null default now(),
  unique(club_id, jugador_id)        -- una deuda vigente por club y jugador
);

-- ¿El usuario gestiona este club? (coordinador, o subcoordinador del club)
create or replace function competencias.es_miembro_club(p_club uuid)
returns boolean language sql stable security definer
set search_path = competencias, public as $$
  select exists (select 1 from competencias.usuario_club uc
                 where uc.club_id = p_club and uc.usuario_id = auth.uid()
                   and uc.rol = 'coordinador')
      or exists (select 1 from competencias.usuario_club_categoria x
                 where x.club_id = p_club and x.usuario_id = auth.uid())
$$;

alter table competencias.deuda_jugador enable row level security;
drop policy if exists dj_sel on competencias.deuda_jugador;
drop policy if exists dj_ins on competencias.deuda_jugador;
drop policy if exists dj_upd on competencias.deuda_jugador;
drop policy if exists dj_del on competencias.deuda_jugador;
create policy dj_sel on competencias.deuda_jugador for select to authenticated
  using ( competencias.es_miembro_club(club_id)
       or competencias.es_staff_marca((select marca_id from competencias.club c where c.id = club_id)) );
create policy dj_ins on competencias.deuda_jugador for insert to authenticated
  with check ( competencias.es_miembro_club(club_id)
       or competencias.es_staff_marca((select marca_id from competencias.club c where c.id = club_id)) );
create policy dj_upd on competencias.deuda_jugador for update to authenticated
  using ( competencias.es_miembro_club(club_id)
       or competencias.es_staff_marca((select marca_id from competencias.club c where c.id = club_id)) );
create policy dj_del on competencias.deuda_jugador for delete to authenticated
  using ( competencias.es_miembro_club(club_id)
       or competencias.es_staff_marca((select marca_id from competencias.club c where c.id = club_id)) );
grant select, insert, update, delete on competencias.deuda_jugador to authenticated;

-- 🔒 CONTROL: bloquea la inscripción en LBF si el jugador tiene deuda con
-- algún club de la marca (torneos con deuda_control). VIP y staff exentos.
create or replace function competencias.impedir_inscripcion_con_deuda()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
declare v_ctl boolean; v_marca uuid; v_vip boolean; v_acreedor text;
begin
  select t.deuda_control, t.marca_id into v_ctl, v_marca
  from competencias.categoria c
  join competencias.torneo t on t.id = c.torneo_id
  where c.id = new.categoria_id;
  if not coalesce(v_ctl,false) then return new; end if;
  if auth.uid() is null then return new; end if;                   -- service/procesos
  if competencias.es_staff_marca(v_marca) then return new; end if; -- 👑 admin decide
  select cl.vip into v_vip
  from competencias.equipo e join competencias.club cl on cl.id = e.club_id
  where e.id = new.equipo_id;
  if coalesce(v_vip,false) then return new; end if;                -- ⭐ club VIP exento
  select cl.nombre into v_acreedor
  from competencias.deuda_jugador d
  join competencias.club cl on cl.id = d.club_id and cl.marca_id = v_marca
  where d.jugador_id = new.jugador_id
  order by d.created_at limit 1;
  if v_acreedor is not null then
    raise exception 'El jugador no puede registrarse, por deuda con el CLUB %. Mientras esta deuda no se elimine, el jugador no podrá registrarse.', v_acreedor;
  end if;
  return new;
end $$;
drop trigger if exists t_control_deuda on competencias.inscripcion_lbf;
create trigger t_control_deuda before insert on competencias.inscripcion_lbf
for each row execute function competencias.impedir_inscripcion_con_deuda();

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'tabla deuda_jugador' as objeto, count(*)::text as existe
from information_schema.tables where table_schema='competencias' and table_name='deuda_jugador'
union all
select 'trigger t_control_deuda', count(*)::text from pg_trigger where tgname='t_control_deuda'
union all
select 'torneo (2 columnas deuda)', count(*)::text from information_schema.columns
where table_schema='competencias' and table_name='torneo' and column_name like 'deuda%'
union all
select 'club.vip', count(*)::text from information_schema.columns
where table_schema='competencias' and table_name='club' and column_name='vip';
