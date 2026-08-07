-- ============================================================================
-- PATCH: ATRIBUTOS DEL JUGADOR (Pie hábil, Posición) con CATÁLOGO CONFIGURABLE
-- Los valores de las listas los administra el maestro de datos (super-admin)
-- en la tabla catalogo_atributo — extensible a futuros atributos.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Catálogo configurable (lectura pública; escritura solo super-admin)
create table if not exists competencias.catalogo_atributo (
  id       uuid primary key default gen_random_uuid(),
  atributo text not null,                -- 'pie_habil' | 'posicion' | futuros
  valor    text not null,
  orden    int  not null default 0,
  activo   boolean not null default true,
  unique (atributo, valor)
);
alter table competencias.catalogo_atributo enable row level security;
drop policy if exists cat_read on competencias.catalogo_atributo;
create policy cat_read on competencias.catalogo_atributo for select using (true);
drop policy if exists cat_write on competencias.catalogo_atributo;
create policy cat_write on competencias.catalogo_atributo for all
  using (competencias.es_super()) with check (competencias.es_super());
grant select on competencias.catalogo_atributo to anon, authenticated;
grant insert, update, delete on competencias.catalogo_atributo to authenticated;

insert into competencias.catalogo_atributo (atributo, valor, orden) values
  ('pie_habil','Derecho',1),('pie_habil','Izquierdo',2),('pie_habil','Ambidiestro',3),
  ('posicion','Arquero',1),('posicion','Defensa',2),('posicion','Lateral',3),
  ('posicion','Medio Campo',4),('posicion','Extremo',5),('posicion','Delantero',6)
on conflict (atributo, valor) do nothing;

-- 2) Campos en la maestra
alter table competencias.jugador_maestro
  add column if not exists pie_habil text,
  add column if not exists posicion  text;

-- 3) Editar atributos con alcance de gestión + validación contra el catálogo
create or replace function competencias.actualizar_atributos_jugador(p_jugador uuid, p_pie text, p_posicion text)
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
    raise exception 'Sin permiso para actualizar los atributos de esta persona';
  end if;
  if coalesce(p_pie,'') <> '' and not exists
     (select 1 from competencias.catalogo_atributo where atributo='pie_habil' and valor=p_pie and activo) then
    raise exception 'Pie hábil inválido (no está en el catálogo)';
  end if;
  if coalesce(p_posicion,'') <> '' and not exists
     (select 1 from competencias.catalogo_atributo where atributo='posicion' and valor=p_posicion and activo) then
    raise exception 'Posición inválida (no está en el catálogo)';
  end if;
  update competencias.jugador_maestro
  set pie_habil = nullif(p_pie,''), posicion = nullif(p_posicion,'')
  where id = p_jugador;
end $$;
revoke execute on function competencias.actualizar_atributos_jugador(uuid,text,text) from public, anon;
grant  execute on function competencias.actualizar_atributos_jugador(uuid,text,text) to authenticated;

-- 4) Vistas públicas: perfil del jugador con sus atributos (columnas al FINAL)
create or replace view competencias.vista_jugador_publico as
select j.id, j.nombres, j.apellidos,
       extract(year from j.fecha_nacimiento)::int as anio_nacimiento,
       case when j.consentimiento_imagen then j.foto_url else null end as foto_url,
       j.consentimiento_imagen,
       j.verificado,
       j.pie_habil, j.posicion
from competencias.jugador_maestro j;

create or replace view competencias.vista_lbf_publica as
select i.id as inscripcion_id, i.equipo_id, i.categoria_id, i.dorsal, i.capitan,
       i.es_excepcion, jp.nombres, jp.apellidos, jp.anio_nacimiento,
       jp.foto_url, jp.consentimiento_imagen,
       jp.pie_habil, jp.posicion
from competencias.inscripcion_lbf i
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
where i.en_lbf and not i.inhabilitado;

notify pgrst, 'reload schema';
