-- DIAGNÓSTICO (solo lectura) · ¿Dónde está inscrito el DNI 78491854?
-- La regla anti-suplantación es única por (jugador, categoría): si aparece
-- inscrito en otro equipo de la misma categoría —aunque ese equipo esté
-- retirado— el alta se bloquea.
select j.nombres || ' ' || j.apellidos             as jugador,
       j.pais_documento || ' ' || j.nro_documento  as documento,
       t.nombre                                    as torneo,
       coalesce(c.nombre_display, c.anio_nacimiento::text || ' / ' || c.modalidad) as categoria,
       cl.nombre                                   as club,
       coalesce(nullif(e.nombre,''), cl.nombre)    as equipo,
       e.estado                                    as equipo_estado,
       i.estado                                    as inscripcion_estado,
       i.en_lbf, i.inhabilitado,
       (select count(*) from competencias.planilla_partido pl
        where pl.inscripcion_id = i.id and pl.jugo)          as partidos_jugados,
       (select count(*) from competencias.planilla_partido pl
        where pl.inscripcion_id = i.id
          and (pl.goles > 0 or pl.amarillas > 0 or pl.rojas > 0)) as con_registros,
       i.id                                        as inscripcion_id,
       c.id                                        as categoria_id
from competencias.jugador_maestro j
join competencias.inscripcion_lbf i on i.jugador_id = j.id
join competencias.categoria c on c.id = i.categoria_id
join competencias.torneo t    on t.id = c.torneo_id
join competencias.equipo e    on e.id = i.equipo_id
join competencias.club cl     on cl.id = e.club_id
where j.nro_documento = '78491854'
order by t.nombre, categoria;
