-- ============================================================================
-- PATCH: COMANDO TÉCNICO en la LBF por equipo/torneo
-- Roles: Entrenador, Asistente Técnico, Preparador físico, Preparador de
-- arqueros, Médico. Máximo configurable por torneo. Las personas viven en la
-- MISMA maestra global (jugador_maestro: documento único por país — si el
-- entrenador también es jugador registrado, es la misma persona).
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Configuración del torneo: máximo de personas del comando técnico
alter table competencias.torneo
  add column if not exists ct_max_personas int not null default 5;

-- 2) Inscripción del comando técnico (por equipo, como la LBF)
create table if not exists competencias.comando_tecnico (
  id           uuid primary key default gen_random_uuid(),
  equipo_id    uuid not null references competencias.equipo(id) on delete cascade,
  categoria_id uuid not null references competencias.categoria(id) on delete cascade,
  persona_id   uuid not null references competencias.jugador_maestro(id),
  rol          text not null check (rol in ('Entrenador','Asistente Técnico','Preparador físico','Preparador de arqueros','Médico')),
  estado       text not null default 'pendiente' check (estado in ('pendiente','activo')),
  inhabilitado boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (equipo_id, persona_id)          -- una persona una sola vez por equipo
);
alter table competencias.comando_tecnico enable row level security;

-- 3) Helper de alcance (staff de marca, coordinador multimarca, delegado del
--    equipo, sub-coordinador de la categoría) — reutilizable
create or replace function competencias.gestiona_equipo(p_equipo uuid, p_categoria uuid)
returns boolean
language sql stable security definer
set search_path = competencias
as $$
  select competencias.es_staff_marca(competencias.marca_de_categoria(p_categoria))
      or exists (select 1 from equipo e where e.id = p_equipo and competencias.es_coordinador_club(e.club_id))
      or exists (select 1 from usuario_club uc
                 where uc.usuario_id = auth.uid() and uc.rol = 'delegado' and uc.equipo_id = p_equipo)
      or exists (select 1 from usuario_club_categoria ucc
                 join equipo e2 on e2.id = p_equipo
                 where ucc.usuario_id = auth.uid() and ucc.club_id = e2.club_id
                   and ucc.categoria_id = p_categoria)
$$;
revoke execute on function competencias.gestiona_equipo(uuid,uuid) from public, anon;
grant  execute on function competencias.gestiona_equipo(uuid,uuid) to authenticated;

-- 4) Políticas y permisos
drop policy if exists ct_read on competencias.comando_tecnico;
create policy ct_read on competencias.comando_tecnico for select
  using (auth.uid() is not null);
drop policy if exists ct_write on competencias.comando_tecnico;
create policy ct_write on competencias.comando_tecnico for all
  using (competencias.gestiona_equipo(equipo_id, categoria_id))
  with check (auth.uid() is not null);
grant select, insert, update, delete on competencias.comando_tecnico to authenticated;

-- 5) Blindaje: estado/inhabilitado solo los cambia el staff (como en la LBF)
create or replace function competencias.proteger_ct_estado()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_staff_marca(competencias.marca_de_categoria(new.categoria_id)) then
    new.estado       := old.estado;
    new.inhabilitado := old.inhabilitado;
  end if;
  return new;
end $$;
drop trigger if exists t_proteger_ct on competencias.comando_tecnico;
create trigger t_proteger_ct before update on competencias.comando_tecnico
for each row execute function competencias.proteger_ct_estado();

-- 6) Fotos y documentos: el permiso ahora también cubre al comando técnico
create or replace function competencias.actualizar_foto_jugador(p_jugador uuid, p_url text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para actualizar la foto de esta persona';
  end if;
  update competencias.jugador_maestro set foto_url = p_url where id = p_jugador;
end $$;

create or replace function competencias.actualizar_docs_jugador(p_jugador uuid, p_frente text, p_reverso text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para actualizar los documentos de esta persona';
  end if;
  update competencias.jugador_maestro set
    doc_scan_frente_url  = coalesce(p_frente,  doc_scan_frente_url),
    doc_scan_reverso_url = coalesce(p_reverso, doc_scan_reverso_url)
  where id = p_jugador;
end $$;

notify pgrst, 'reload schema';
