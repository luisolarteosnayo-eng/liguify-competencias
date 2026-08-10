-- Figura del partido (elegida al cargar el resultado)
alter table competencias.partido
  add column if not exists figura_inscripcion_id uuid references competencias.inscripcion_lbf(id);

notify pgrst, 'reload schema';
