-- ============================================================================
--  LIGUIFY COMPETENCIAS — Esquema v1 COMPLETO
--  Ejecutar en Supabase SQL Editor (proyecto bpsczjjomgzhnjxnzmhj)
--
--  Traduce el modelo de ANALISIS_PUBLICO_ADMIN.md con TODAS las decisiones:
--   · Marca (tenant, slug, membresía) → Torneo (reglas, implícito) → Categoría
--     (año+modalidad) → Fase → Zona → Equipo → Inscripción LBF
--   · Club ÚNICO POR MARCA (C1) · Jugador maestro GLOBAL (anti-suplantación)
--   · UNIQUE(jugador, categoría) declarativo (I9) · sanción global (I5)
--   · Membresías/roles (I6) · acreditación en cancha (§11) · eventos con
--     idempotencia offline · vistas públicas que ocultan datos sensibles (T7)
--   · Búsqueda censurada de jugador (I3) · jornada.computa_en_tabla (T4)
--   · Vista de standings calculada desde resultados (recálculo total, C5/C4)
--
--  ⚠ REEMPLAZA el esquema `competencias` completo (borra los datos del PoC).
--  ⚠ Mantiene una política temporal `poc_write_partido` para que poc-sync.html
--    siga funcionando SIN auth. Borrar al cablear el login:
--    drop policy poc_write_partido on competencias.partido;
-- ============================================================================

drop schema if exists competencias cascade;
create schema competencias;

-- ============================================================================
-- 1. MAESTRAS GLOBALES
-- ============================================================================

-- ---- MARCA (tenant · Nivel 1) ----------------------------------------------
create table competencias.marca (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null,
  slug        text not null unique
              check (slug ~ '^[a-z0-9]{2,30}$'
                     and slug not in ('admin','erp','academias','www','api')),
  logo_url    text,
  pais        text not null default 'PE',
  ciudad      text,
  email       text,
  telefono    text,
  redes       text,
  descripcion text,
  membresia   text not null default 'basico'
              check (membresia in ('basico','intermedio','premium')),
  owner_id    uuid,                        -- auth.users del dueño
  created_at  timestamptz not null default now()
);

-- ---- CLUB (único POR MARCA — C1) -------------------------------------------
create table competencias.club (
  id             uuid primary key default gen_random_uuid(),
  marca_id       uuid not null references competencias.marca(id) on delete cascade,
  nombre         text not null,
  escudo_url     text,
  color          text not null default '#1d4ed8',
  ruc_id_fiscal  text,                     -- opcional informativo (C2)
  contacto_email text,
  contacto_tel   text,
  pais           text,
  created_at     timestamptz not null default now(),
  unique (marca_id, nombre)
);

-- ---- JUGADOR MAESTRO (GLOBAL — núcleo anti-suplantación) -------------------
create table competencias.jugador_maestro (
  id                   uuid primary key default gen_random_uuid(),
  tipo_documento       text not null default 'DNI',
  pais_documento       text not null default 'PE',   -- derivado del tipo
  nro_documento        text not null,
  nombres              text not null,                 -- separados (§7 Academias)
  apellidos            text not null,
  fecha_nacimiento     date not null,
  genero               text check (genero in ('Masculino','Femenino')),
  foto_url             text,
  doc_scan_frente_url  text,                          -- storage PRIVADO (T7)
  doc_scan_reverso_url text,
  verificado           boolean not null default false,
  consentimiento_imagen boolean not null default false,  -- T3: foto B/N si false
  consentimiento_fecha  timestamptz,
  origen               text default 'manual'
                       check (origen in ('manual','academia','import')),
  created_at           timestamptz not null default now(),
  unique (pais_documento, nro_documento)              -- LLAVE ÚNICA GLOBAL
);

-- ---- SANCIÓN GLOBAL (fallos de oficio — I5) --------------------------------
create table competencias.sancion_global (
  id             uuid primary key default gen_random_uuid(),
  jugador_id     uuid not null references competencias.jugador_maestro(id),
  motivo         text not null,
  vigencia_desde date not null default current_date,
  vigencia_hasta date,                                -- null = indefinida
  emitida_por    uuid,
  created_at     timestamptz not null default now()
);

-- ---- PERFIL DE USUARIO + MEMBRESÍAS/ROLES (I6) -----------------------------
create table competencias.usuario_perfil (
  id         uuid primary key,                        -- = auth.users.id
  email      text not null,
  nombre     text,
  es_super   boolean not null default false,          -- super-admin plataforma
  created_at timestamptz not null default now()
);

create table competencias.usuario_marca (
  usuario_id uuid not null references competencias.usuario_perfil(id) on delete cascade,
  marca_id   uuid not null references competencias.marca(id) on delete cascade,
  rol        text not null check (rol in ('admin_marca','mesa_control')),
  primary key (usuario_id, marca_id, rol)
);

create table competencias.usuario_club (
  usuario_id uuid not null references competencias.usuario_perfil(id) on delete cascade,
  club_id    uuid not null references competencias.club(id) on delete cascade,
  rol        text not null check (rol in ('coordinador','delegado')),
  equipo_id  uuid,                                    -- delegado limitado a un equipo
  primary key (usuario_id, club_id, rol)
);

-- Sub-coordinador: alcance club + categoría (módulo club)
create table competencias.usuario_club_categoria (
  usuario_id   uuid not null references competencias.usuario_perfil(id) on delete cascade,
  club_id      uuid not null references competencias.club(id)      on delete cascade,
  categoria_id uuid not null references competencias.categoria(id) on delete cascade,
  primary key (usuario_id, club_id, categoria_id)
);

-- Invitaciones de coordinador/sub-coordinador (acceso SOLO por RPC security definer)
create table competencias.invitacion_club (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  nombre      text,
  telefono    text,
  club_id     uuid not null references competencias.club(id)   on delete cascade,
  torneo_id   uuid not null references competencias.torneo(id) on delete cascade,
  rol         text not null check (rol in ('coordinador','subcoordinador')),
  categorias  uuid[],
  estado      text not null default 'pendiente' check (estado in ('pendiente','aceptada','revocada')),
  invitado_por uuid,
  usuario_id  uuid,
  created_at  timestamptz not null default now(),
  aceptada_at timestamptz
);

-- ============================================================================
-- 2. JERARQUÍA DE COMPETICIÓN
-- ============================================================================

-- ---- TORNEO (Nivel 2 · bloque de reglas) -----------------------------------
create table competencias.torneo (
  id            uuid primary key default gen_random_uuid(),
  marca_id      uuid not null references competencias.marca(id) on delete cascade,
  nombre        text not null,
  slug          text not null,
  logo_url      text,                       -- null ⇒ fallback al logo de la marca
  deporte       text not null default 'futbol',   -- T9: catálogo a futuro
  anio          int  not null default extract(year from now()),
  sede          text,
  descripcion   text,
  estado        text not null default 'borrador'
                check (estado in ('borrador','en_curso','finalizado','archivado')),
  es_implicito  boolean not null default false,   -- Decisión 8: torneo oculto de marca
  -- ── reglas (default del torneo; heredables con override por categoría D1/I8)
  modalidad_default        text not null default 'F7' check (modalidad_default in ('F7','F9','F11')),
  puntos_ganado            int  not null default 3,
  puntos_empate            int  not null default 1,
  puntos_perdido           int  not null default 0,
  sumar_puntos_walkover    boolean not null default false,
  goles_ganado_walkover    int  not null default 3,
  puntos_perdido_walkover  int  not null default 0,
  orden_tabla              text[] not null default '{PJ,PUNTOS,DIF_GOL,GF,GC}',  -- T1: columnas + desempate
  mostrar_tabla_general    boolean not null default false,
  mostrar_excepciones_edad boolean not null default false,
  amarillas_suspension     int,                        -- null = sin suspensión
  fecha_limite_amarillas   date,
  lbf_max_jugadores        int not null default 30,    -- POR EQUIPO (I7)
  cargar_lbf               boolean not null default true,
  scan_dni_obligatorio     boolean not null default false,
  -- ── solo-torneo (sin override — I8)
  permitir_delegados          boolean not null default true,
  fecha_limite_carga_equipo   date,
  permitir_modificacion_equipo boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (marca_id, slug)
);

-- ---- CATEGORÍA (Nivel 3 · modalidad es ATRIBUTO; llave año+modalidad) ------
create table competencias.categoria (
  id              uuid primary key default gen_random_uuid(),
  torneo_id       uuid not null references competencias.torneo(id) on delete cascade,
  anio_nacimiento int  not null,
  modalidad       text not null check (modalidad in ('F7','F9','F11')),
  nombre_display  text,
  fecha_inicio    date,
  fecha_fin       date,
  config_override jsonb not null default '{}'::jsonb,  -- D1: override de heredables
  created_at      timestamptz not null default now(),
  unique (torneo_id, anio_nacimiento, modalidad)
);

-- ---- FASE / ZONA / JORNADA -------------------------------------------------
create table competencias.fase (
  id           uuid primary key default gen_random_uuid(),
  categoria_id uuid not null references competencias.categoria(id) on delete cascade,
  nombre       text not null,               -- Fase de Grupos · Copa Oro · Repechaje
  tipo         text not null default 'grupos' check (tipo in ('grupos','eliminacion','repechaje')),
  orden        int  not null default 1
);

create table competencias.zona (
  id      uuid primary key default gen_random_uuid(),
  fase_id uuid not null references competencias.fase(id) on delete cascade,
  nombre  text not null,                    -- A · B · C
  visible boolean not null default true
);

create table competencias.jornada (
  id               uuid primary key default gen_random_uuid(),
  categoria_id     uuid not null references competencias.categoria(id) on delete cascade,
  numero           int  not null,
  nombre           text,
  fecha            date,
  visible          boolean not null default true,
  computa_en_tabla boolean not null default true,   -- T4: fechas amistosas no suman
  horarios_publicados boolean not null default true, -- ocultar fecha/hora/sede al público mientras se programa
  unique (categoria_id, numero)
);

-- ---- EQUIPO (instancia del club en la categoría; nombre LIBRE) -------------
create table competencias.equipo (
  id              uuid primary key default gen_random_uuid(),
  categoria_id    uuid not null references competencias.categoria(id) on delete cascade,
  club_id         uuid not null references competencias.club(id),
  nombre          text,                     -- null ⇒ nombre del club; libre (A/B/SELECTIVO)
  foto_url        text,
  sede            text,
  color_dot       text,                     -- punto identificador del público
  delegado_id     uuid references competencias.usuario_perfil(id),
  delegado_codigo text,                     -- I4: código de UN SOLO USO (se anula al canjear)
  ajuste_puntos   int  not null default 0,  -- sumar/quitar puntos manual
  premio_tipo     text check (premio_tipo in ('Campeon','Subcampeon','Tercer_puesto','Fair_Play','Goleador','Valla_menos_vencida','Otro')),
  premio_libre    text,
  estado          text not null default 'activo' check (estado in ('activo','inactivo')),  -- nunca se borra
  created_at      timestamptz not null default now()
);

create table competencias.equipo_en_zona (
  zona_id   uuid not null references competencias.zona(id) on delete cascade,
  equipo_id uuid not null references competencias.equipo(id) on delete cascade,
  primary key (zona_id, equipo_id)
);

-- ---- INSCRIPCIÓN LBF (jugador ↔ equipo · ficha) ----------------------------
create table competencias.inscripcion_lbf (
  id            uuid primary key default gen_random_uuid(),
  equipo_id     uuid not null references competencias.equipo(id) on delete cascade,
  jugador_id    uuid not null references competencias.jugador_maestro(id),
  categoria_id  uuid not null references competencias.categoria(id),  -- I9: desnormalizado
  dorsal        int,
  en_lbf        boolean not null default true,
  fecha_fichaje date default current_date,
  capitan       boolean not null default false,
  cobertura_medica text,
  fecha_apto_medico date,
  estado        text not null default 'pendiente' check (estado in ('pendiente','activo')),
  inhabilitado  boolean not null default false,
  motivo_inhabilitacion text,
  es_excepcion  boolean not null default false,      -- año ≠ categoría
  origen        text not null default 'manual' check (origen in ('manual','maestra','academia')),
  qr_token      text,                                -- carnet digital (rotativo)
  nfc_uid       text,                                -- tarjeta física (premium)
  created_at    timestamptz not null default now(),
  unique (jugador_id, categoria_id)                  -- ★ ANTI-SUPLANTACIÓN declarativa
);

-- ============================================================================
-- 3. PARTIDOS, EVENTOS, PLANILLA, ACREDITACIÓN
-- ============================================================================

create table competencias.partido (
  id           uuid primary key default gen_random_uuid(),
  categoria_id uuid not null references competencias.categoria(id) on delete cascade,
  fase_id      uuid references competencias.fase(id),
  zona_id      uuid references competencias.zona(id),
  jornada_id   uuid references competencias.jornada(id),
  etapa        text,                        -- "Semifinal #1 Copa Oro" (llaves)
  -- Llaves con plantilla (§13): el partido puede nacer sin equipos (placeholder)
  -- con el cupo descrito en *_origen; resolver = asignar los equipos reales.
  local_id     uuid references competencias.equipo(id),
  visita_id    uuid references competencias.equipo(id),
  local_origen  jsonb,                      -- {t:'zona',zona,puesto}|{t:'mejor',puesto,rank}|{t:'ganador'|'perdedor',partido}
  visita_origen jsonb,
  fecha        date,
  hora         time,
  sede         text,
  cancha       text,
  arbitro      text,
  estado       text not null default 'programado'
               check (estado in ('programado','en_vivo','finalizado','suspendido','walkover')),
  goles_local  int,
  goles_visita int,
  penales      boolean not null default false,
  penales_local  int,
  penales_visita int,
  figura_inscripcion_id uuid references competencias.inscripcion_lbf(id),  -- ⭐ figura del partido
  comentario   text,
  visible      boolean not null default true,
  created_by   uuid,
  updated_by   uuid,
  updated_at   timestamptz not null default now(),
  check (local_id <> visita_id),
  constraint partido_estado_equipos_chk
    check (estado in ('programado','suspendido')
           or (local_id is not null and visita_id is not null))
);

-- Eventos del Match Center (en vivo). id lo genera el CLIENTE (uuid) para
-- idempotencia offline: reintentos de sync hacen upsert y nunca duplican.
create table competencias.evento_partido (
  id             uuid primary key,                    -- generado en el cliente
  partido_id     uuid not null references competencias.partido(id) on delete cascade,
  equipo_id      uuid references competencias.equipo(id),   -- atribución del evento (gol sin jugador elegido igual suma)
  inscripcion_id uuid references competencias.inscripcion_lbf(id),
  tipo           text not null check (tipo in ('gol','amarilla','roja','asistencia','cambio','lesion')),
  periodo        int  not null default 1,
  minuto         int  not null default 0,
  segundo        int  not null default 0,
  creado_por     uuid,
  creado_offline boolean not null default false,
  created_at     timestamptz not null default now()
);

-- Planilla por partido = FUENTE PRINCIPAL de stats (T2). Al modificar/borrar
-- el resultado, los eventos del en vivo se eliminan (cascade app/trigger).
create table competencias.planilla_partido (
  partido_id     uuid not null references competencias.partido(id) on delete cascade,
  inscripcion_id uuid not null references competencias.inscripcion_lbf(id) on delete cascade,
  jugo        boolean not null default false,
  goles       int not null default 0,
  amarillas   int not null default 0,
  rojas       int not null default 0,
  faltas      int not null default 0,
  asistencias int not null default 0,               -- solo desde el en vivo
  primary key (partido_id, inscripcion_id)
);

-- Acreditación en cancha (§11) — evidencia auditable; alimenta planilla.jugo
create table competencias.acreditacion_partido (
  partido_id     uuid not null references competencias.partido(id) on delete cascade,
  inscripcion_id uuid not null references competencias.inscripcion_lbf(id) on delete cascade,
  metodo         text not null check (metodo in ('dni_scan','qr','nfc')),
  verificado_por uuid,
  created_at     timestamptz not null default now(),
  primary key (partido_id, inscripcion_id)
);

-- Auditoría append-only
create table competencias.auditoria (
  id         bigint generated always as identity primary key,
  ts         timestamptz not null default now(),
  usuario_id uuid,
  marca_id   uuid,
  entidad    text not null,
  entidad_id text,
  accion     text not null,
  detalle    jsonb
);

-- ============================================================================
-- 4. FUNCIONES
-- ============================================================================

-- Config efectiva de una categoría = reglas del torneo ⊕ override (D1/I8)
create or replace function competencias.config_efectiva(p_categoria uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'modalidad',               c.modalidad,
    'puntos_ganado',           t.puntos_ganado,
    'puntos_empate',           t.puntos_empate,
    'puntos_perdido',          t.puntos_perdido,
    'sumar_puntos_walkover',   t.sumar_puntos_walkover,
    'goles_ganado_walkover',   t.goles_ganado_walkover,
    'puntos_perdido_walkover', t.puntos_perdido_walkover,
    'orden_tabla',             to_jsonb(t.orden_tabla),
    'mostrar_excepciones_edad',t.mostrar_excepciones_edad,
    'amarillas_suspension',    t.amarillas_suspension,
    'lbf_max_jugadores',       t.lbf_max_jugadores,
    'cargar_lbf',              t.cargar_lbf,
    'scan_dni_obligatorio',    t.scan_dni_obligatorio
  ) || coalesce(c.config_override, '{}'::jsonb)
  from competencias.categoria c
  join competencias.torneo t on t.id = c.torneo_id
  where c.id = p_categoria
$$;

-- Roles del usuario autenticado
-- SECURITY DEFINER obligatorio: las políticas que consultan usuario_perfil inline
-- disparan la política de usuario_perfil y recursan (42P17).
create or replace function competencias.es_super()
returns boolean language sql stable security definer
set search_path = competencias as $$
  select exists (select 1 from usuario_perfil where id = auth.uid() and es_super)
$$;

create or replace function competencias.es_admin_marca(p_marca uuid)
returns boolean language sql stable security definer set search_path = competencias as $$
  select exists (select 1 from usuario_marca
                 where usuario_id = auth.uid() and marca_id = p_marca and rol = 'admin_marca')
      or exists (select 1 from usuario_perfil where id = auth.uid() and es_super)
$$;

create or replace function competencias.es_staff_marca(p_marca uuid)  -- admin o mesa
returns boolean language sql stable security definer set search_path = competencias as $$
  select exists (select 1 from usuario_marca
                 where usuario_id = auth.uid() and marca_id = p_marca)
      or exists (select 1 from usuario_perfil where id = auth.uid() and es_super)
$$;

-- Normalización de nombres (sin tildes, minúsculas) para comparar clubes
create or replace function competencias.norm_txt(t text)
returns text language sql immutable as $$
  select translate(lower(trim(coalesce(t,''))),
                   'áàäâéèëêíìïîóòöôúùüûñç','aaaaeeeeiiiioooouuuunc')
$$;

-- Coordinador del club: directo, o por club HOMÓNIMO de otra marca de la MISMA
-- organización real (mismo erp_org_id). Entre organizadores distintos NO hay
-- extensión (protección de cartera C1).
create or replace function competencias.es_coordinador_club(p_club uuid)
returns boolean
language sql stable security definer
set search_path = competencias
as $$
  select exists (select 1 from usuario_club
                 where usuario_id = auth.uid() and club_id = p_club and rol = 'coordinador')
      or exists (
        select 1
        from usuario_club uc
        join club  c0 on c0.id = uc.club_id
        join marca m0 on m0.id = c0.marca_id and m0.erp_org_id is not null
        join club  c1 on c1.id = p_club
        join marca m1 on m1.id = c1.marca_id and m1.erp_org_id = m0.erp_org_id
        where uc.usuario_id = auth.uid() and uc.rol = 'coordinador'
          and competencias.norm_txt(c1.nombre) = competencias.norm_txt(c0.nombre))
$$;

-- Escudo compartido entre clubes homónimos de la MISMA organización (erp_org_id):
-- al crear un club hereda el escudo del homónimo; al cambiarlo se propaga.
create or replace function competencias.heredar_escudo_club()
returns trigger
language plpgsql security definer
set search_path = competencias, public
as $$
declare v record;
begin
  if new.escudo_url is null then
    select src.escudo_url, src.color into v
    from competencias.club src
    join competencias.marca ms on ms.id = src.marca_id and ms.erp_org_id is not null
    join competencias.marca mn on mn.id = new.marca_id and mn.erp_org_id = ms.erp_org_id
    where src.escudo_url is not null
      and competencias.norm_txt(src.nombre) = competencias.norm_txt(new.nombre)
    limit 1;
    if v.escudo_url is not null then
      new.escudo_url := v.escudo_url;
      new.color := coalesce(v.color, new.color);
    end if;
  end if;
  return new;
end $$;
create trigger t_heredar_escudo before insert on competencias.club
for each row execute function competencias.heredar_escudo_club();

create or replace function competencias.propagar_escudo_club()
returns trigger
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if (new.escudo_url is distinct from old.escudo_url) or (new.color is distinct from old.color) then
    update competencias.club c
    set escudo_url = new.escudo_url, color = new.color
    from competencias.marca m0, competencias.marca m1
    where m0.id = new.marca_id and m0.erp_org_id is not null
      and m1.id = c.marca_id and m1.erp_org_id = m0.erp_org_id
      and c.id <> new.id
      and competencias.norm_txt(c.nombre) = competencias.norm_txt(new.nombre);
  end if;
  return new;
end $$;
create trigger t_propagar_escudo after update on competencias.club
for each row execute function competencias.propagar_escudo_club();

create or replace function competencias.marca_de_categoria(p_cat uuid)
returns uuid language sql stable as $$
  select t.marca_id from competencias.categoria c
  join competencias.torneo t on t.id = c.torneo_id where c.id = p_cat
$$;

-- Gestión de roles por email (alta de marcas / pantalla 👥 USUARIOS).
-- El usuario debe existir en auth.users (registrarse una vez); si no → 'NO_EXISTE'.
create or replace function competencias.asignar_rol_marca(p_email text, p_marca uuid, p_rol text)
returns text
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_uid uuid; v_email text;
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  if p_rol not in ('admin_marca','mesa_control') then
    raise exception 'Rol inválido';
  end if;
  select id, email into v_uid, v_email
  from auth.users where lower(email) = lower(p_email) limit 1;
  if v_uid is null then
    return 'NO_EXISTE';
  end if;
  insert into competencias.usuario_perfil(id, email) values (v_uid, v_email)
    on conflict (id) do nothing;
  insert into competencias.usuario_marca(usuario_id, marca_id, rol)
    values (v_uid, p_marca, p_rol)
    on conflict do nothing;
  if p_rol = 'admin_marca' then
    update competencias.marca set owner_id = coalesce(owner_id, v_uid) where id = p_marca;
  end if;
  return 'OK';
end $$;

create or replace function competencias.quitar_rol_marca(p_usuario uuid, p_marca uuid, p_rol text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  delete from competencias.usuario_marca
  where usuario_id = p_usuario and marca_id = p_marca and rol = p_rol;
end $$;

create or replace function competencias.usuarios_de_marca(p_marca uuid)
returns table(usuario_id uuid, email text, nombre text, rol text)
language sql security definer stable
set search_path = competencias, public
as $$
  select um.usuario_id, up.email, up.nombre, um.rol
  from competencias.usuario_marca um
  join competencias.usuario_perfil up on up.id = um.usuario_id
  where um.marca_id = p_marca
    and competencias.es_admin_marca(p_marca)
  order by up.email, um.rol;
$$;

revoke execute on function competencias.asignar_rol_marca(text,uuid,text) from public, anon;
revoke execute on function competencias.quitar_rol_marca(uuid,uuid,text)  from public, anon;
revoke execute on function competencias.usuarios_de_marca(uuid)           from public, anon;
grant  execute on function competencias.asignar_rol_marca(text,uuid,text) to authenticated;
grant  execute on function competencias.quitar_rol_marca(uuid,uuid,text)  to authenticated;
grant  execute on function competencias.usuarios_de_marca(uuid)           to authenticated;

-- ---- PUENTE ERP (Liguify Financiero, esquema public) — §12, OPCIONAL -------
-- marca.erp_org_id null = cero rastro del ERP. Ver patch_erp_import.sql.
-- Una org ERP puede operar VARIAS marcas (N:1); vínculos e idempotencia POR MARCA.
alter table competencias.marca  add column if not exists erp_org_id    bigint;
alter table competencias.club   add column if not exists erp_club_id   bigint;
alter table competencias.equipo add column if not exists erp_equipo_id bigint;
alter table competencias.club   add constraint club_marca_erp_uk unique (marca_id, erp_club_id);
create index if not exists equipo_erp_idx on competencias.equipo(erp_equipo_id);

create or replace function competencias.erp_orgs_disponibles()
returns table(org_id bigint, nombre text)
language sql security definer stable
set search_path = public, competencias
as $$
  select o.id, o.nombre
  from public.organizaciones o
  where o.owner_user_id = auth.uid()
     or exists (select 1 from public.profiles p
                where p.id = auth.uid() and p.org_id = o.id and p.activo)
  order by o.nombre
$$;

create or replace function competencias.vincular_erp(p_marca uuid, p_org bigint)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_admin_marca(p_marca) then
    raise exception 'Sin permiso sobre esta marca';
  end if;
  if p_org is not null and not exists (
      select 1 from public.organizaciones o
      where o.id = p_org
        and (o.owner_user_id = auth.uid()
             or exists (select 1 from public.profiles p
                        where p.id = auth.uid() and p.org_id = o.id and p.activo))
  ) then
    raise exception 'No perteneces a esa organización del ERP';
  end if;
  update competencias.marca set erp_org_id = p_org where id = p_marca;
end $$;

create or replace function competencias.erp_torneos(p_marca uuid)
returns table(torneo_id bigint, nombre text, estado text, inicio date)
language sql security definer stable
set search_path = public, competencias
as $$
  select t.id, t.nombre, t.estado, t.inicio
  from public.torneos t
  join competencias.marca m on m.erp_org_id = t.org_id
  where m.id = p_marca
    and competencias.es_admin_marca(p_marca)
  order by t.created_at desc
$$;

create or replace function competencias.erp_equipos_torneo(p_marca uuid, p_torneo bigint)
returns table(erp_equipo_id bigint, erp_club_id bigint, club_nombre text,
              delegado text, telefono text, categoria text, modalidad text,
              sub_nombre text, estado text, invitado boolean,
              ya_importado boolean, club_vinculado boolean, club_adoptable boolean)
language sql security definer stable
set search_path = public, competencias
as $$
  select e.id, c.id, c.nombre, c.delegado, c.telefono,
         cat.nombre,
         coalesce(nullif(e.modalidad,''),
                  (select tc.modalidad from public.torneo_categorias tc
                   where tc.torneo_id = e.torneo_id and tc.cat_id = e.cat_id limit 1), ''),
         nullif(trim(e.nombre),''),
         e.estado, e.invitado,
         exists (select 1 from competencias.equipo q
                 join competencias.categoria cc on cc.id = q.categoria_id
                 join competencias.torneo tt on tt.id = cc.torneo_id
                 where tt.marca_id = p_marca and q.erp_equipo_id = e.id),
         exists (select 1 from competencias.club k
                 where k.marca_id = p_marca and k.erp_club_id = c.id),
         exists (select 1 from competencias.club k
                 where k.marca_id = p_marca and k.erp_club_id is null
                   and lower(trim(k.nombre)) = lower(trim(c.nombre)))
  from public.equipos e
  join public.clubes c     on c.id  = e.club_id
  join public.categorias cat on cat.id = e.cat_id
  join competencias.marca m on m.erp_org_id = e.org_id
  where e.torneo_id = p_torneo and m.id = p_marca
    and competencias.es_admin_marca(p_marca)
  order by cat.nombre, c.nombre, e.id
$$;

create or replace function competencias.importar_equipos_erp(p_categoria uuid, p_erp_torneo bigint, p_ids bigint[])
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare
  v_marca uuid; v_org bigint; v_club uuid; v_link bigint; v_creado boolean; r record;
  v_email text;
  n_reusados int := 0; n_adoptados int := 0; n_creados int := 0;
  n_eq int := 0; n_omitidos int := 0;
begin
  v_marca := competencias.marca_de_categoria(p_categoria);
  if v_marca is null or not competencias.es_admin_marca(v_marca) then
    raise exception 'Sin permiso sobre esta categoría';
  end if;
  select erp_org_id into v_org from competencias.marca where id = v_marca;
  if v_org is null then
    raise exception 'La marca no está vinculada al ERP';
  end if;
  if not exists (select 1 from public.torneos t where t.id = p_erp_torneo and t.org_id = v_org) then
    raise exception 'Ese torneo no pertenece a tu organización del ERP';
  end if;

  for r in
    select e.id as eq_id, e.nombre as sub_nombre,
           c.id as club_id, c.nombre as club_nombre, c.telefono as club_tel,
           c.email as club_email, c.logo_url as club_logo
    from public.equipos e
    join public.clubes c on c.id = e.club_id
    where e.torneo_id = p_erp_torneo and e.id = any(p_ids)
  loop
    if exists (select 1 from competencias.equipo q
               join competencias.categoria cc on cc.id = q.categoria_id
               join competencias.torneo tt on tt.id = cc.torneo_id
               where tt.marca_id = v_marca and q.erp_equipo_id = r.eq_id) then
      n_omitidos := n_omitidos + 1; continue;   -- re-importar no duplica (dentro de la marca)
    end if;
    v_creado := false;
    v_email  := nullif(trim(coalesce(r.club_email,'')),'');
    select id into v_club from competencias.club
    where marca_id = v_marca and erp_club_id = r.club_id;
    if v_club is not null then
      n_reusados := n_reusados + 1;
    else
      -- mismo nombre en la marca → usarlo SIEMPRE (club único por marca):
      -- sin vínculo se adopta; ya vinculado a otro registro ERP (duplicado
      -- en el ERP) se reusa sin tocar el vínculo.
      select id, erp_club_id into v_club, v_link from competencias.club
      where marca_id = v_marca
        and lower(trim(nombre)) = lower(trim(r.club_nombre))
      limit 1;
      if v_club is not null then
        if v_link is null then
          update competencias.club set erp_club_id = r.club_id where id = v_club;
          n_adoptados := n_adoptados + 1;
        else
          n_reusados := n_reusados + 1;
        end if;
      else
        insert into competencias.club (marca_id, nombre, contacto_tel, contacto_email, escudo_url, erp_club_id)
        values (v_marca, trim(r.club_nombre), r.club_tel, v_email, r.club_logo, r.club_id)
        returning id into v_club;
        n_creados := n_creados + 1;
        v_creado := true;
      end if;
    end if;
    -- Club existente: completar SOLO los campos vacíos (nunca sobrescribir)
    if not v_creado then
      update competencias.club set
        escudo_url     = coalesce(escudo_url, r.club_logo),
        contacto_email = coalesce(contacto_email, v_email),
        contacto_tel   = coalesce(contacto_tel, r.club_tel)
      where id = v_club
        and ( (escudo_url is null and r.club_logo is not null)
           or (contacto_email is null and v_email is not null)
           or (contacto_tel is null and r.club_tel is not null) );
    end if;
    insert into competencias.equipo (categoria_id, club_id, nombre, erp_equipo_id)
    values (p_categoria, v_club, nullif(trim(coalesce(r.sub_nombre,'')),''), r.eq_id);
    n_eq := n_eq + 1;
  end loop;

  return jsonb_build_object(
    'clubes_creados', n_creados, 'clubes_adoptados', n_adoptados,
    'clubes_reusados', n_reusados, 'equipos_creados', n_eq, 'omitidos', n_omitidos);
end $$;

revoke execute on function competencias.erp_orgs_disponibles()                       from public, anon;
revoke execute on function competencias.vincular_erp(uuid,bigint)                    from public, anon;
revoke execute on function competencias.erp_torneos(uuid)                            from public, anon;
revoke execute on function competencias.erp_equipos_torneo(uuid,bigint)              from public, anon;
revoke execute on function competencias.importar_equipos_erp(uuid,bigint,bigint[])   from public, anon;
grant  execute on function competencias.erp_orgs_disponibles()                       to authenticated;
grant  execute on function competencias.vincular_erp(uuid,bigint)                    to authenticated;
grant  execute on function competencias.erp_torneos(uuid)                            to authenticated;
grant  execute on function competencias.erp_equipos_torneo(uuid,bigint)              to authenticated;
grant  execute on function competencias.importar_equipos_erp(uuid,bigint,bigint[])   to authenticated;

-- ---- MÓDULO CLUB (The Hub) — delegados por código de un solo uso (I4) -------
create or replace function competencias.canjear_codigo_delegado(p_codigo text)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_eq record; v_email text;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión';
  end if;
  select e.id, e.club_id, c.nombre as club_nombre
  into v_eq
  from competencias.equipo e
  join competencias.club c on c.id = e.club_id
  where upper(trim(e.delegado_codigo)) = upper(trim(p_codigo))
  limit 1;
  if v_eq.id is null then
    return jsonb_build_object('ok', false, 'msg', 'Código inválido o ya utilizado');
  end if;
  select email into v_email from auth.users where id = auth.uid();
  insert into competencias.usuario_perfil(id, email)
    values (auth.uid(), coalesce(v_email,''))
    on conflict (id) do nothing;
  insert into competencias.usuario_club(usuario_id, club_id, rol, equipo_id)
    values (auth.uid(), v_eq.club_id, 'delegado', v_eq.id)
    on conflict do nothing;
  update competencias.equipo
    set delegado_id = auth.uid(), delegado_codigo = null
    where id = v_eq.id;
  return jsonb_build_object('ok', true, 'club', v_eq.club_nombre);
end $$;

create or replace function competencias.mis_equipos_club()
returns table(equipo_id uuid, equipo_nombre text, equipo_estado text,
              club_id uuid, club_nombre text, escudo_url text, color text,
              categoria_id uuid, categoria text, anio int, modalidad text,
              torneo_id uuid, torneo text, torneo_estado text,
              marca text, marca_slug text,
              permitir_delegados boolean, cargar_lbf boolean, lbf_max int, rol text)
language sql security definer stable
set search_path = competencias, public
as $$
  with acceso as (
    select e.id as eq_id, 'coordinador'::text as rol, 0 as prio
    from competencias.club c
    join competencias.equipo e on e.club_id = c.id
    where competencias.es_coordinador_club(c.id)
    union all
    select e.id, uc.rol, 1
    from competencias.usuario_club uc
    join competencias.equipo e on e.club_id = uc.club_id and uc.equipo_id = e.id
    where uc.usuario_id = auth.uid() and uc.rol = 'delegado'
    union all
    select e.id, 'subcoordinador', 2
    from competencias.usuario_club_categoria ucc
    join competencias.equipo e on e.club_id = ucc.club_id and e.categoria_id = ucc.categoria_id
    where ucc.usuario_id = auth.uid()
  )
  select distinct on (e.id)
         e.id, coalesce(e.nombre, c.nombre), e.estado,
         c.id, c.nombre, c.escudo_url, c.color,
         cat.id, coalesce(cat.nombre_display, 'Categoría '||cat.anio_nacimiento||' / '||cat.modalidad),
         cat.anio_nacimiento, cat.modalidad,
         t.id, t.nombre, t.estado, m.nombre, m.slug,
         t.permitir_delegados, t.cargar_lbf, t.lbf_max_jugadores, a.rol
  from acceso a
  join competencias.equipo e on e.id = a.eq_id
  join competencias.club c   on c.id = e.club_id
  join competencias.categoria cat on cat.id = e.categoria_id
  join competencias.torneo t on t.id = cat.torneo_id
  join competencias.marca m  on m.id = t.marca_id
  order by e.id, a.prio
$$;

-- Invitaciones de coordinador / sub-coordinador (ver patch_coordinadores.sql y
-- patch_coordinador_multimarca.sql): invitar_coordinador, invitar_subcoordinador,
-- mis_invitaciones, aceptar_invitacion, invitaciones_de_club, revocar_invitacion.
create or replace function competencias.invitar_coordinador(p_torneo uuid, p_club uuid, p_email text, p_nombre text, p_telefono text)
returns uuid
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_marca uuid; v_id uuid;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null or not competencias.es_admin_marca(v_marca) then
    raise exception 'Sin permiso sobre este torneo';
  end if;
  if not exists (select 1 from competencias.club where id = p_club and marca_id = v_marca) then
    raise exception 'El club no pertenece a la marca del torneo';
  end if;
  if coalesce(trim(p_email),'') = '' then raise exception 'El email es obligatorio'; end if;
  insert into competencias.invitacion_club(email, nombre, telefono, club_id, torneo_id, rol, invitado_por)
  values (lower(trim(p_email)), nullif(trim(p_nombre),''), nullif(trim(p_telefono),''), p_club, p_torneo, 'coordinador', auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function competencias.invitar_subcoordinador(p_torneo uuid, p_club uuid, p_email text, p_nombre text, p_telefono text, p_categorias uuid[])
returns uuid
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_marca uuid; v_id uuid;
begin
  select marca_id into v_marca from competencias.torneo where id = p_torneo;
  if v_marca is null then raise exception 'Torneo inválido'; end if;
  if not ( competencias.es_admin_marca(v_marca) or competencias.es_coordinador_club(p_club) ) then
    raise exception 'Solo el admin o el coordinador del club pueden invitar sub-coordinadores';
  end if;
  if coalesce(trim(p_email),'') = '' then raise exception 'El email es obligatorio'; end if;
  if p_categorias is null or array_length(p_categorias,1) is null then
    raise exception 'Elige al menos una categoría';
  end if;
  if exists (select 1 from unnest(p_categorias) x
             where not exists (select 1 from competencias.categoria c where c.id = x and c.torneo_id = p_torneo)) then
    raise exception 'Hay categorías que no pertenecen a este torneo';
  end if;
  insert into competencias.invitacion_club(email, nombre, telefono, club_id, torneo_id, rol, categorias, invitado_por)
  values (lower(trim(p_email)), nullif(trim(p_nombre),''), nullif(trim(p_telefono),''), p_club, p_torneo, 'subcoordinador', p_categorias, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function competencias.mis_invitaciones()
returns table(id uuid, rol text, club text, torneo text, marca text, nombre text, categorias text[])
language sql security definer stable
set search_path = competencias, public
as $$
  select i.id, i.rol, c.nombre, t.nombre, m.nombre, i.nombre,
         (select array_agg(coalesce(cat.nombre_display, 'Cat. '||cat.anio_nacimiento||'/'||cat.modalidad))
          from competencias.categoria cat where cat.id = any(i.categorias))
  from competencias.invitacion_club i
  join competencias.club c   on c.id = i.club_id
  join competencias.torneo t on t.id = i.torneo_id
  join competencias.marca m  on m.id = t.marca_id
  where i.estado = 'pendiente'
    and lower(i.email) = lower((select email from auth.users where id = auth.uid()))
  order by i.created_at desc
$$;

create or replace function competencias.aceptar_invitacion(p_id uuid)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare v record; v_email text;
begin
  select email into v_email from auth.users where id = auth.uid();
  select * into v from competencias.invitacion_club
  where id = p_id and estado = 'pendiente' and lower(email) = lower(coalesce(v_email,''));
  if v.id is null then
    return jsonb_build_object('ok', false, 'msg', 'Invitación no encontrada, ya usada o no corresponde a tu email');
  end if;
  insert into competencias.usuario_perfil(id, email, nombre)
    values (auth.uid(), coalesce(v_email,''), v.nombre)
    on conflict (id) do nothing;
  if v.rol = 'coordinador' then
    insert into competencias.usuario_club(usuario_id, club_id, rol)
      values (auth.uid(), v.club_id, 'coordinador')
      on conflict do nothing;
  else
    insert into competencias.usuario_club_categoria(usuario_id, club_id, categoria_id)
      select auth.uid(), v.club_id, unnest(v.categorias)
      on conflict do nothing;
  end if;
  update competencias.invitacion_club
    set estado = 'aceptada', aceptada_at = now(), usuario_id = auth.uid()
    where id = v.id;
  return jsonb_build_object('ok', true, 'rol', v.rol);
end $$;

create or replace function competencias.invitaciones_de_club(p_torneo uuid, p_club uuid)
returns table(id uuid, email text, nombre text, telefono text, rol text, estado text, categorias text[], created_at timestamptz)
language sql security definer stable
set search_path = competencias, public
as $$
  select i.id, i.email, i.nombre, i.telefono, i.rol, i.estado,
         (select array_agg(coalesce(cat.nombre_display, 'Cat. '||cat.anio_nacimiento||'/'||cat.modalidad))
          from competencias.categoria cat where cat.id = any(i.categorias)),
         i.created_at
  from competencias.invitacion_club i
  join competencias.torneo t on t.id = i.torneo_id
  where i.torneo_id = p_torneo and i.club_id = p_club
    and ( competencias.es_admin_marca(t.marca_id) or competencias.es_coordinador_club(p_club) )
  order by i.created_at desc
$$;

create or replace function competencias.revocar_invitacion(p_id uuid)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
declare v record;
begin
  select i.*, t.marca_id into v
  from competencias.invitacion_club i join competencias.torneo t on t.id = i.torneo_id
  where i.id = p_id;
  if v.id is null then raise exception 'Invitación no encontrada'; end if;
  if not ( competencias.es_admin_marca(v.marca_id) or competencias.es_coordinador_club(v.club_id) ) then
    raise exception 'Sin permiso para revocar esta invitación';
  end if;
  if v.estado <> 'pendiente' then raise exception 'Solo se pueden revocar invitaciones pendientes'; end if;
  update competencias.invitacion_club set estado = 'revocada' where id = p_id;
end $$;

revoke execute on function competencias.canjear_codigo_delegado(text)                           from public, anon;
revoke execute on function competencias.mis_equipos_club()                                      from public, anon;
revoke execute on function competencias.es_coordinador_club(uuid)                               from public, anon;
revoke execute on function competencias.invitar_coordinador(uuid,uuid,text,text,text)           from public, anon;
revoke execute on function competencias.invitar_subcoordinador(uuid,uuid,text,text,text,uuid[]) from public, anon;
revoke execute on function competencias.mis_invitaciones()                                      from public, anon;
revoke execute on function competencias.aceptar_invitacion(uuid)                                from public, anon;
revoke execute on function competencias.invitaciones_de_club(uuid,uuid)                         from public, anon;
revoke execute on function competencias.revocar_invitacion(uuid)                                from public, anon;
grant  execute on function competencias.canjear_codigo_delegado(text)                           to authenticated;
grant  execute on function competencias.mis_equipos_club()                                      to authenticated;
grant  execute on function competencias.es_coordinador_club(uuid)                               to authenticated;
grant  execute on function competencias.invitar_coordinador(uuid,uuid,text,text,text)           to authenticated;
grant  execute on function competencias.invitar_subcoordinador(uuid,uuid,text,text,text,uuid[]) to authenticated;
grant  execute on function competencias.mis_invitaciones()                                      to authenticated;
grant  execute on function competencias.aceptar_invitacion(uuid)                                to authenticated;
grant  execute on function competencias.invitaciones_de_club(uuid,uuid)                         to authenticated;
grant  execute on function competencias.revocar_invitacion(uuid)                                to authenticated;

-- I3: búsqueda de jugador por documento con datos CENSURADOS
-- (los datos completos solo tras confirmar la inscripción, vía flujo autenticado)
create or replace function competencias.buscar_jugador_censurado(p_pais text, p_doc text)
returns table (existe boolean, jugador_id uuid, nombre_censurado text,
               anio_nacimiento int, genero text, verificado boolean)
language sql stable security definer set search_path = competencias as $$
  select true, j.id,
         (select string_agg(left(w,1) || repeat('*', greatest(length(w)-1,2)), ' ')
            from unnest(string_to_array(j.nombres || ' ' || j.apellidos, ' ')) w),
         extract(year from j.fecha_nacimiento)::int,
         j.genero, j.verificado
  from jugador_maestro j
  where j.pais_documento = p_pais and j.nro_documento = p_doc
$$;
revoke all on function competencias.buscar_jugador_censurado(text,text) from public, anon;
grant execute on function competencias.buscar_jugador_censurado(text,text) to authenticated;

-- updated_at automático en partido
create or replace function competencias.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger trg_partido_touch before update on competencias.partido
for each row execute function competencias.touch_updated_at();

-- T2: al modificar el marcador o borrar el resultado, los eventos del en vivo se eliminan
create or replace function competencias.limpiar_eventos_si_cambia_resultado()
returns trigger language plpgsql security definer set search_path = competencias, pg_temp as $$
begin
  -- T2: solo cuando el ADMIN modifica el resultado (no cuando el Match Center
  -- en vivo deriva el marcador de sus propios eventos, estado 'en_vivo')
  if new.estado <> 'en_vivo'
     and ((old.goles_local is distinct from new.goles_local)
       or (old.goles_visita is distinct from new.goles_visita)) then
    delete from competencias.evento_partido where partido_id = new.id;
  end if;
  return new;
end $$;
create trigger trg_partido_limpia_eventos after update on competencias.partido
for each row execute function competencias.limpiar_eventos_si_cambia_resultado();

-- ============================================================================
-- 5. VISTAS (standings + público sin datos sensibles — T7)
-- ============================================================================

-- Standings por zona: SIEMPRE recalculado desde resultados (C5) —
-- computa finalizado + walkover (C4), respeta jornada.computa_en_tabla (T4)
-- y suma ajuste_puntos. El ORDEN final lo aplica el cliente según orden_tabla (T1).
create or replace view competencias.vista_tabla_zona as
with cfg as (
  select c.id as categoria_id,
         (competencias.config_efectiva(c.id)->>'puntos_ganado')::int  as pg_,
         (competencias.config_efectiva(c.id)->>'puntos_empate')::int  as pe_,
         (competencias.config_efectiva(c.id)->>'puntos_perdido')::int as pp_
  from competencias.categoria c
),
juegos as (
  select p.zona_id, p.categoria_id, e.id as equipo_id,
         case when p.local_id = e.id then p.goles_local  else p.goles_visita end as gf,
         case when p.local_id = e.id then p.goles_visita else p.goles_local  end as gc
  from competencias.partido p
  join competencias.equipo e on e.id in (p.local_id, p.visita_id)
  left join competencias.jornada j on j.id = p.jornada_id
  where p.estado in ('finalizado','walkover')
    and p.goles_local is not null
    and coalesce(j.computa_en_tabla, true)
)
select z.id  as zona_id, z.nombre as zona,
       e.categoria_id, e.id as equipo_id,
       coalesce(e.nombre, cl.nombre) as equipo,
       cl.color, e.color_dot,
       count(g.equipo_id)::int                                   as pj,
       count(*) filter (where g.gf > g.gc)::int                  as pg,
       count(*) filter (where g.gf = g.gc)::int                  as pe,
       count(*) filter (where g.gf < g.gc)::int                  as pp,
       coalesce(sum(g.gf),0)::int                                as gf,
       coalesce(sum(g.gc),0)::int                                as gc,
       coalesce(sum(g.gf) - sum(g.gc),0)::int                    as dg,
       (count(*) filter (where g.gf > g.gc) * cfg.pg_
      + count(*) filter (where g.gf = g.gc) * cfg.pe_
      + count(*) filter (where g.gf < g.gc) * cfg.pp_
      + e.ajuste_puntos)::int                                    as pts
from competencias.equipo e
join competencias.club cl on cl.id = e.club_id
join cfg on cfg.categoria_id = e.categoria_id
join competencias.equipo_en_zona ez on ez.equipo_id = e.id
join competencias.zona z on z.id = ez.zona_id
left join juegos g on g.equipo_id = e.id and g.zona_id = z.id
where e.estado = 'activo'
group by z.id, z.nombre, e.categoria_id, e.id, e.nombre, cl.nombre, cl.color,
         e.color_dot, e.ajuste_puntos, cfg.pg_, cfg.pe_, cfg.pp_;

-- Jugador PÚBLICO: nombre + SOLO AÑO de nacimiento (T3); sin documento ni scans
create or replace view competencias.vista_jugador_publico as
select j.id, j.nombres, j.apellidos,
       extract(year from j.fecha_nacimiento)::int as anio_nacimiento,
       case when j.consentimiento_imagen then j.foto_url else null end as foto_url,
       j.consentimiento_imagen,          -- false ⇒ frontend muestra B/N/placeholder
       j.verificado,
       j.pie_habil, j.posicion,          -- atributos (catálogo del maestro)
       extract(month from j.fecha_nacimiento)::int as mes_nacimiento  -- decisión 2026-08-07: público ve mes/año
from competencias.jugador_maestro j;

-- LBF pública (alineaciones): dorsal + nombre, sin datos médicos/documentales
create or replace view competencias.vista_lbf_publica as
select i.id as inscripcion_id, i.equipo_id, i.categoria_id, i.dorsal, i.capitan,
       i.es_excepcion, jp.nombres, jp.apellidos, jp.anio_nacimiento,
       jp.foto_url, jp.consentimiento_imagen,
       jp.pie_habil, jp.posicion, jp.mes_nacimiento
from competencias.inscripcion_lbf i
join competencias.vista_jugador_publico jp on jp.id = i.jugador_id
where i.en_lbf and not i.inhabilitado;

-- ============================================================================
-- 6. PERMISOS + RLS
-- ============================================================================
grant usage on schema competencias to anon, authenticated;
grant execute on function competencias.config_efectiva(uuid) to anon, authenticated;
grant execute on function competencias.es_admin_marca(uuid) to authenticated;
grant execute on function competencias.es_staff_marca(uuid) to authenticated;
grant execute on function competencias.marca_de_categoria(uuid) to authenticated;

-- Vistas públicas (corren como owner → exponen SOLO sus columnas)
grant select on competencias.vista_tabla_zona,
                competencias.vista_jugador_publico,
                competencias.vista_lbf_publica to anon, authenticated;

-- Tablas: select según sensibilidad; escritura por rol
grant select on competencias.marca, competencias.torneo, competencias.categoria,
                competencias.fase, competencias.zona, competencias.jornada,
                competencias.club, competencias.equipo, competencias.equipo_en_zona,
                competencias.partido, competencias.evento_partido,
                competencias.planilla_partido to anon, authenticated;
grant select on competencias.jugador_maestro, competencias.inscripcion_lbf,
                competencias.acreditacion_partido, competencias.sancion_global,
                competencias.usuario_perfil, competencias.usuario_marca,
                competencias.usuario_club, competencias.auditoria to authenticated;
grant insert, update on all tables in schema competencias to authenticated;
grant delete on competencias.partido, competencias.equipo_en_zona,
  competencias.evento_partido, competencias.inscripcion_lbf,
  competencias.acreditacion_partido to authenticated;  -- RLS sigue gobernando quién
grant update (goles_local, goles_visita, estado, penales, penales_local, penales_visita, updated_at)
  on competencias.partido to anon;          -- ⚠ solo para poc_write_partido

alter table competencias.marca                enable row level security;
alter table competencias.club                 enable row level security;
alter table competencias.jugador_maestro      enable row level security;
alter table competencias.sancion_global       enable row level security;
alter table competencias.usuario_perfil       enable row level security;
alter table competencias.usuario_marca        enable row level security;
alter table competencias.usuario_club         enable row level security;
alter table competencias.torneo               enable row level security;
alter table competencias.categoria            enable row level security;
alter table competencias.fase                 enable row level security;
alter table competencias.zona                 enable row level security;
alter table competencias.jornada              enable row level security;
alter table competencias.equipo               enable row level security;
alter table competencias.equipo_en_zona       enable row level security;
alter table competencias.inscripcion_lbf      enable row level security;
alter table competencias.partido              enable row level security;
alter table competencias.evento_partido       enable row level security;
alter table competencias.planilla_partido     enable row level security;
alter table competencias.acreditacion_partido enable row level security;
alter table competencias.auditoria            enable row level security;

-- ---- LECTURA PÚBLICA (módulo público sin login) ----------------------------
create policy pub_read on competencias.marca     for select using (true);
create policy pub_read on competencias.torneo    for select using (estado <> 'borrador' or competencias.es_staff_marca(marca_id));
create policy pub_read on competencias.categoria for select using (true);
create policy pub_read on competencias.fase      for select using (true);
create policy pub_read on competencias.zona      for select using (visible or competencias.es_staff_marca(competencias.marca_de_categoria((select categoria_id from competencias.fase f where f.id = fase_id))));
create policy pub_read on competencias.jornada   for select using (visible or competencias.es_staff_marca(competencias.marca_de_categoria(categoria_id)));
create policy pub_read on competencias.club      for select using (true);
create policy pub_read on competencias.equipo    for select using (true);
create policy pub_read on competencias.equipo_en_zona for select using (true);
create policy pub_read on competencias.partido   for select using (visible or competencias.es_staff_marca(competencias.marca_de_categoria(categoria_id)));
create policy pub_read on competencias.evento_partido  for select using (true);
create policy pub_read on competencias.planilla_partido for select using (true);

-- ---- SENSIBLES: solo autenticados con contexto -----------------------------
create policy auth_read on competencias.jugador_maestro for select
  using (auth.uid() is not null);   -- v2: restringir a staff/coordinadores con vínculo
create policy auth_read on competencias.inscripcion_lbf for select
  using (auth.uid() is not null);
create policy auth_read on competencias.acreditacion_partido for select
  using (auth.uid() is not null);
create policy auth_read on competencias.sancion_global for select
  using (auth.uid() is not null);
create policy self_read on competencias.usuario_perfil for select
  using (id = auth.uid() or competencias.es_super());
create policy self_read on competencias.usuario_marca  for select using (usuario_id = auth.uid());
create policy self_read on competencias.usuario_club   for select using (usuario_id = auth.uid());

-- ---- ESCRITURA por rol -----------------------------------------------------
create policy adm_write on competencias.marca for update
  using (competencias.es_admin_marca(id)) with check (competencias.es_admin_marca(id));
create policy adm_ins on competencias.marca for insert
  with check (competencias.es_super());

create policy adm_all on competencias.torneo for all
  using (competencias.es_admin_marca(marca_id)) with check (competencias.es_admin_marca(marca_id));
create policy adm_all on competencias.club for all
  using (competencias.es_admin_marca(marca_id)) with check (competencias.es_admin_marca(marca_id));
create policy adm_all on competencias.categoria for all
  using (competencias.es_admin_marca(competencias.marca_de_categoria(id)))
  with check (competencias.es_admin_marca((select marca_id from competencias.torneo t where t.id = torneo_id)));
create policy adm_all on competencias.fase for all
  using (competencias.es_admin_marca(competencias.marca_de_categoria(categoria_id)))
  with check (competencias.es_admin_marca(competencias.marca_de_categoria(categoria_id)));
create policy adm_all on competencias.zona for all
  using (competencias.es_admin_marca(competencias.marca_de_categoria((select categoria_id from competencias.fase f where f.id = fase_id))))
  with check (true);
create policy adm_all on competencias.jornada for all
  using (competencias.es_admin_marca(competencias.marca_de_categoria(categoria_id)))
  with check (competencias.es_admin_marca(competencias.marca_de_categoria(categoria_id)));
create policy adm_all on competencias.equipo for all
  using (competencias.es_admin_marca(competencias.marca_de_categoria(categoria_id)))
  with check (competencias.es_admin_marca(competencias.marca_de_categoria(categoria_id)));
create policy adm_all on competencias.equipo_en_zona for all
  using (true) with check (auth.uid() is not null);

-- Jugador maestro: crear autenticado; editar solo si NO verificado o super (M9)
create policy jug_ins on competencias.jugador_maestro for insert
  with check (auth.uid() is not null);
create policy jug_upd on competencias.jugador_maestro for update
  using ((not verificado) or competencias.es_super());

-- LBF: staff de la marca, coordinador (multimarca por organización), delegado
-- por equipo, o sub-coordinador por categoría
create policy lbf_write on competencias.inscripcion_lbf for all
  using (
    competencias.es_staff_marca(competencias.marca_de_categoria(categoria_id))
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

alter table competencias.usuario_club_categoria enable row level security;
create policy self_read on competencias.usuario_club_categoria for select
  using (usuario_id = auth.uid());
grant select on competencias.usuario_club_categoria to authenticated;
alter table competencias.invitacion_club enable row level security;  -- sin policies: solo RPC

-- Blindaje LBF: el club puede editar dorsal/capitán, pero estado/inhabilitado/
-- apto/excepción solo los cambia el staff de la marca (se revierten en silencio).
-- Excepción controlada: subir_autorizacion_jugador habilita SOLO pendiente→activo
-- vía set_config (autorización de Padre/Tutor).
create or replace function competencias.proteger_lbf_estado()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if competencias.es_staff_marca(competencias.marca_de_categoria(new.categoria_id)) then
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
create trigger t_proteger_lbf before update on competencias.inscripcion_lbf
for each row execute function competencias.proteger_lbf_estado();

-- ---- AUTORIZACIÓN DE PADRE/TUTOR (única por jugador, activa la inscripción) --
alter table competencias.torneo
  add column if not exists requiere_autorizacion boolean not null default false;
alter table competencias.jugador_maestro
  add column if not exists autorizacion_url   text,   -- ruta en bucket PRIVADO 'documentos'
  add column if not exists autorizacion_fecha timestamptz;

create or replace function competencias.subir_autorizacion_jugador(p_jugador uuid, p_inscripcion uuid, p_ruta text default null)
returns jsonb
language plpgsql security definer
set search_path = competencias, public
as $$
declare
  v_ins record; v_req boolean; v_url text; v_activado boolean := false;
begin
  select i.id, i.equipo_id, i.categoria_id, i.estado, c.torneo_id
    into v_ins
  from competencias.inscripcion_lbf i
  join competencias.categoria c on c.id = i.categoria_id
  where i.id = p_inscripcion and i.jugador_id = p_jugador;
  if v_ins.id is null or not competencias.gestiona_equipo(v_ins.equipo_id, v_ins.categoria_id) then
    raise exception 'Sin permiso sobre esta inscripción';
  end if;
  if p_ruta is not null then
    update competencias.jugador_maestro set
      autorizacion_url      = p_ruta,
      autorizacion_fecha    = now(),
      consentimiento_imagen = true,
      consentimiento_fecha  = coalesce(consentimiento_fecha, now())
    where id = p_jugador;
  end if;
  select autorizacion_url into v_url from competencias.jugador_maestro where id = p_jugador;
  if v_url is null then
    raise exception 'El jugador aún no tiene autorización subida';
  end if;
  select t.requiere_autorizacion into v_req
  from competencias.torneo t where t.id = v_ins.torneo_id;
  if coalesce(v_req, false) and v_ins.estado = 'pendiente' then
    perform set_config('competencias.activar_por_autorizacion', '1', true);
    update competencias.inscripcion_lbf set estado = 'activo' where id = p_inscripcion;
    perform set_config('competencias.activar_por_autorizacion', '', true);
    v_activado := true;
  end if;
  return jsonb_build_object('ok', true, 'activado', v_activado, 'autorizacion_url', v_url);
end $$;
revoke execute on function competencias.subir_autorizacion_jugador(uuid,uuid,text) from public, anon;
grant  execute on function competencias.subir_autorizacion_jugador(uuid,uuid,text) to authenticated;

-- ---- ESTADÍSTICAS POR JUGADOR (minutos/asistencias + duración del partido) --
-- Se capturan en CARGAR RESULTADO; el módulo Club muestra PJ/min/goles/asist/
-- %participación/min-promedio/por-90 calculados sobre torneo.duracion_partido.
alter table competencias.torneo
  add column if not exists duracion_partido int not null default 90;  -- minutos
alter table competencias.planilla_partido
  add column if not exists minutos     int not null default 0,
  add column if not exists asistencias int not null default 0;

-- ---- COMANDO TÉCNICO (por equipo/torneo; misma maestra global) --------------
-- torneo.ct_max_personas define el máximo por equipo (default 5)
alter table competencias.torneo add column if not exists ct_max_personas int not null default 5;

create table if not exists competencias.comando_tecnico (
  id           uuid primary key default gen_random_uuid(),
  equipo_id    uuid not null references competencias.equipo(id) on delete cascade,
  categoria_id uuid not null references competencias.categoria(id) on delete cascade,
  persona_id   uuid not null references competencias.jugador_maestro(id),
  rol          text not null check (rol in ('Entrenador','Asistente Técnico','Preparador físico','Preparador de arqueros','Médico')),
  estado       text not null default 'pendiente' check (estado in ('pendiente','activo')),
  inhabilitado boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (equipo_id, persona_id)
);
alter table competencias.comando_tecnico enable row level security;

-- alcance de gestión de un equipo (staff, coordinador multimarca, delegado, sub)
create or replace function competencias.gestiona_equipo(p_equipo uuid, p_categoria uuid)
returns boolean
language sql stable security definer
set search_path = competencias
as $$
  select competencias.es_staff_marca(competencias.marca_de_categoria(p_categoria))
      or exists (select 1 from equipo e where e.id = p_equipo and competencias.es_coordinador_club(e.club_id))
      or exists (select 1 from usuario_club uc
                 where uc.usuario_id = auth.uid() and uc.rol = 'delegado' and uc.equipo_id = p_equipo)
      or exists (select 1 from usuario_club_categoria ucc
                 join equipo e2 on e2.id = p_equipo
                 where ucc.usuario_id = auth.uid() and ucc.club_id = e2.club_id
                   and ucc.categoria_id = p_categoria)
$$;

create policy ct_read on competencias.comando_tecnico for select
  using (auth.uid() is not null);
create policy ct_write on competencias.comando_tecnico for all
  using (competencias.gestiona_equipo(equipo_id, categoria_id))
  with check (auth.uid() is not null);
grant select, insert, update, delete on competencias.comando_tecnico to authenticated;

create or replace function competencias.proteger_ct_estado()
returns trigger language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not competencias.es_staff_marca(competencias.marca_de_categoria(new.categoria_id)) then
    new.estado       := old.estado;
    new.inhabilitado := old.inhabilitado;
  end if;
  return new;
end $$;
create trigger t_proteger_ct before update on competencias.comando_tecnico
for each row execute function competencias.proteger_ct_estado();

-- Fotos y documentos de la persona (jugador o CT): permiso = gestiona algún
-- equipo donde está inscrita. Foto → bucket publico/jugadores; DNI → bucket
-- PRIVADO documentos/jugadores (ver patch_docs_jugador.sql para el bucket)
create or replace function competencias.actualizar_foto_jugador(p_jugador uuid, p_url text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para actualizar la foto de esta persona';
  end if;
  update competencias.jugador_maestro set foto_url = p_url where id = p_jugador;
end $$;

create or replace function competencias.actualizar_docs_jugador(p_jugador uuid, p_frente text, p_reverso text)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if not ( exists (select 1 from competencias.inscripcion_lbf i
                   where i.jugador_id = p_jugador
                     and competencias.gestiona_equipo(i.equipo_id, i.categoria_id))
        or exists (select 1 from competencias.comando_tecnico ct
                   where ct.persona_id = p_jugador
                     and competencias.gestiona_equipo(ct.equipo_id, ct.categoria_id)) ) then
    raise exception 'Sin permiso para actualizar los documentos de esta persona';
  end if;
  update competencias.jugador_maestro set
    doc_scan_frente_url  = coalesce(p_frente,  doc_scan_frente_url),
    doc_scan_reverso_url = coalesce(p_reverso, doc_scan_reverso_url)
  where id = p_jugador;
end $$;

revoke execute on function competencias.gestiona_equipo(uuid,uuid)               from public, anon;
revoke execute on function competencias.actualizar_foto_jugador(uuid,text)       from public, anon;
revoke execute on function competencias.actualizar_docs_jugador(uuid,text,text)  from public, anon;
grant  execute on function competencias.gestiona_equipo(uuid,uuid)               to authenticated;
grant  execute on function competencias.actualizar_foto_jugador(uuid,text)       to authenticated;
grant  execute on function competencias.actualizar_docs_jugador(uuid,text,text)  to authenticated;

-- Partido: staff (admin o mesa) de la marca
create policy staff_all on competencias.partido for all
  using (competencias.es_staff_marca(competencias.marca_de_categoria(categoria_id)))
  with check (competencias.es_staff_marca(competencias.marca_de_categoria(categoria_id)));
-- ⚠ TEMPORAL para poc-sync.html sin auth — BORRAR al cablear login:
create policy poc_write_partido on competencias.partido for update
  using (true) with check (true);

create policy staff_all on competencias.evento_partido for all
  using (auth.uid() is not null) with check (auth.uid() is not null);
create policy staff_all on competencias.planilla_partido for all
  using (auth.uid() is not null) with check (auth.uid() is not null);
create policy staff_all on competencias.acreditacion_partido for all
  using (auth.uid() is not null) with check (auth.uid() is not null);

create policy audit_ins on competencias.auditoria for insert with check (auth.uid() is not null);
create policy audit_read on competencias.auditoria for select
  using (marca_id is null or competencias.es_admin_marca(marca_id));

create policy super_all on competencias.sancion_global for all
  using (competencias.es_super()) with check (competencias.es_super());
create policy self_ins on competencias.usuario_perfil for insert with check (id = auth.uid());
create policy adm_ins  on competencias.usuario_marca for insert
  with check (competencias.es_admin_marca(marca_id));
create policy adm_ins  on competencias.usuario_club for insert
  with check (auth.uid() is not null);

-- ---- Realtime --------------------------------------------------------------
alter publication supabase_realtime add table competencias.partido;
alter publication supabase_realtime add table competencias.evento_partido;

-- ============================================================================
-- 7. SEED — INTI CUP ORO · Categoría 2017/F7 · Zona A (+ LBF de ACAR)
-- ============================================================================
do $$
declare
  v_marca uuid; v_torneo uuid; v_cat uuid; v_fase uuid; v_zona uuid;
  j1 uuid; j2 uuid;
  c_acar uuid; c_alsur uuid; c_sbsa uuid; c_amsmp uuid;
  e_acar uuid; e_alsur uuid; e_sbsa uuid; e_amsmp uuid;
  m1 uuid; m2 uuid;
begin
  insert into competencias.marca (nombre, slug, ciudad, membresia, email)
  values ('INTI CUP','inticup','Lima','premium','contacto@inticup.pe') returning id into v_marca;

  insert into competencias.torneo (marca_id, nombre, slug, estado, mostrar_tabla_general)
  values (v_marca,'INTI CUP ORO','oro','en_curso', true) returning id into v_torneo;

  insert into competencias.categoria (torneo_id, anio_nacimiento, modalidad, nombre_display)
  values (v_torneo, 2017,'F7','Categoría 2017 / F7') returning id into v_cat;

  insert into competencias.fase (categoria_id, nombre, tipo) values (v_cat,'Fase de Grupos','grupos') returning id into v_fase;
  insert into competencias.zona (fase_id, nombre) values (v_fase,'A') returning id into v_zona;
  insert into competencias.jornada (categoria_id, numero, nombre) values (v_cat,1,'Fecha 1') returning id into m1;
  insert into competencias.jornada (categoria_id, numero, nombre) values (v_cat,2,'Fecha 2') returning id into m2;

  insert into competencias.club (marca_id,nombre,color) values (v_marca,'ACAR','#1d4ed8') returning id into c_acar;
  insert into competencias.club (marca_id,nombre,color) values (v_marca,'Alianza Lima Surquillo','#d9232e') returning id into c_alsur;
  insert into competencias.club (marca_id,nombre,color) values (v_marca,'Sport Boys Sor Ana','#7c3aed') returning id into c_sbsa;
  insert into competencias.club (marca_id,nombre,color) values (v_marca,'Amigos SMP','#0d9488') returning id into c_amsmp;

  insert into competencias.equipo (categoria_id,club_id) values (v_cat,c_acar)  returning id into e_acar;
  insert into competencias.equipo (categoria_id,club_id) values (v_cat,c_alsur) returning id into e_alsur;
  insert into competencias.equipo (categoria_id,club_id) values (v_cat,c_sbsa)  returning id into e_sbsa;
  insert into competencias.equipo (categoria_id,club_id) values (v_cat,c_amsmp) returning id into e_amsmp;
  insert into competencias.equipo_en_zona (zona_id, equipo_id)
  values (v_zona,e_acar),(v_zona,e_alsur),(v_zona,e_sbsa),(v_zona,e_amsmp);

  -- jugadores maestros + LBF de ACAR
  insert into competencias.jugador_maestro (nro_documento,nombres,apellidos,fecha_nacimiento,genero,verificado,consentimiento_imagen)
  values ('80123455','Gael','Llallahui Diaz','2017-05-02','Masculino',true,true) returning id into j1;
  insert into competencias.jugador_maestro (nro_documento,nombres,apellidos,fecha_nacimiento,genero,verificado)
  values ('80234561','Fabio','Alvitez Quispe','2017-06-24','Masculino',true) returning id into j2;
  insert into competencias.inscripcion_lbf (equipo_id,jugador_id,categoria_id,dorsal,capitan,estado,fecha_apto_medico)
  values (e_acar,j1,v_cat,9,true,'activo','2026-07-01'),
         (e_acar,j2,v_cat,8,false,'activo','2026-07-01');

  insert into competencias.partido (categoria_id,fase_id,zona_id,jornada_id,local_id,visita_id,goles_local,goles_visita,estado,fecha,hora,sede)
  values (v_cat,v_fase,v_zona,m1,e_acar,e_alsur,2,1,'finalizado','2026-07-13','09:00','Arena 7 - Campo Azul 2'),
         (v_cat,v_fase,v_zona,m1,e_sbsa,e_amsmp,null,null,'programado','2026-07-13','10:00','Arena 7 - Campo Azul 1'),
         (v_cat,v_fase,v_zona,m2,e_acar,e_sbsa,null,null,'programado','2026-07-14','09:00','Arena 7 - Campo Azul 2'),
         (v_cat,v_fase,v_zona,m2,e_alsur,e_amsmp,null,null,'programado','2026-07-14','10:00','Arena 7 - Campo Azul 1');
end $$;

select 'OK: esquema competencias v1 COMPLETO' as resultado,
       (select count(*) from information_schema.tables where table_schema='competencias') as tablas,
       (select count(*) from competencias.partido) as partidos,
       (select count(*) from competencias.vista_tabla_zona) as filas_standings;
