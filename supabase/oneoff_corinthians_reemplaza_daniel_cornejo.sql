-- ============================================================================
-- PASO 2 · PLATA - 2014 F11 - CLAUSURA
-- CORINTHIANS reemplaza a DANIEL CORNEJO en los 13 partidos programados.
-- Mismos pasos que EL DIAMANTE ↔ C.D. FÉNIX ÉLITE: IDs literales verificados
-- en el Paso 1, sin renombrar y sin borrar nada; cada club conserva su identidad.
-- La tabla de posiciones se recalcula sola (se deriva de los partidos).
-- ============================================================================
do $$
declare
  v_cat constant uuid := '5c1406e8-b73f-4b76-8c1a-5b62cf3b87a3';  -- CATEGORÍA 2014/F11 del torneo PLATA - 2014 F11 - CLAUSURA
  v_old constant uuid := '74f79324-a6a1-4e61-88e8-c67361a6f4e0';  -- DANIEL CORNEJO (13 partidos: 8L + 5V)
  v_new constant uuid := 'cc136c31-84cd-4895-bb04-5e5f6cdf36a1';  -- CORINTHIANS  (0 partidos)
  n_local int; n_visita int; n_zona int; n_ev int;
begin
  -- Seguridad: los IDs deben seguir siendo los del Paso 1.
  if not exists (select 1 from competencias.equipo where id = v_old and categoria_id = v_cat) then
    raise exception 'DANIEL CORNEJO no está en esa categoría: no se cambió nada.';
  end if;
  if not exists (select 1 from competencias.equipo where id = v_new and categoria_id = v_cat) then
    raise exception 'CORINTHIANS no está en esa categoría: no se cambió nada.';
  end if;
  if exists (select 1 from competencias.partido
             where categoria_id = v_cat and (local_id = v_new or visita_id = v_new)) then
    raise exception 'CORINTHIANS ya tiene partidos en esta categoría: no se cambió nada.';
  end if;

  -- CORINTHIANS hereda la zona de DANIEL CORNEJO (ZONA A); si ya está, no duplica.
  insert into competencias.equipo_en_zona (zona_id, equipo_id)
  select z.zona_id, v_new from competencias.equipo_en_zona z
  where z.equipo_id = v_old
  on conflict do nothing;
  get diagnostics n_zona = row_count;

  -- El reemplazo en la programación, acotado a ESTA categoría.
  update competencias.partido set local_id  = v_new
   where categoria_id = v_cat and local_id  = v_old;
  get diagnostics n_local = row_count;

  update competencias.partido set visita_id = v_new
   where categoria_id = v_cat and visita_id = v_old;
  get diagnostics n_visita = row_count;

  -- Eventos ya cargados (goles/tarjetas) de esos partidos, por si hubiera alguno.
  update competencias.evento_partido ev set equipo_id = v_new
   where ev.equipo_id = v_old
     and exists (select 1 from competencias.partido p
                 where p.id = ev.partido_id and p.categoria_id = v_cat);
  get diagnostics n_ev = row_count;

  raise notice 'Local: % · Visita: % · Total: % (se esperaban 8 + 5 = 13)', n_local, n_visita, n_local + n_visita;
  raise notice 'Zonas heredadas: % · eventos reapuntados: %', n_zona, n_ev;

  if n_local + n_visita <> 13 then
    raise exception 'Se movieron % partidos y se esperaban 13: se revierte todo.', n_local + n_visita;
  end if;
end $$;

-- Verificación: DANIEL CORNEJO en 0 y CORINTHIANS con 8 de local y 5 de visita.
select upper(trim(coalesce(nullif(e.nombre,''), cl.nombre))) as equipo,
       count(p.id) filter (where p.local_id  = e.id) as de_local,
       count(p.id) filter (where p.visita_id = e.id) as de_visita,
       count(p.id) as total
from competencias.equipo e
join competencias.club cl on cl.id = e.club_id
left join competencias.partido p
       on p.categoria_id = e.categoria_id and (p.local_id = e.id or p.visita_id = e.id)
where e.id in ('74f79324-a6a1-4e61-88e8-c67361a6f4e0','cc136c31-84cd-4895-bb04-5e5f6cdf36a1')
group by 1 order by 1;
