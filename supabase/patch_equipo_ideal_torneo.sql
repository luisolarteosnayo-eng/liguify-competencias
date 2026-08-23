-- Equipo ideal DEL TORNEO (una sola imagen mezclando categorías):
-- de los jugadores marcados en cada partido, el organizador elige cuáles
-- integran el equipo de la fecha a nivel torneo. Se persiste aquí.
alter table competencias.equipo_ideal
  add column if not exists en_torneo boolean not null default false;
notify pgrst, 'reload schema';
select 'en_torneo lista' as resultado;
