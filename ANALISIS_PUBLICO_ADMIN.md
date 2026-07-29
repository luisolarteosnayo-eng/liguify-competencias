# Liguify v1 — Análisis funcional: Módulos Público y Administrador

> Lado **deportivo** del portafolio Liguify. API-First, multi-tenant, multi-país, multi-deporte (fútbol primero).
> El módulo **Club** (The Hub / delegados / LBF self-service) se especifica por separado más adelante.
> Diseño visual objetivo: `https://liguifyv1.lovable.app/`.

---

## 1. Estructura de datos (modelo de dominio)

Principio rector: separar lo **global y reutilizable** (se comparte entre marcas y torneos, y con el ERP/Academias) de lo **instanciado por competición** (vive dentro de una categoría y se aísla).

### 1.1. Entidades globales (maestras)

**`marca`** (Tenant — Nivel 1)
| campo | tipo | nota |
|-------|------|------|
| id | uuid | |
| nombre | text | INTI CUP, NOVA CUP |
| **slug** | text | **UNIQUE, NOT NULL** — minúsculas/números (inticup, novacup, idvlima). Alimenta la ruta pública `liguify.com/<slug>` y el subdominio compartible `<slug>.liguify.com` (Decisión 7). Prohibidos los reservados: admin, erp, academias, www, api |
| logo_url | text | |
| pais | text | país base |
| owner_usuario_id | uuid | dueño / admin de marca |

**`club`** (institución — **ÚNICO POR MARCA**, decidido 2026-07-19, resuelve C1)
> El club NO es global del sistema: cada marca tiene su propia cartera de clubes. "Alianza Lima" de INTI CUP y "Alianza Lima" de NOVA CUP pueden coincidir en el mundo real pero son registros independientes. Razón: **protección de clientes** — los clubes de una marca son su cartera comercial y no se comparten con otras marcas (RLS aísla por marca_id). El club sí se reutiliza entre TODOS los torneos de su marca (escudo/nombre únicos dentro de la marca). El vínculo con ERP/Academias es por marca. Asimetría deliberada: `jugador_maestro` SÍ es global (anti-suplantación cruza marcas); `club` no.

| campo | tipo | nota |
|-------|------|------|
| id | uuid | |
| **marca_id** | uuid | **NOT NULL** — el club pertenece a la marca |
| nombre | text | Alianza Lima · **UNIQUE (marca_id, nombre)** |
| escudo_url | text | único dentro de la marca; aplica a todos sus torneos |
| ruc_id_fiscal | text | |
| contacto_email / contacto_tel | text | |
| pais | text | |

**`jugador_maestro`** (persona, reutilizable entre torneos — **núcleo anti-suplantación**)
| campo | tipo | nota |
|-------|------|------|
| id | uuid | |
| pais_documento | text | **se deriva del tipo de documento** |
| tipo_documento | enum | DNI, Pasaporte, … (lleva el país) |
| nro_documento | text | |
| nombres / apellidos | text | **separados** (contrato de integración con Academias, §7) — bloqueados tras verificación |
| foto_url | text | bloqueada tras verificación |
| fecha_nacimiento | date | determina categoría-año |
| genero | enum | Masculino / Femenino |
| doc_scan_frente_url / doc_scan_reverso_url | text | escaneo de DNI — storage PRIVADO, nunca expuesto al público (T7) |
| verificado | bool | |
| consentimiento_imagen | bool | T3 (en análisis): false ⇒ foto en B/N en el público; true (aprobación explícita del padre/tutor) ⇒ foto a color. + fecha_consentimiento, otorgado_por |
| **Privacidad público (T3)** | | el módulo público muestra nombre + **solo el AÑO** de nacimiento (nunca día/mes) |
| **UNIQUE** | | **(pais_documento, nro_documento)** |

**`usuario`** (identidad de personas con acceso: admins, coordinadores)
| campo | tipo | nota |
|-------|------|------|
| id | uuid | |
| email | text | |
| password_hash | text | |
| nombre | text | |
| estado | enum | invitado / activo |

**`usuario_marca`** (membresías/roles a nivel marca — I6)
| campo | tipo | nota |
|-------|------|------|
| usuario_id, marca_id | uuid | |
| rol | enum | admin_marca / mesa_control |

**`usuario_club`** (membresías/roles a nivel club — I6; base de The Hub: un coordinador vinculado a N clubes de N marcas ve todos sus torneos en una sesión)
| campo | tipo | nota |
|-------|------|------|
| usuario_id, club_id | uuid | |
| rol | enum | coordinador / delegado |
| equipo_id | uuid? | si el rol delegado está limitado a un equipo específico |

**`sancion_global`** (fallos de oficio a nivel plataforma — I5, spec 2.4)
| campo | tipo | nota |
|-------|------|------|
| id, jugador_maestro_id | uuid | bloquea TODAS sus inscripciones/alineaciones mientras esté vigente |
| motivo | text | |
| vigencia_desde / vigencia_hasta | date | null en hasta = indefinida |
| emitida_por | uuid | super-admin de plataforma |

### 1.2. Jerarquía de competición

```
marca (Nivel 1 · tenant)             INTI CUP · IDV LIMA · NOVA CUP
 └─ torneo / circuito (Nivel 2)      ej. INTI CUP ORO 2026   ← reglas configurables
    ·· OPCIONAL de cara al usuario: si la marca no define torneos (caso IDV LIMA),
       se crea un torneo IMPLÍCITO oculto con el nombre de la marca (ver Decisión 7)
     └─ categoria (Nivel 3)          ej. Categoría 2016 / F7
         ·· modalidad (F7|F9|F11)    ← ATRIBUTO de la categoría, NO un nivel jerárquico
                                       (verificado por Luis 2026-07-19; unicidad = año+modalidad)
         └─ fase                     Fase de Grupos · Copa Oro · Copa Plata · Repechaje Oro
             └─ zona (grupo)         A · B · C
                 └─ equipo (sub-eq.) Alianza Lima A / B  (instancia de club — el club es de la marca)
                     └─ inscripcion_lbf → jugador_maestro
```

**`torneo`** (Circuito / Sub-tenant — Nivel 2). Contiene el **bloque de reglas** (según formulario "Editar torneo"):
| campo | tipo | default |
|-------|------|---------|
| id, marca_id, nombre, pais, sede, nivel, estado | | |
| logo_url | url? | null — **fallback: si el torneo no tiene logo propio, se usa el logo de la marca** (definido por Luis 2026-07-19) |
| anio_temporada | int | 2026 |
| tipo_default (modalidad) | enum | F7 / F9 / F11 |
| **Puntajes** — puntos que se suman a los equipos cuando se registra el resultado de su partido | | |
| puntos_ganado / empate / perdido | int | 3 / 1 / 0 |
| sumar_puntos_walkover | bool | off |
| goles_ganado_walkover | int | 3 |
| puntos_perdido_walkover | int | 0 |
| **Tabla** | | |
| orden_tabla | array | [PJ, PUNTOS, DIF_GOL, GF, GC] — campo de **DOBLE PROPÓSITO** (T1, 2026-07-19): la secuencia define (a) las **columnas** que muestra la tabla pública y su orden, y (b) la **precedencia de los criterios de desempate** deportivo (se ordena por cada valor en secuencia). Valores posibles a futuro: H2H (head-to-head), FAIR_PLAY. Último recurso cuando todo empata: orden alfabético/sorteo manual del admin. Nota: PJ como columna informativa normalmente no debería ir primero en la secuencia de desempate — responsabilidad del admin |
| mostrar_tabla_general | bool | on — si está activa, la portada pública del torneo muestra la **Tabla General**: acumulado por **EQUIPO** de la suma de TODAS sus categorías (PJ/PG/PE/PP/GF/GC/PTS agregados). Los sub-equipos acumulan de forma **independiente** (Alianza Lima A ≠ Alianza Lima B): la llave del acumulado es la identidad del equipo, no el club. El detalle individual se ve al entrar a cada categoría. (Definido por Luis 2026-07-19; implementado en mockup-publico.html `tablaGeneral()`) |
| mostrar_excepciones_edad | bool | off |
| **Disciplina** | | |
| amarillas_para_suspension | int? | null = sin suspensión |
| fecha_limite_acum_amarillas | date? | |
| **LBF** | | |
| lbf_max_jugadores | int | 30 — máximo de jugadores/as **POR EQUIPO** en su LBF (I7, 2026-07-19); el valor se configura por categoría (hereda del torneo, override D1) |
| cargar_lbf | bool | on — habilita la opción de agregar jugadores; **hay torneos que no requieren carga de jugadores** (si está off, no se muestra la carga de LBF) |
| scan_dni_obligatorio | bool | off |
| **Delegados / carga** | | |
| permitir_delegados | bool | on — habilita el **envío de usuario a los clubes** para que agreguen jugadores y tengan acceso al **modo Club** |
| fecha_limite_carga_equipo | date | |
| permitir_modificacion_equipo | bool | on |
| descripcion | rich text | |

> **Decisión D1 (resuelta):** herencia con **override total**. Las reglas se definen a nivel **Torneo** como default; cada **Categoría puede sobreescribir cualquier campo** (modalidad, puntajes, orden de tabla, LBF, disciplina, etc.). En la práctica: `config` efectiva de una categoría = `torneo.config` ⊕ `categoria.config_override` (solo los campos que difieran). La UI debe mostrar qué valores son heredados vs sobreescritos.
>
> **Refinamiento I8 (2026-07-19):** el override aplica a los campos **heredables** — puntajes/walkover, orden_tabla, disciplina, LBF (máx, cargar, scan), modalidad, excepciones por edad. Son **solo-torneo** (sin override por categoría, no tiene sentido): `mostrar_tabla_general`, `permitir_delegados`, `fecha_limite_carga_equipo`, `permitir_modificacion_equipo`, logo y descripción.

**`categoria`** (Nivel 3 — la modalidad es un atributo suyo)

> La llave lógica de la categoría dentro de un torneo es **(año_nacimiento + modalidad)** — no solo el año. Confirmado por la estructura real de Luis (2026-07-19): INTI CUP FORMATIVO y NOVA CUP FORMATIVO tienen a la vez "Categoría 2016 F7" y "Categoría 2016 F9". Estructura de referencia: marca INTI CUP → torneos ORO / PLATA NORTE / PLATA SUR / INTERNACIONAL / FORMATIVO; marcas IDV LIMA y NOVA CUP (NOVA CUP / INTERNACIONAL / FORMATIVO).
| campo | tipo | nota |
|-------|------|------|
| id, torneo_id | | |
| anio_nacimiento | int | 2016 |
| modalidad | enum | F7 / F9 / F11 (afecta acta y mínimos de plantilla) |
| nombre_display | text | "Categoría 2016 / F7" |
| fecha_inicio / fecha_fin | date | rango del torneo |
| config_override | jsonb | **override de cualquier regla del torneo** (D1); vacío = hereda todo |

**`fase`**: id, categoria_id, nombre (Fase de Grupos / Copa Oro / Copa Plata / Repechaje Oro), tipo (grupos | eliminacion | repechaje), orden.

**`zona`** (grupo): id, fase_id, nombre (A/B/C), visible (bool — "Mostrar/ocultar zona").

**`equipo`** (sub-equipo — instancia de club en la categoría)
| campo | tipo | nota |
|-------|------|------|
| id, categoria_id, club_id | | club_id **NOT NULL**: todo equipo pertenece a un club (de la misma marca del torneo) |
| nombre | text | **LIBRE** (verificado 2026-07-19): por defecto el nombre del club (UNIVERSITARIO); puede ser club+sufijo (ALIANZA LIMA A / B / AZUL) o un nombre totalmente distinto (SPORTING CRISTAL → "SELECTIVO"). El escudo mostrado SIEMPRE es el del club (único por marca) |
| foto_url | text | foto del equipo (la del plantel, no el escudo) |
| sede | text | |
| color_identificador | text | el "punto de color" del público |
| delegado_usuario_id | uuid? | |
| delegado_codigo | text? | código de **UN SOLO USO** para vincular la cuenta del delegado (I4): se canjea con email/contraseña, luego se invalida; el acceso queda nominal y revocable |
| ajuste_puntos | int | sumar/quitar puntos manual |
| premio_tipo | enum? | catálogo: Campeón, Subcampeón, Fair Play, Goleador, Valla menos vencida |
| premio_libre | text? | premio fuera de catálogo |
| estado | enum | activo / inactivo (nunca se borra) |

**`equipo_en_zona`** (un equipo puede estar en la zona de grupos y luego en una llave): id, zona_id, equipo_id.

**`inscripcion_lbf`** (jugador ↔ equipo; la ficha de LBF)
| campo | tipo | nota |
|-------|------|------|
| id, equipo_id, jugador_maestro_id | | |
| categoria_id | uuid | **desnormalizado** (I9) para la constraint declarativa anti-suplantación: **UNIQUE (jugador_maestro_id, categoria_id)** — sin triggers |
| dorsal | int | |
| en_lbf | bool | toggle "LBF" |
| fecha_fichaje | date | |
| capitan | bool | |
| cobertura_medica | text | |
| fecha_apto_medico | date | |
| inhabilitado | bool | sanción local |
| motivo_inhabilitacion | text | |
| es_excepcion | bool | excepción por edad (fuera del año de nacimiento) |
| motivo_excepcion | text | visible si el torneo activa "Mostrar excepciones por edad" |
| estado | enum | pendiente / activo (activado por admin) |
| activado_por / activado_at | | auditoría |
| **UNIQUE anti-suplantación** | | **1 jugador_maestro por (categoria)** entre todos sus sub-equipos |

### 1.3. Partido y resultado

**`jornada`** (Fecha): id, categoria_id (o fase_id), numero (11), nombre.

**`partido`**
| campo | tipo | nota |
|-------|------|------|
| id, categoria_id, fase_id, zona_id?, jornada_id | | |
| etapa_label | text | "Cuartos #1 Copa Oro - 1º Grupo-A x 2º Grupo-B" |
| equipo_local_id / equipo_visita_id | uuid | |
| fecha / hora | | |
| sede / cancha / arbitro | text | |
| estado | enum | programado / en_vivo / finalizado / suspendido / walkover |
| goles_local / goles_visita | int | |
| penales (bool), penales_local, penales_visita | | definición |
| es_walkover | bool | |
| comentario | text | |

**`planilla_jugador_partido`** (grilla de carga resumida por jugador)
| campo | tipo | nota |
|-------|------|------|
| id, partido_id, inscripcion_id | | |
| jugo | bool | toggle "J" → alimenta "Juegos" |
| goles | int | "G" |
| amarillas | int | 🟨 |
| rojas | int | 🟥 |
| faltas | int | "F" |
| asistencias | int | **solo vía partido en vivo** |

**`evento_partido`** (timeline en vivo — jugadas del partido)
| campo | tipo | nota |
|-------|------|------|
| id, partido_id, inscripcion_id, equipo_id | | |
| tipo | enum | gol · amarilla · roja · asistencia · penal_definicion · falta |
| periodo | int | 1 / 2 |
| minuto / segundo | int | "2º 23'0"" |

**`multimedia_partido`**: id, partido_id, tipo (foto/video), url, autor.
**`comentario_partido`**: id, partido_id, autor, texto, created_at.

### 1.4. Derivados (calculados, no se almacenan como verdad)

- **Tabla de posiciones** (por zona / general): PJ, PG, PE, PP, GF, GC, DG, PTS (+ `ajuste_puntos`), **Forma** = últimos **5** partidos como secuencia **G-E-P** con color. Orden por `orden_tabla` (efectivo tras override).
- **Goleadores** y **Tarjetas** (por categoría / fase): agregados de `planilla_jugador_partido` / `evento_partido`.
- **Stats de jugador**: Goles, Juegos, Amarillas, Rojas, Faltas, Asistencias.

---

## 2. Roles y accesos

| Rol | Alcance | Acceso | Puede |
|-----|---------|--------|-------|
| **Super-admin de Plataforma** | Global (Liguify) | email + password | Ve y administra todas las marcas; alta de marcas; soporte |
| **Administrador de Marca** | Marca (Tenant) | email + password | Crear torneos, categorías, zonas de *su* marca; configurar reglas; registrar coordinadores. **RLS aísla por marca** |
| **Administrador de Torneo** | Torneo | email + password | Validar apto/docs y **activar** jugadores; equipos/zonas/fixture; cargar resultados; sanciones; premios; ajuste de puntos |
| **Mesa de Control** | Partido | usuario dedicado (solo operación) | Cargar resultado y **partido en vivo**, sin acceso a configuración |
| **Coordinador de club** | Club (multi-torneo) | invitación email (token único) → *The Hub* | Gestionar LBF de sus equipos *(módulo Club — luego)* |
| **Delegado** | Equipo | **código compartido** | Cargar/gestionar plantel de su equipo *(módulo Club — luego)* |
| **Público** | — | sin login | Ver tablas, resultados, programación, estadísticas, fichas |

---

## 3. Procesos (flujos)

**F1 — Alta de competición.** Marca → Torneo (setea reglas) → Categoría (año + modalidad) → Fase → Zona. (FAB: Nuevo torneo / Nueva categoría / Nueva zona.)

**F2 — Inscripción de equipos.** En una Zona: *Nuevo equipo* (club maestro nuevo o existente) o *Importar equipo*. Un club puede tener sub-equipos A/B. Asignar **delegado** → compartir código.

**F3 — Carga de LBF (importación inteligente).**
1. Delegado/Coordinador/Admin agrega jugador digitando **Nro Documento**.
2. Backend busca en `jugador_maestro` por (país-del-documento + número):
   - **existe** → autocompleta foto/nombre y **bloquea edición**.
   - **no existe** → alta con **scan de DNI** (obligatorio si el torneo lo exige).
3. Regla **anti-suplantación**: rechaza si el documento ya está en otro sub-equipo de la **misma categoría**.
4. Ficha queda **pendiente** → el **Admin de Torneo** valida apto médico + docs → **activo**.

**F4 — Generar fixture.** Por Zona: round-robin automático → `jornadas` + `partidos`. Fases de eliminación → llaves (bracket) con `etapa_label`.

**F5 — Día de partido.**
- *Editar información*: sede, cancha, árbitro, hora, estado, comentario.
- *Generar planilla de partido* (acta arbitral, según modalidad).
- *Cargar resultado* (post-partido): marcador + toggle penales + estado + **grilla por jugador** (G/🟨/🟥/F/J) + multimedia.
- *Partido en vivo* (Match Center): eventos con periodo/minuto/segundo, incl. **asistencias** y penales de definición.
- **Cada guardado** recalcula tabla + goleadores + tarjetas + forma y **empuja en tiempo real** al módulo Público.

**F6 — Ajustes y sanciones.** Sumar/quitar puntos (manual), asignar premio, inhabilitar jugador (+ motivo), suspensión por acumulación de amarillas (según config del torneo). Sanciones **locales al torneo** salvo fallo global de oficio.

**F7 — Publicación.** Todo lo anterior se refleja en Público en vivo (WebSocket / Supabase Realtime).

---

## 4. Pantallas

### 4.1. Módulo Público

| # | Pantalla | Contenido |
|---|----------|-----------|
| P1 | **Catálogo de campeonatos** | Buscador + grid de torneos (logo + bandera de país) |
| P2 | **Torneo → Categorías** | Lista "Categoría {año} / {modalidad}" + rango de fechas; tabs: Inicio · Fixture · Tabla · Llaves · Video |
| P3 | **Tabla de posiciones** | Selector de Fase + toggle "por grupo"; cols PTS·PJ·PG·PE·PP·GF·GC·DG; zonas de clasificación con color; Forma |
| P4 | **Fixture / Resultados** | Partidos por Fecha; tarjetas con marcador + estado |
| P5 | **Programación** | Próximos partidos (fecha/hora/sede) |
| P6 | **Detalle de partido** | Tabs Juego / Comentarios / Medios; alineación (titulares+suplentes con iconos ⚽🟨🟥); Jugadas del partido (timeline periodo+minuto); sede con mapa; penales |
| P7 | **Llaves / Bracket** | Eliminación (Copa Oro/Plata) |
| P8 | **Estadísticas** | Goleadores / Tarjetas con filtro por fase |
| P9 | **Sub-equipo** | Tabs Jugadores / Partidos |
| P10 | **Ficha de jugador** | Foto, dorsal, edad, posición; stats Goles·Juegos·🟨·🟥·Faltas·Asistencias |
| P11 | **Video** | Highlights / streaming |

### 4.2. Módulo Administrador

| # | Pantalla | Contenido / acciones |
|---|----------|----------------------|
| A1 | **Panel / navegación** | Árbol Marca→Torneo→Categoría→Zona; FAB: Nuevo torneo/categoría/zona |
| A2 | **Crear/Editar torneo-categoría** | Bloque completo de reglas (§1.2) |
| A3 | **Equipos por zona** | Lista por zona con check DELEGADO; menú zona: Editar / Nuevo equipo / Importar / Generar fixture / Mostrar-ocultar |
| A4 | **Alta/Editar equipo** | Escudo, foto, nombre, sede; plantel con toggle LBF; menú: Reemplazar (nuevo/existente), Sumar/Quitar puntos, Asignar premio, Reasignar/Quitar delegado, Compartir código, Borrar jugadores |
| A5 | **Ficha de jugador** | Documento (llave) + scan, datos, médico, capitán, inhabilitado + motivo |
| A6 | **Fixture** | Partidos por Fecha; menú partido: Editar info / Cargar planilla / Cargar resultado / Mover a otra fecha / Generar planilla / Eliminar |
| A7 | **Editar información de partido** | Equipos, zona, fecha, hora, sede, cancha, árbitro, estado, comentario |
| A8 | **Cargar resultado** | Marcador + toggle penales + estado + grilla por jugador (G/🟨/🟥/F/J) + tab Multimedia |
| A9 | **Partido en vivo (Match Center)** | Eventos con minuto/segundo, asistencias, penales; push realtime |
| A10 | **Generar planilla / acta** | PDF imprimible por modalidad |
| A11 | **Accesos** | Registrar coordinador (email) · compartir código de delegado |

---

## 5. Data de ejemplo

Dos torneos: uno nacional (INTI CUP, con sub-equipos A/B) y uno internacional (AMÉRICA ISOCUP, para el caso multi-país).

```json
{
  "marcas": [
    { "id": "m1", "nombre": "INTI CUP", "pais": "PE" },
    { "id": "m2", "nombre": "AMÉRICA ISOCUP", "pais": "PE" }
  ],
  "torneos": [
    { "id": "t1", "marca_id": "m1", "nombre": "INTI CUP ORO", "anio_temporada": 2026, "tipo_default": "F7",
      "puntos": [3,1,0], "walkover": { "sumar": false, "goles_ganador": 3, "puntos_perdedor": 0 },
      "orden_tabla": ["PUNTOS","DIF_GOL","GF","GC"], "lbf_max": 30, "scan_dni_obligatorio": false,
      "amarillas_suspension": null, "permitir_delegados": true },
    { "id": "t2", "marca_id": "m2", "nombre": "AMÉRICA ISOCUP", "anio_temporada": 2026, "tipo_default": "F9" }
  ],
  "categorias": [
    { "id": "c1", "torneo_id": "t1", "anio": 2016, "modalidad": "F7", "display": "Categoría 2016 / F7",
      "inicio": "2026-07-13", "fin": "2026-07-17" },
    { "id": "c2", "torneo_id": "t2", "anio": 2014, "modalidad": "F9", "display": "Categoría 2014 / F9" }
  ],
  "fases": [
    { "id": "f1", "categoria_id": "c1", "nombre": "Fase de Grupos", "tipo": "grupos", "orden": 1 },
    { "id": "f2", "categoria_id": "c1", "nombre": "Copa Oro", "tipo": "eliminacion", "orden": 2 }
  ],
  "zonas": [
    { "id": "z1", "fase_id": "f1", "nombre": "A", "visible": true },
    { "id": "z2", "fase_id": "f1", "nombre": "B", "visible": true }
  ],
  "clubes_maestros": [
    { "id": "cm1", "nombre": "ACAR", "pais": "PE" },
    { "id": "cm2", "nombre": "Alianza Lima Surquillo", "pais": "PE" },
    { "id": "cm3", "nombre": "Los Tigres del Callao", "pais": "PE" },
    { "id": "cm4", "nombre": "Sport Boys Sor Ana", "pais": "PE" }
  ],
  "equipos": [
    { "id": "e1", "categoria_id": "c1", "club_maestro_id": "cm1", "nombre": "ACAR", "sufijo": null, "zona": "z1", "color": "#1e40af", "delegado_codigo": "ACAR-7X2", "ajuste_puntos": 0 },
    { "id": "e2", "categoria_id": "c1", "club_maestro_id": "cm2", "nombre": "Alianza Lima Surquillo", "zona": "z1", "color": "#dc2626" },
    { "id": "e3", "categoria_id": "c1", "club_maestro_id": "cm3", "nombre": "Los Tigres del Callao A", "sufijo": "A", "zona": "z2", "color": "#16a34a" },
    { "id": "e4", "categoria_id": "c1", "club_maestro_id": "cm3", "nombre": "Los Tigres del Callao B", "sufijo": "B", "zona": "z2", "color": "#f59e0b" },
    { "id": "e5", "categoria_id": "c1", "club_maestro_id": "cm4", "nombre": "Sport Boys Sor Ana", "zona": "z1", "color": "#7c3aed" }
  ],
  "jugadores_maestros": [
    { "id": "j1", "tipo_doc": "DNI", "pais_doc": "PE", "nro_doc": "78434568", "nombre": "Aymar Tantalean Villacrez", "nac": "2014-01-13", "genero": "M", "verificado": true },
    { "id": "j2", "tipo_doc": "DNI", "pais_doc": "PE", "nro_doc": "80123455", "nombre": "Gael Llallahui Diaz", "nac": "2016-05-02", "genero": "M", "verificado": true }
  ],
  "inscripciones_lbf": [
    { "id": "i1", "equipo_id": "e1", "jugador_id": "j2", "dorsal": 9, "en_lbf": true, "capitan": true, "estado": "activo", "fecha_apto_medico": "2026-07-01" },
    { "id": "i2", "equipo_id": "e2", "jugador_id": "j1", "dorsal": 5, "en_lbf": true, "estado": "activo" }
  ],
  "jornadas": [
    { "id": "jo11", "categoria_id": "c1", "numero": 11, "nombre": "Fecha 11" }
  ],
  "partidos": [
    { "id": "p1", "categoria_id": "c1", "fase_id": "f1", "zona_id": "z1", "jornada_id": "jo11",
      "local": "e1", "visita": "e2", "fecha": "2026-07-15", "hora": "19:00",
      "sede": "Arena 7 - Campo Azul 2", "arbitro": null, "estado": "finalizado",
      "goles_local": 2, "goles_visita": 1, "penales": false }
  ],
  "planilla_jugador_partido": [
    { "partido_id": "p1", "inscripcion_id": "i1", "jugo": true, "goles": 1, "amarillas": 0, "rojas": 0, "faltas": 1, "asistencias": 0 }
  ]
}
```

---

## 6. Decisiones resueltas (2026-07-19)

1. **D1 — Overrides de categoría:** **override total**. La categoría hereda del torneo y puede sobreescribir cualquier regla (§1.2).
2. **Administrador General:** **dos niveles** → Super-admin de Plataforma (Liguify, global) + Administrador de Marca (tenant, RLS aísla por marca).
3. **Forma:** últimos **5** partidos, mostrada como secuencia **G-E-P** con color en el público.
4. **Mesa de Control:** **rol/usuario propio dedicado**, solo para cargar resultados y partido en vivo.
5. **Excepciones por edad:** flag `es_excepcion` + `motivo_excepcion` en la inscripción LBF; etiqueta visible según config del torneo.
6. **Premios:** **catálogo** (Campeón, Subcampeón, Fair Play, Goleador, Valla menos vencida) **+ texto libre** (`premio_tipo` / `premio_libre`).
7. **URLs de marca (2026-07-19):** cada marca tiene **subdominio compartible** — `inticup.liguify.com`, `novacup.liguify.com` — implementado con wildcard `*.liguify.com` (automático al crear la marca, sin configuración manual). Al lanzamiento el subdominio hace **301 → `liguify.com/<marca>`** (canónico por ruta: el link es colgable en redes/páginas de la marca y el SEO se consolida en el dominio raíz). Upgrades premium por tenant: servir directo en el subdominio o dominio propio white-label (`inticup.com`). Subdominios reservados: `admin`, `erp`, `academias`, `www`, `api`. Requisito derivado: la marca necesita un campo **`slug`** único (inticup, novacup, idvlima) que alimenta ruta y subdominio.
8. **Torneo opcional (2026-07-19):** una marca puede tener categorías "directas" sin torneo visible (caso IDV LIMA). Se implementa con el patrón **torneo implícito**: en BD toda categoría SIEMPRE pertenece a un torneo (jerarquía estricta, sin FK nullable), pero el torneo puede ser `es_implicito=true` (auto-creado con el nombre de la marca). La UI y las URLs públicas ocultan ese nivel (`liguify.com/idvlima/2019-f7` sin segmento de torneo); las reglas configurables viven en el torneo implícito. Si la marca luego crea torneos reales, el implícito se renombra y se hace visible.

---

## 7. Integración con Liguify Academias (definida 2026-07-19)

Este sistema se integra con **Liguify Academias** (repo `proyecto-academias`, mismo proyecto Supabase, esquema Postgres `academias`).

### 7.1 Identidad unificada (SSO por email)
- **El correo del club es el login unificado**: la misma cuenta (email) sirve para entrar a Liguify Torneos y a Liguify Academias.
- Implementación natural: ambos sistemas comparten el MISMO proyecto Supabase → un solo `auth.users`. El email del coordinador/club se registra una vez; cada app resuelve sus permisos por separado (Torneos: acceso a sub-equipos vía invitación/código; Academias: tenant de su academia).

### 7.2 Contrato de importación de jugadores (Academias → Torneos)
Los clubes podrán importar a sus alumnos/jugadores con estos campos:

| Campo Academias | Campo Torneos (jugador maestro) |
|---|---|
| nombres | nombres (separado de apellidos — NO un solo campo "nombre completo") |
| apellidos | apellidos |
| nro_documento (DNI) | documento → **llave única global país+documento**; si ya existe en la maestra, se reutiliza (no se duplica) |
| fecha_nacimiento | fecha_nacimiento (date) → determina categoría; si no coincide con el año, entra como excepción por edad |
| foto del alumno | foto del jugador |
| fotos del DNI | scans DNI frente/reverso — al venir de Academias la identidad ya está verificada (no se re-exige scan) |

### 7.3 Consideraciones de diseño para que la integración sea sencilla
1. **Jugador maestro con `nombres` y `apellidos` separados** (igual que Academias) — nunca un solo campo concatenado.
2. La llave país+documento es el **puente natural**: importar = buscar/crear en la maestra global por documento.
3. Jugador importado llega **verificado SOLO si Academias aporta el scan de DNI** (C3, 2026-07-19); sin scan → entra como **pendiente de documentación** (completa el scan en Competencias). En ambos casos queda **PENDIENTE** de validación del admin del torneo (apto médico).
3b. **Precedencia de la base maestra** (C3): si el DNI ya existe en Liguify, se usan los datos ya registrados en la maestra y se **ignoran los de Academias** — la maestra global nunca se sobreescribe desde una importación.
4. La validación de edad aplica igual: año ≠ categoría → `es_excepcion`.
5. Implementado en mockup-admin.html: botón "🎓 Importar desde Liguify Academias" en el modal Agregar jugador/a (multi-select del pool de alumnos del club, con badge 🎓 Academias en el plantel).

---

## 8. Revisión crítica — errores y vacíos detectados (2026-07-19)

Análisis general de: creación de torneos, equipos y jugadores; integración con Academias; programación de partidos.

### 🔴 Críticos
| # | Área | Problema | Acción propuesta |
|---|------|----------|------------------|
| C1 | Clubes | ~~Gobernanza del club maestro compartido~~ **RESUELTO (2026-07-19)**: el club es **único POR MARCA**, no global. Cada marca tiene su cartera de clubes independiente (protección de clientes); el admin de la marca edita sus clubes sin afectar a otras marcas. El jugador maestro sigue siendo global (anti-suplantación) | Modelado en §1.1: `club.marca_id NOT NULL`, UNIQUE(marca_id, nombre), RLS por marca |
| C2 | Clubes | ~~Duplicados por matching débil~~ **RESUELTO (2026-07-19)**: NO se usa RUC/llave fuerte ni merge automático — muchos clubes son informales y no tienen RUC. **El control de duplicados es responsabilidad manual del administrador de la marca** (acotado por C1: cada marca gestiona solo su propia cartera). El sistema ayuda de forma pasiva: al crear un equipo se muestra la lista de clubes existentes de la marca primero, y se rechaza el nombre exacto duplicado. RUC/ID fiscal queda como campo opcional informativo | Sin acción de desarrollo adicional |
| C3 | Academias | ~~Import otorga verificado sin scan~~ **RESUELTO (2026-07-19)**: (a) sin scan de DNI en Academias → el jugador entra como **PENDIENTE DE DOCUMENTACIÓN** (verificado=false, debe completar el scan en Competencias); (b) **precedencia de la base maestra**: si el DNI ya existe en Liguify, se usan los **datos ya registrados** en la maestra y NO se importan los de Academias (sin sobreescritura). Implementado y verificado en mockup-admin `doImportAcademia()` | Cerrado |
| C4 | Torneos | ~~Retiro de equipo a mitad de torneo sin regla~~ **RESUELTO (2026-07-19)**: los retiros se resuelven **MANUALMENTE — el administrador toma las decisiones** caso por caso, usando las herramientas del sistema: inactivar equipo ("quitar del torneo", nunca se borra), marcar partidos futuros como WALKOVER con el marcador que corresponda, y sumar/quitar puntos si aplica. No hay automatismo de retiro | Parte técnica cerrada: el motor de standings ya computa el estado `walkover` con su marcador (implementado y verificado en mockup-admin `calcTablaZona`); en backend, los puntos del WO respetan la config del torneo (`sumar_puntos_walkover`, `goles_ganado_walkover`, `puntos_perdido_walkover`) |
| C5 | Reglas | ~~Cambiar puntajes con resultados cargados~~ **RESUELTO (2026-07-19)**: **SÍ se permite** — el cambio recalcula la tabla **retroactivamente** para todo el torneo, previa **advertencia explícita** con confirmación (muestra valores anteriores → nuevos y cuántos resultados serán reasignados; cancelar restaura la config previa). Implementado y verificado en mockup-admin `guardarConfig()`. En backend: sumar entrada de **auditoría** (quién cambió puntajes, cuándo, valores antes/después) | Cerrado |

### 🟡 Medios
| # | Área | Problema |
|---|------|----------|
| M1 | Academias | Falta tabla puente club↔academia con autorización real (el email compartido no basta) |
| M2 | LBF | Excepciones por edad sin límites configurables (rango de años, máx. por equipo) |
| M3 | LBF | Refuerzos entre categorías del mismo torneo: permitido implícitamente, debe ser regla explícita/configurable |
| M4 | LBF | Transferencias/pases de jugador durante el torneo: sin definir (¿baja+alta? ¿stats viajan?) |
| M5 | Fixture | Generador: falta intervalo entre fechas (hoy días consecutivos), ida y vuelta, multi-cancha, validación de choques cancha/hora/árbitro |
| M6 | Fixture | Bracket de llaves manual — automatizar 1A-2B/1B-2A desde tabla + criterio de desempate de último recurso (sorteo/fair play) |
| M7 | Disciplina | Motor de suspensiones no diseñado (conteo de amarillas → inhabilitación auto; roja → N fechas default) |
| M8 | Fixture | Alta de equipo después de generar fixture: sin flujo (regenerar borra resultados) |
| M9 | Jugadores | Corrección de datos de jugador verificado (error de tipeo): falta flujo de solicitud al super-admin |

### 🟢 Menores
dorsal único por equipo (validar) · `torneo.slug` para URLs · timezone por torneo (multi-país) · vigencia del apto médico · consentimiento del tutor para fotos/DNI de menores entre sistemas (Ley 29733 PE) · partido suspendido con goles parciales (conservar eventos al reanudar) · auditoría created_by/updated_by en resultados.

---

## 9. Segunda revisión crítica — incoherencias entre decisiones (2026-07-19)

### 🔴 Críticas
| # | Incoherencia | Detalle | Propuesta |
|---|--------------|---------|-----------|
| I1 | ~~Identidad de equipo entre categorías~~ **RESUELTO (2026-07-19)**: NO se crea entidad `escuadra`. La Tabla General es un **caso especial** (no todos los torneos la tienen) y en esos torneos normalmente no hay duplicidad A/B. Cada club y cada equipo mantienen su propio id | Llave técnica del acumulado: **(club_id, nombre_equipo normalizado)** — lower/trim/espacios colapsados, para que variaciones de tipeo no partan el acumulado. Nombrar consistente entre categorías = responsabilidad del admin (coherente con C2) |
| I2 | ~~Override de puntajes vs Tabla General~~ **RESUELTO (2026-07-19)**: **se permite** el override de puntajes por categoría aunque la Tabla General esté activa — **bajo responsabilidad del admin** (coherente con C2/C4/I1: el admin controla). Recomendable un aviso informativo en la UI al overridear puntajes con tabla general activa, sin bloquear | Cerrado |
| I3 | ~~Fuga de datos de menores cross-marca~~ **RESUELTO (2026-07-19)**: el autocompletado por DNI muestra **datos censurados** — nombre "S******* R**** P*******", año de nacimiento sin día/mes, sin foto — con nota de privacidad de menores. Los **datos completos se revelan únicamente al confirmar la inscripción** a la LBF. Implementado y verificado en mockup-admin `buscarDoc()`. El caso "bloqueado por anti-suplantación en la propia categoría" sí muestra el nombre (es dato que la propia marca ya tiene) | Cerrado |
| I4 | ~~Código de delegado débil~~ **APLICADO AL MODELO**: el código de delegado es de **UN SOLO USO** para vincular cuenta — el delegado lo canjea registrando su email/contraseña; a partir de ahí el acceso es nominal (usuario identificable) y revocable. El código canjeado se invalida; reasignar delegado genera código nuevo | Modelado en `equipo.delegado_codigo` (§1.2) |
| I5 | ~~Sanción global sin modelar~~ **APLICADO AL MODELO**: tabla `sancion_global` agregada en §1.1 (jugador_maestro_id, motivo, vigencia desde/hasta, emitida_por super-admin) — bloquea toda inscripción/alineación mientras esté vigente | Cerrado |

### 🟡 Medias
| # | Problema | Propuesta |
|---|----------|-----------|
| I6 | ~~Membresías/roles sin modelar~~ **APLICADO AL MODELO**: tablas `usuario_marca` (rol admin_marca/mesa_control) y `usuario_club` (rol coordinador/delegado, con equipo_id opcional) agregadas en §1.1 — base de The Hub | Cerrado |
| I7 | ~~lbf_max_jugadores ambiguo~~ **RESUELTO (2026-07-19)**: el tope es **POR EQUIPO** — cada equipo de la categoría puede tener hasta N jugadores en su LBF. El **valor N se configura por categoría** (hereda del torneo, override por categoría vía D1): la 2017/F7 puede permitir 30 y la 2015/F9 permitir 25. Validación backend: `count(inscripcion_lbf where equipo_id=X and en_lbf=true) <= config_efectiva.lbf_max` | Cerrado |
| I8 | ~~Override demasiado amplio~~ **APLICADO**: campos clasificados en heredables vs solo-torneo (refinamiento bajo D1 en §1.2) | Cerrado |
| I9 | ~~Anti-suplantación declarativa~~ **APLICADO**: `inscripcion_lbf.categoria_id` desnormalizado + `UNIQUE(jugador_maestro_id, categoria_id)` (§1.2) | Cerrado |
| I10 | ~~Tabla en vivo~~ **RESUELTO (2026-07-19)**: los puntos entran a la tabla **SOLO al finalizar el encuentro** (o al marcarse walkover). El partido en vivo actualiza su marcador/cronología en tiempo real en el módulo público, pero NO altera la tabla de posiciones hasta el estado FINALIZADO. Coincide con lo implementado en ambos mockups | Cerrado |
| I11 | ~~Tabla General con torneo implícito~~ **RESUELTO por diseño**: cuando la marca solo tiene torneo implícito, la **página de la marca ES la página del torneo implícito** (misma vista, sin segmento de torneo en la URL) — la Tabla General y las categorías viven ahí | Cerrado |

### 🟢 Menores
Zona/fecha oculta: resultados computan igual (solo visual — confirmar) · backend debe validar anti-suplantación también en imports de Academias contra otros equipos de la categoría · interacción `fecha_limite_carga_equipo` vs `permitir_modificacion_equipo` sin definir · `categoria.fecha_inicio/fin` vs fechas de jornadas (derivable).

---

## 10. Tercera revisión crítica — bugs verificados y huecos restantes (2026-07-19)

### ✅ Bugs CONFIRMADOS en vivo y CORREGIDOS en mockup-admin (mismo día)
| # | Bug (verificado antes de corregir) | Corrección aplicada |
|---|-----|-----|
| B1 | Importar de la maestra NO marcaba excepción por edad (alta manual sí lo hacía) | `importarJugador` calcula `excepcion` y avisa |
| B2 | **Anti-suplantación estático**: tras inscribir un DNI, se podía inscribir en OTRO equipo de la misma categoría (la regla solo miraba datos hardcodeados) | `inscritoEnCategoria(doc)` dinámico: busca en todos los planteles antes que en la maestra |
| B3 | El mismo DNI podía agregarse DOS veces al MISMO equipo | Cubierto por la misma validación dinámica |
| B4 | Se podía crear un partido en Zona A entre dos equipos de Zona B | `crearPartido` valida que ambos equipos pertenezcan a la zona seleccionada |
| B5 | Jugadores **INHABILITADOS** aparecían en la grilla de carga de resultados (podían "anotar goles") | Grilla excluye inhabilitados con nota "N excluidos"; solo alineables los en_lbf y no inhabilitados |
| B6 | El tope LBF (30) no se validaba en ningún alta (manual, maestra, Academias) | Validado en los 3 flujos (en Academias: plantel + seleccionados ≤ 30) |

### 🔴 Huecos estructurales críticos (requieren decisión)
| # | Hueco | Detalle |
|---|-------|---------|
| T1 | ~~Criterios de desempate huérfanos~~ **RESUELTO (2026-07-19)**: NO hay campo separado — `orden_tabla` es de **doble propósito**: define columnas mostradas Y precedencia de desempate en esa misma secuencia (ver §1.2). El motor de standings debe ordenar dinámicamente según la secuencia configurada (no hardcodear PTS→DG→GF) |
| T2 | ~~Cascada resultado↔eventos↔stats~~ **RESUELTO (2026-07-19)**: **el resultado cargado/modificado por el admin es la FUENTE PRINCIPAL**. Al modificar o borrar un resultado, los **eventos del Match Center en vivo de ese partido SE BORRAN** (cronología, goles con minuto, asistencias) — nunca quedan goles fantasma inflando goleadores. Las stats de jugador quedan respaldadas por la planilla del resultado (grilla G/🟨/🟥/F/J). Implementado y verificado en mockup-admin `limpiarEnVivo()` | Cerrado |
| T3 | ~~Privacidad del público (menores)~~ **RESUELTO (2026-07-19)**: la ficha pública muestra **nombre + solo el AÑO de nacimiento** (nunca día/mes; la edad sí). Implementado y verificado en mockup-publico. **En análisis (idea de Luis): foto en BLANCO Y NEGRO por defecto — pasa a COLOR solo con la aprobación explícita del padre/tutor** para el uso de datos (el consentimiento se vuelve visible e incentivado). Campo derivado: `jugador_maestro.consentimiento_imagen` (bool + fecha + otorgado_por) | Año-solo cerrado; foto B/N pendiente de confirmación |

### 🟡 Medios
| # | Hueco |
|---|-------|
| T4 | **Jornada "computa en tablas"**: la referencia (Futplay) tenía "La fecha impacta en: Posiciones / Valla menos vencida" — concepto perdido en nuestro modelo. Agregar `jornada.computa_en_tabla` (fechas amistosas/exhibición que no suman) |
| T5 | **Estados del torneo sin transiciones**: ¿un torneo FINALIZADO sigue aceptando cambios de resultados (con recálculo retroactivo)? Definir bloqueo o permiso con advertencia (coherente con C5) |
| T6 | **Fecha límite de carga**: ¿`fecha_limite_carga_equipo` aplica también al alta de jugadores o solo de equipos? Interacción con `permitir_modificacion_equipo` y `cargar_lbf` sin definir |
| T7 | **RLS/vistas públicas**: separar datos públicos (nombres, stats) de sensibles (scans DNI, contactos, emails) — el rol anon SOLO lee vistas públicas; storage de scans en bucket PRIVADO con URLs firmadas |
| T8 | **Concurrencia**: dos sesiones sobre el mismo partido (mesa de control registrando + admin editando/borrando) — resolver con versionado optimista/realtime en backend |
| T9 | **Multi-deporte hardcodeado**: modalidad (F7/F9/F11) y eventos (gol/amarilla/roja) son fútbol-only, pero la visión es multi-deporte (vóley, pádel). Diseñar `deporte` en marca/torneo + modalidad como catálogo por deporte + tipos de evento por deporte, para no bloquear la expansión |

### 🟢 Menores
Regenerar "todas las zonas" borra también resultados de zonas con juego (granularidad del reemplazo) · mockup público desactualizado vs decisiones recientes (orden_tabla dinámico, censura, tabla general por club_id+nombre) · moderación de multimedia subida por mesa de control · scope del rol mesa_control (¿toda la marca o por torneo?).

---

## 11. Acreditación de jugadores en partido — por nivel de membresía (definido 2026-07-19)

Verificación de identidad EN CANCHA al registrar jugadores en un partido (check-in de alineación). Los métodos disponibles dependen de la **membresía de la marca** — primer concepto de planes del sistema.

| Membresía | Método | Detalle |
|-----------|--------|---------|
| Básico | **Scan de DNI físico** | La mesa escanea/digita el DNI → ficha verificada con foto en pantalla → comparación visual. Disponible para todos |
| Intermedio | **Carnet digital con QR** | Carnet por jugador (foto, equipo, categoría, marca) en celular o impreso. QR **firmado con expiración/rotación** (anti-captura). Escaneo → ficha en segundos |
| Premium | **Tarjeta física NFC** | Tarjeta impresa con chip NFC vinculada a la inscripción; tap en el móvil de la mesa (Web NFC). **Ingreso adicional: venta de tarjetas por jugador** |

### Modelo derivado
- `marca.membresia` (enum: basico / intermedio / premium) — gobierna métodos de acreditación disponibles; conecta con los otros premium ya definidos (subdominio directo, white-label, dominio propio).
- `acreditacion_partido`: partido_id, inscripcion_id, metodo (dni_scan | qr | nfc), verificado_por (usuario mesa), timestamp — **evidencia auditable** de que la alineación fue verificada.
- Carnet QR: token firmado (corta vigencia, regenerable) asociado a inscripcion_lbf — no un QR estático copiable.
- NFC: uid del chip vinculado a la inscripción al emitir la tarjeta.
- El check-in alimenta la columna J (jugó) de la planilla del partido.

### Roadmap de mejoras propuesto (2026-07-19, priorizado)
1. ⭐ Carnet QR + acreditación por membresía (esta sección)
2. ⭐ Compartibles automáticos para redes — **CONFIRMADO E IMPLEMENTADO EN MOCKUP (Luis, 2026-07-19)**. Pantalla "📣 Compartibles" en mockup-admin: genera imágenes REALES 1080×1080 en canvas con 3 plantillas (🏆 Marcador final con escudos/penales/etapa · 📊 Tabla de posiciones por zona con datos vivos · ⚽ Goleador de la fecha con avatar B/N si no hay consentimiento T3), branding de la marca (logo, color, nombre) + marca de agua "⚡ Powered by LIGUIFY · liguify.com/<slug>", descarga PNG y compartir por WhatsApp (wa.me con texto + link del torneo). En producción: generación automática al FINALIZAR el partido/fecha, notificada al admin lista para publicar
3. ⭐ Modo offline de Mesa de Control — **CONFIRMADO COMO REQUISITO (Luis, 2026-07-19: "esto es necesario")**. Demostrado en mockup-admin (simulador de señal + cola local + sync). Diseño técnico:
   - **Escritura local primero**: cada evento se guarda en el dispositivo (IndexedDB) ANTES de enviarse; la UI actualiza al instante (optimista). El Match Center nunca se bloquea por falta de señal.
   - **Idempotencia**: cada evento lleva `uuid` generado en el cliente + timestamp + secuencia local → el servidor hace upsert por uuid (los reintentos nunca duplican goles).
   - **Sincronización automática**: al detectar conectividad (navigator.onLine + reintentos con backoff), la cola se envía en orden; los eventos pasan de "⏳ cola local" a confirmados y se publican al módulo público.
   - **Conflicto con T2**: si mientras la mesa estaba offline el admin cargó/modificó el resultado del partido (el resultado del admin es la fuente principal), la sync de esa cola se RECHAZA con aviso a la mesa — no se resucitan eventos de un partido ya consolidado.
   - Implementación natural como PWA (conecta con roadmap #9).
4. Suspensiones automáticas (M7, subida de prioridad)
5. Notificaciones WhatsApp (programación, resultados, suspensiones)
6. OCR del DNI en el alta de jugadores
7. Import masivo por Excel (pasa por importación inteligente en lote)
8. Wizard de creación de torneo
9. PWA instalable con push web
10. Modo pantalla/TV para la sede

---

## 12. Integración ERP ↔ Competencias — importación de clubes por categoría (análisis 2026-07-29)

**Objetivo (Luis):** el ERP ya tiene clubes inscritos a torneos (con categoría y modalidad); Competencias debe poder **importar esos clubes a un torneo/categoría** sin duplicar clubes en la base de datos.

### 12.1 Los dos modelos (mismo proyecto Supabase, esquemas distintos)

| Concepto | ERP (`public`, ids bigint) | Competencias (`competencias`, ids uuid) |
|---|---|---|
| Tenant | `organizaciones` | `marca` |
| Club | `clubes` (nombre, delegado, teléfono, provincia, org_id) | `club` (marca_id, nombre, escudo, UNIQUE marca+nombre) |
| Torneo | `torneos` (estado activo/en_ejecucion/cerrado) | `torneo` (slug, reglas) |
| Categoría | `categorias` (nombre libre p.ej. "2015") + `torneo_categorias` (torneo+cat+**modalidad F7**) | `categoria` (**anio_nacimiento + modalidad**, UNIQUE) |
| Inscripción del club | **`equipos`** (torneo_id, club_id, cat_id, modalidad, nombre "Cara A/B", estado, montos) | **`equipo`** (categoria_id, club_id, nombre libre, estado) |

**Hallazgo clave:** `public.equipos` ≈ `competencias.equipo` — la inscripción ERP contiene exactamente lo necesario para crear el equipo deportivo (club + categoría + modalidad + sub-nombre → nombre libre/sufijo).

### 12.2 Diseño del puente (sin duplicar clubes)

**Columnas de vínculo (Fase 1 — DDL):**
```sql
alter table competencias.marca  add column erp_org_id  bigint unique;             -- marca ↔ organización
alter table competencias.club   add column erp_club_id bigint unique;             -- club ↔ club ERP (1:1)
alter table competencias.equipo add column erp_equipo_id bigint unique;           -- idempotencia del import
-- (FK cross-schema opcional: references public.clubes(id) on delete set null — mismo Postgres, es válido)
```

**Resolución de club SIN duplicar (algoritmo por cada club ERP a importar):**
1. ¿Existe `competencias.club` con `erp_club_id = X`? → **reusar** (vínculo ya hecho).
2. Si no: ¿existe club de la marca con **nombre normalizado igual** (lower/trim)? → **ADOPTAR**: set `erp_club_id = X` sobre el existente (es el mismo club creado a mano antes — así se cura el duplicado en vez de crearlo). Confirmación del admin en UI.
3. Si no: **crear** `club {marca_id, nombre, erp_club_id}` (+ delegado/teléfono como contacto).

**Mapeo de categoría:** `public.categorias.nombre` es texto libre → si parsea como año (regex `^(19|20)\d{2}$`) se sugiere el match con `anio_nacimiento`; la modalidad viene de `equipos.modalidad`/`torneo_categorias.modalidad`. La UI de import muestra el pareo sugerido ERP↔Competencias y el admin lo confirma/ajusta (mapping manual como fallback — los nombres de categoría del ERP son libres por org).

**Flujo de importación (Fase 2 — UI en Competencias, categoría → "⬇ IMPORTAR CLUBES DESDE ERP"):**
1. Requiere `marca.erp_org_id` vinculado (pantalla Editar Marca: "Vincular con mi organización del ERP").
2. Selector de torneo ERP (de esa org) → lista sus `equipos` (inscripciones) con club/categoría/modalidad/estado, pre-filtrados por el mapeo de la categoría destino.
3. Multi-select → por cada uno: resolver club (12.2) + crear `competencias.equipo {categoria_id, club_id, nombre: equipos.nombre||null, erp_equipo_id}` — **idempotente** por `erp_equipo_id unique` (re-importar no duplica).
4. Resumen: N clubes creados · N adoptados · N reusados · N equipos creados · N omitidos.

**Seguridad/RLS:** implementar como función `security definer` — `competencias.importar_clubes_erp(p_categoria uuid, p_erp_torneo bigint, ...)`: valida `es_admin_marca` **y** que `marca.erp_org_id` = org del torneo ERP; solo entonces lee `public.*` (no se otorgan grants directos de ERP a usuarios de Competencias; la cartera de otras orgs queda inaccesible).

### 12.3 Casos borde
- `equipos.nombre` "Cara A"/"Cara B" del ERP → nombre libre del equipo Competencias (patrón sufijo ya soportado).
- `equipos.estado='inactivo'` en ERP → no se ofrece en el import (o se ofrece marcado).
- `equipos.invitado` → informativo (sin efecto deportivo).
- Ids bigint (ERP) vs uuid (Competencias) → por eso columnas de vínculo dedicadas, nunca compartir PKs.
- Un mismo club ERP en 2 categorías del mismo torneo ERP → 2 equipos Competencias, 1 solo club (correcto).
- Torneo ERP `cerrado` → igual importable (caso real: la parte financiera se cierra antes de armar el deportivo del siguiente).

### 12.4 Bonus que habilita el vínculo (futuro)
- **Semáforo de pagos en Competencias**: con `club.erp_club_id`, el admin deportivo puede ver "al día / deudor" desde la cuenta corriente del ERP (join por vínculo) — p.ej. bloquear acreditación o programación de clubes morosos (configurable).
- Inverso: el ERP puede mostrar posición/resultados del club (dato deportivo) en su estado de cuenta.

### 12.5 Fases propuestas
1. **F1 (DDL, 15 min):** columnas de vínculo + función `importar_clubes_erp` security definer.
2. **F2 (UI):** vincular marca↔org en Editar Marca + modal de importación en la categoría (idéntico patrón al "Importar plantel" ya construido).
3. **F3 (valor):** semáforo de pagos ERP en la vista de equipos/acreditación.
