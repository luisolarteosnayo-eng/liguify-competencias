-- Público: mostrar MES y año de nacimiento (decisión 2026-08-07; antes solo año)
create or replace view competencias.vista_jugador_publico as
select j.id, j.nombres, j.apellidos,
       extract(year from j.fecha_nacimiento)::int as anio_nacimiento,
       case when j.consentimiento_imagen then j.foto_url else null end as foto_url,
       j.consentimiento_imagen,
       j.verificado,
       j.pie_habil, j.posicion,
       extract(month from j.fecha_nacimiento)::int as mes_nacimiento
from competencias.jugador_maestro j;

create or replace view competencias.vista_lbf_publica as
select i.id as inscripcion_id, i.equipo_id, i.categoria_id, i.dorsal, i.capitan,
       i.es_excepcion, jp.nombres, jp.apellidos, jp.anio_nacimiento,
       jp.foto_url, jp.consentimiento_imagen,
       jp.pie_habil, jp.posicion, jp.mes_nacimiento
from competencias.inscripcion_lbf i
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
where i.en_lbf and not i.inhabilitado;

notify pgrst, 'reload schema';