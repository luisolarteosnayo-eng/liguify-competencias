-- ============================================================================
-- ⭐ EQUIPO IDEAL DE LA FECHA
-- En CARGAR RESULTADO, cada jugador puede marcarse para el equipo ideal de la
-- jornada indicando su línea (ARQ/DEF/MED/DEL). Desde la cabecera de la fecha,
-- ⭐ EQUIPO IDEAL arma la formación (F7: 1-2-2-2 · F9: 1-3-3-2 · F11: 1-4-3-3)
-- y genera la imagen para redes con el estilo de las imágenes actuales.
-- ============================================================================
create table if not exists competencias.equipo_ideal (
  jornada_id     uuid not null references competencias.jornada(id) on delete cascade,
  inscripcion_id uuid not null references competencias.inscripcion_lbf(id) on delete cascade,
  linea          text not null check (linea in ('ARQ','DEF','MED','DEL')),
  created_by     uuid,
  created_at     timestamptz not null default now(),
  primary key (jornada_id, inscripcion_id)
);
alter table competencias.equipo_ideal enable row level security;

-- Público puede leerlo (futuro: mostrarlo en la web); escribe el staff de la marca
drop policy if exists ei_read on competencias.equipo_ideal;
create policy ei_read on competencias.equipo_ideal for select using (true);
drop policy if exists ei_write on competencias.equipo_ideal;
create policy ei_write on competencias.equipo_ideal for all
  using (competencias.es_staff_marca(competencias.marca_de_categoria(
           (select j.categoria_id from competencias.jornada j where j.id = jornada_id))))
  with check (competencias.es_staff_marca(competencias.marca_de_categoria(
           (select j.categoria_id from competencias.jornada j where j.id = jornada_id))));
grant select on competencias.equipo_ideal to anon, authenticated;
grant insert, update, delete on competencias.equipo_ideal to authenticated;

drop trigger if exists t_sellar_equipo_ideal on competencias.equipo_ideal;
create trigger t_sellar_equipo_ideal before insert on competencias.equipo_ideal
for each row execute function competencias.sellar_created_by();

notify pgrst, 'reload schema';
select 'equipo_ideal lista' as resultado;
