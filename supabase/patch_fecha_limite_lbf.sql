-- ============================================================================
-- 🔒 FECHA LÍMITE DE CARGA DE EQUIPO — AHORA SE APLICA DE VERDAD
-- El campo torneo.fecha_limite_carga_equipo existía pero NUNCA se validaba:
-- los clubes podían seguir agregando/quitando jugadores después del cierre.
-- Este candado (a nivel de BD) bloquea INSERT y DELETE en inscripcion_lbf
-- para usuarios que NO son staff de la marca cuando ya pasó la fecha límite.
--  · El ADMIN/mesa sigue pudiendo todo (es el canal para cambios post-cierre).
--  · Los procesos internos (service_role, sin auth.uid) no se bloquean.
--  · Los UPDATE del club (dorsal, capitán, fotos/documentos) NO se bloquean
--    aquí; el modo Club los oculta igual en pantalla tras el cierre.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.impedir_lbf_fuera_de_plazo()
returns trigger language plpgsql security definer
set search_path = competencias, public as $$
declare v_lim date; v_marca uuid; v_cat uuid;
begin
  v_cat := coalesce(new.categoria_id, old.categoria_id);
  select t.fecha_limite_carga_equipo, t.marca_id into v_lim, v_marca
  from competencias.categoria c
  join competencias.torneo t on t.id = c.torneo_id
  where c.id = v_cat;
  if v_lim is null or current_date <= v_lim then return coalesce(new, old); end if;
  if auth.uid() is null then return coalesce(new, old); end if;          -- service_role / procesos
  if competencias.es_staff_marca(v_marca) then return coalesce(new, old); end if;
  raise exception 'La carga de equipos de este torneo cerró el %. Los cambios en la LBF ahora solo los hace el organizador.',
    to_char(v_lim, 'DD/MM/YYYY');
end $$;

drop trigger if exists t_lbf_fuera_de_plazo on competencias.inscripcion_lbf;
create trigger t_lbf_fuera_de_plazo
before insert or delete on competencias.inscripcion_lbf
for each row execute function competencias.impedir_lbf_fuera_de_plazo();

notify pgrst, 'reload schema';

-- VERIFICACIÓN
select 'trigger t_lbf_fuera_de_plazo' as objeto, count(*)::text as existe
from pg_trigger where tgname = 't_lbf_fuera_de_plazo';
