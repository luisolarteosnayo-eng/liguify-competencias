# Liguify Competencias

Producto principal del portafolio **Liguify**: gestión deportiva de torneos de fútbol formativo y competitivo (SaaS multi-tenant, API-first sobre Supabase).

## Apps (sin build — HTML + Tailwind CDN + supabase-js)
- `index.html` — **Módulo Público**: catálogo de marcas → torneos → categorías → tablas/fixture/planteles, en tiempo real (Realtime). Solo lectura anónima.
- `admin.html` — **Panel Administrador**: login por roles (RLS), categorías, equipos/clubes, LBF con búsqueda censurada y anti-suplantación, resultados.
- `poc-sync.html` — herramienta QA de verificación de arquitectura.
- `mockup*.html` — especificación viviente de pantallas pendientes de migrar.

## Backend
- `supabase/schema.sql` — esquema completo `competencias` (20 tablas, vistas públicas, funciones, triggers, RLS multi-tenant por marca).
- `ANALISIS_PUBLICO_ADMIN.md` — análisis funcional, modelo de dominio y decisiones.

Módulos complementarios del portafolio: [Liguify ERP](https://erp.liguify.com) (financiero) · [Liguify Academias](https://liguify-academias.vercel.app).
