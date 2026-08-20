-- PASO 1 (solo lectura) · Torneo PLATA - 2014 F11 - CLAUSURA
-- Identifica los IDs de CORINTHIANS y DANIEL CORNEJO y sus partidos EN ESE TORNEO.
select t.id  as torneo_id,
       t.nombre as torneo,
       c.id  as categoria_id,
       e.id  as equipo_id,
       upper(trim(coalesce(nullif(e.nombre,''), cl.nombre))) as equipo,
       e.estado,
       count(p.id) filter (where p.local_id  = e.id) as de_local,
       count(p.id) filter (where p.visita_id = e.id) as de_visita,
       count(p.id) as partidos
from competencias.torneo t
join competencias.categoria c on c.torneo_id = t.id
join competencias.equipo e    on e.categoria_id = c.id
join competencias.club cl     on cl.id = e.club_id
left join competencias.partido p
       on p.categoria_id = c.id and (p.local_id = e.id or p.visita_id = e.id)
where t.nombre ilike '%PLATA%2014%F11%'
  and upper(trim(coalesce(nullif(e.nombre,''), cl.nombre))) in ('CORINTHIANS','DANIEL CORNEJO')
group by t.id, t.nombre, c.id, e.id, equipo, e.estado
order by equipo;
