# Edge Functions · Liguify Competencias

## enviar-aviso-programacion

Envía por email a los clubes de un torneo el aviso de que la programación de una
fecha ya está disponible. Cada club recibe **solo sus partidos** (hora, rival,
cancha) y un recordatorio si su lista de buena fe está vacía o con pendientes.

La usa el botón **📧 AVISAR** de la pantalla del torneo en el admin.

### Requisitos previos

1. `supabase/patch_aviso_programacion.sql` ya ejecutado (tabla `aviso_programacion`
   y función `destinatarios_programacion`).
2. Dominio `liguify.com` verificado en Resend (ya lo está: se usa para los correos
   de invitación). El remitente es `no-reply@liguify.com`.

### Despliegue (una sola vez)

```bash
# 1) API key de Resend como secreto del proyecto
supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxxxxxx

# 2) desplegar la función
supabase functions deploy enviar-aviso-programacion
```

También puede hacerse desde el panel de Supabase → **Edge Functions** (crear la
función, pegar `index.ts`) y **Edge Functions → Secrets** para la API key.

### Cómo probar

En el admin: torneo → **📧 AVISAR** → elegir la fecha → escribir un correo propio
en "probar con un correo tuyo" → **✉️ ENVIAR PRUEBA**. Llega un solo correo con
los datos del primer club, sin registrar el envío ni avisar a nadie más.

### Seguridad

- La función no decide quién puede enviar: llama a `destinatarios_programacion`
  con el **token del usuario**, y esa función solo responde al staff de la marca
  dueña del torneo. Un delegado o un anónimo reciben error.
- El registro en `aviso_programacion` también se hace con el token del usuario,
  protegido por RLS.
- `RESEND_API_KEY` vive solo en los secretos del proyecto, nunca en el frontend.
