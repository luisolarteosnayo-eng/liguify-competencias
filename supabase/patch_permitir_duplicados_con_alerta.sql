-- ============================================================================
-- INSCRIPCIONES: de BLOQUEO a ALERTA (decisión 2026-08-21)
--
-- Antes: unique (jugador_id, categoria_id) impedía inscribir a un jugador en
-- dos equipos de la misma categoría (anti-suplantación dura).
-- Ahora: la inscripción SE PERMITE y el frontend muestra la alerta de
-- duplicidad/suplantación. El organizador los detecta en el reporte
-- 🔎 DUPLICADOS (que ya agrupa por documento en más de un equipo, incluida
-- la misma categoría) y se comunica con ambos equipos.
--
-- Se mantiene un único candado: el MISMO jugador no puede estar dos veces en
-- el MISMO equipo (unique jugador + equipo).
-- ============================================================================

-- 1) Soltar el unique (jugador_id, categoria_id), se llame como se llame
do $$
declare r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'competencias.inscripcion_lbf'::regclass
      and con.contype = 'u'
      and (select array_agg(att.attname order by att.attname)
           from unnest(con.conkey) k
           join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k)
          = array['categoria_id','jugador_id']::name[]
  loop
    execute format('alter table competencias.inscripcion_lbf drop constraint %I', r.conname);
    raise notice 'Constraint eliminado: %', r.conname;
  end loop;
end $$;

-- 2) Nuevo candado mínimo: no repetir al jugador dentro del mismo equipo
do $$ begin
  alter table competencias.inscripcion_lbf
    add constraint inscripcion_lbf_jugador_equipo_key unique (jugador_id, equipo_id);
exception when duplicate_table then null; when duplicate_object then null; end $$;

-- Verificación: deben quedar solo los unique correctos
select con.conname,
       (select array_agg(att.attname order by att.attname)
        from unnest(con.conkey) k
        join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k) as columnas
from pg_constraint con
where con.conrelid = 'competencias.inscripcion_lbf'::regclass and con.contype = 'u';
