-- ============================================================================
-- NOMBRES EN MAYÚSCULAS (jugadores y comando técnico — ambos viven en
-- jugador_maestro):
--  1) TRIGGER: todo registro nuevo o edición guarda NOMBRES, APELLIDOS y
--     N° DE DOCUMENTO en MAYÚSCULAS (upper + trim). Cubre todas las vías:
--     admin, club, importación y correcciones.
--  2) MIGRACIÓN: se actualizan los datos existentes.
--  NOTA: no se tocan campos de lista (posición, pie hábil, género): tienen
--  valores fijos con CHECK y los formularios los comparan de forma exacta.
-- ============================================================================

-- 1) Trigger
create or replace function competencias.mayusculas_jugador()
returns trigger language plpgsql as $$
begin
  new.nombres       := upper(trim(new.nombres));
  new.apellidos     := upper(trim(new.apellidos));
  new.nro_documento := upper(trim(new.nro_documento));
  return new;
end $$;
drop trigger if exists t_mayusculas_jugador on competencias.jugador_maestro;
create trigger t_mayusculas_jugador
before insert or update on competencias.jugador_maestro
for each row execute function competencias.mayusculas_jugador();

-- 2) Migración de lo existente
update competencias.jugador_maestro
   set nombres = upper(trim(nombres)), apellidos = upper(trim(apellidos))
 where nombres <> upper(trim(nombres)) or apellidos <> upper(trim(apellidos));

-- N° de documento: solo donde el cambio no choque con la llave única
update competencias.jugador_maestro j
   set nro_documento = upper(trim(nro_documento))
 where nro_documento <> upper(trim(nro_documento))
   and not exists (select 1 from competencias.jugador_maestro x
                   where x.pais_documento = j.pais_documento
                     and x.nro_documento = upper(trim(j.nro_documento))
                     and x.id <> j.id);

notify pgrst, 'reload schema';

-- Verificación: no debe quedar ningún nombre en minúsculas
select count(*) filter (where nombres <> upper(nombres) or apellidos <> upper(apellidos)) as pendientes_minusculas,
       count(*) as total_personas
from competencias.jugador_maestro;
