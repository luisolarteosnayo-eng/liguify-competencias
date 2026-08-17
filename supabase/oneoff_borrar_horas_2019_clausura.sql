-- ============================================================================
-- ONE-OFF (dato, no esquema): dejar SIN HORA los partidos de
--   INTI CUP · ORO - CLAUSURA 2026 · Categoría 2019 / F7
-- (11 fechas, 66 partidos) — como si recién se hubieran creado.
-- Solo toca la columna hora: NO cambia fechas, equipos, sedes ni resultados.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) VERIFICAR antes (debe devolver 66 y 66)
select count(*) as partidos, count(hora) as con_hora
from competencias.partido
where categoria_id = 'd9c43d7f-c344-427a-9e6b-3842e5fff671';

-- 2) BORRAR las horas
update competencias.partido
set hora = null
where categoria_id = 'd9c43d7f-c344-427a-9e6b-3842e5fff671'
  and hora is not null;

-- 3) CONFIRMAR (con_hora debe quedar en 0)
select count(*) as partidos, count(hora) as con_hora
from competencias.partido
where categoria_id = 'd9c43d7f-c344-427a-9e6b-3842e5fff671';
