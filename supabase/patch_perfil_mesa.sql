-- ============================================================================
-- PERFIL MESA (rol mesa_control de usuario_marca) — alcance real en la BD
--
-- Lo que MESA puede hacer:
--   · Editar SOLO el resultado de los partidos: marcador, penales, estado y
--     figura (las tarjetas y goles por jugador van por planilla_partido).
--   · Verificar documentos/inscripciones por torneo (verificar_carnet_*, ya
--     concedidos a authenticated).
--   · Acreditar en cancha (acreditacion_partido, ya permitido a autenticados).
--
-- Lo que MESA ya NO puede hacer (antes sí, porque es_staff_marca lo incluía):
--   · Cambiar fecha/hora/sede/cancha/árbitro/equipos/video de un partido.
--   · Crear o eliminar partidos.
--   · Escribir en la LBF (inscribir, editar, quitar jugadores) ni cambiar
--     estado/inhabilitación de inscripciones o del comando técnico.
--
-- El alta sigue igual: 👥 USUARIOS de la marca → email + rol mesa_control
-- (la persona inicia sesión una vez con Google o email en liguify.com/admin).
-- ============================================================================

-- 1) Partido: mesa solo toca columnas de resultado; otros roles, nada.
create or replace function competencias.proteger_partido_mesa()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
declare v_marca uuid;
begin
  v_marca := competencias.marca_de_categoria(new.categoria_id);
  if competencias.es_admin_marca(v_marca) then
    return new;                                   -- admin: sin restricciones
  end if;
  -- Mesa (es_staff sin ser admin): se conservan SOLO las columnas de resultado.
  -- Cualquier otro cambio se revierte en silencio (la fila no se rompe).
  new.categoria_id := old.categoria_id;  new.fase_id      := old.fase_id;
  new.zona_id      := old.zona_id;       new.jornada_id   := old.jornada_id;
  new.etapa        := old.etapa;         new.local_id     := old.local_id;
  new.visita_id    := old.visita_id;     new.local_origen := old.local_origen;
  new.visita_origen:= old.visita_origen; new.fecha        := old.fecha;
  new.hora         := old.hora;          new.sede         := old.sede;
  new.cancha       := old.cancha;        new.arbitro      := old.arbitro;
  new.video_url    := old.video_url;     new.comentario   := old.comentario;
  new.visible      := old.visible;       new.created_by   := old.created_by;
  if not competencias.es_staff_marca(v_marca) then
    -- ni admin ni mesa: tampoco el resultado (cubre la policy temporal del POC)
    new.estado         := old.estado;
    new.goles_local    := old.goles_local;    new.goles_visita   := old.goles_visita;
    new.penales        := old.penales;
    new.penales_local  := old.penales_local;  new.penales_visita := old.penales_visita;
    new.figura_inscripcion_id := old.figura_inscripcion_id;
  end if;
  return new;
end $$;
drop trigger if exists t_proteger_partido_mesa on competencias.partido;
create trigger t_proteger_partido_mesa before update on competencias.partido
for each row execute function competencias.proteger_partido_mesa();

-- 2) Crear/eliminar partidos: solo admin de la marca.
create or replace function competencias.partido_solo_admin()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
declare v_cat uuid;
begin
  v_cat := case when tg_op = 'DELETE' then old.categoria_id else new.categoria_id end;
  if not competencias.es_admin_marca(competencias.marca_de_categoria(v_cat)) then
    raise exception 'Solo el admin de la marca puede crear o eliminar partidos';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists t_partido_solo_admin on competencias.partido;
create trigger t_partido_solo_admin before insert or delete on competencias.partido
for each row execute function competencias.partido_solo_admin();

-- 3) LBF: escribir queda para admin + club (coordinador/subcoordinador/delegado).
--    Antes decía es_staff_marca, lo que dejaba a mesa inscribir y editar.
drop policy if exists lbf_write on competencias.inscripcion_lbf;
create policy lbf_write on competencias.inscripcion_lbf for all
  using (
    competencias.es_admin_marca(competencias.marca_de_categoria(categoria_id))
    or exists (select 1 from competencias.equipo e
               where e.id = equipo_id and competencias.es_coordinador_club(e.club_id))
    or exists (select 1 from competencias.usuario_club uc
               join competencias.equipo e on e.id = equipo_id
               where uc.usuario_id = auth.uid() and uc.club_id = e.club_id
                 and uc.rol = 'delegado' and uc.equipo_id = e.id)
    or exists (select 1 from competencias.usuario_club_categoria ucc
               join competencias.equipo e2 on e2.id = equipo_id
               where ucc.usuario_id = auth.uid() and ucc.club_id = e2.club_id
                 and ucc.categoria_id = inscripcion_lbf.categoria_id)
  )
  with check (auth.uid() is not null);

-- 4) Estado/inhabilitación de inscripciones: bypass solo para admin (antes staff).
--    La activación por autorización de Padre/Tutor (set_config) sigue intacta.
create or replace function competencias.proteger_lbf_estado()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if competencias.es_admin_marca(competencias.marca_de_categoria(new.categoria_id)) then
    return new;
  end if;
  if coalesce(current_setting('competencias.activar_por_autorizacion', true),'') = '1'
     and old.estado = 'pendiente' and new.estado = 'activo' then
    new.inhabilitado      := old.inhabilitado;
    new.fecha_apto_medico := old.fecha_apto_medico;
    new.es_excepcion      := old.es_excepcion;
    return new;
  end if;
  new.estado            := old.estado;
  new.inhabilitado      := old.inhabilitado;
  new.fecha_apto_medico := old.fecha_apto_medico;
  new.es_excepcion      := old.es_excepcion;
  return new;
end $$;

-- 5) Igual para el comando técnico (antes staff).
create or replace function competencias.proteger_ct_estado()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_admin_marca(competencias.marca_de_categoria(new.categoria_id)) then
    new.estado       := old.estado;
    new.inhabilitado := old.inhabilitado;
  end if;
  return new;
end $$;

-- Verificación rápida de objetos creados
select tgname, tgrelid::regclass from pg_trigger
where tgname in ('t_proteger_partido_mesa','t_partido_solo_admin');
