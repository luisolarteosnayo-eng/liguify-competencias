-- La Edge Function enviar-sms-padre llama a crear_codigo_sms con el rol
-- service_role, que no tenia USAGE sobre el esquema competencias (error 42501).
grant usage on schema competencias to service_role;
grant execute on function competencias.crear_codigo_sms(uuid, text) to service_role;
grant execute on function competencias.aviso_nuevo_padre(uuid, uuid)  to service_role;
notify pgrst, 'reload schema';
select has_schema_privilege('service_role','competencias','usage') as service_role_ok;
