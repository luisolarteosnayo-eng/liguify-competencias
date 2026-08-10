-- Vista pública del detalle por jugador de un partido (alineación, goles,
-- tarjetas). Corre como owner; foto censurada por consentimiento vía
-- vista_jugador_publico. Sin datos médicos ni documentales.
create or replace view competencias.vista_planilla_publica as
select p.partido_id, p.inscripcion_id, p.jugo, p.goles, p.amarillas, p.rojas,
       i.equipo_id, i.dorsal, i.capitan,
       jp.nombres, jp.apellidos, jp.foto_url, jp.consentimiento_imagen, jp.posicion
from competencias.planilla_partido p
join competencias.inscripcion_lbf i on i.id = p.inscripcion_id
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id;

grant select on competencias.vista_planilla_publica to anon, authenticated;

notify pgrst, 'reload schema';
