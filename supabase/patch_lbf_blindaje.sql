-- Blindaje: solo el staff de la marca puede cambiar estado/inhabilitado/apto/excepción
-- de una inscripción LBF; para el club esos campos se revierten en silencio.
create or replace function competencias.proteger_lbf_estado()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_staff_marca(competencias.marca_de_categoria(new.categoria_id)) then
    new.estado            := old.estado;
    new.inhabilitado      := old.inhabilitado;
    new.fecha_apto_medico := old.fecha_apto_medico;
    new.es_excepcion      := old.es_excepcion;
  end if;
  return new;
end $$;
drop trigger if exists t_proteger_lbf on competencias.inscripcion_lbf;
create trigger t_proteger_lbf before update on competencias.inscripcion_lbf
for each row execute function competencias.proteger_lbf_estado();

notify pgrst, 'reload schema';