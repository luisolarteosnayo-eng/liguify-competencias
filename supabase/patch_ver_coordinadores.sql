-- ============================================================================
-- VER Y QUITAR AL COORDINADOR TITULAR DESDE CUALQUIER TORNEO.
-- El acceso del coordinador es POR CLUB, pero su invitación vive en el torneo
-- donde se envió — por eso el modal de otro torneo no lo mostraba. Nuevas RPC:
--  · coordinadores_de_club(club): los coordinadores VIGENTES del club
--    (usuario_club), con su email/nombre — visibles para admin y coordinador.
--  · quitar_coordinador(club, usuario): solo ADMIN de la marca; borra el
--    acceso y marca revocadas sus invitaciones aceptadas de ese club.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

create or replace function competencias.coordinadores_de_club(p_club uuid)
returns table(usuario_id uuid, email text, nombre text)
language sql security definer stable
set search_path = competencias, public
as $$
  select uc.usuario_id, p.email, p.nombre
  from competencias.usuario_club uc
  join competencias.club c on c.id = uc.club_id
  left join competencias.usuario_perfil p on p.id = uc.usuario_id
  where uc.club_id = p_club and uc.rol = 'coordinador'
    and ( competencias.es_admin_marca(c.marca_id) or competencias.es_coordinador_club(p_club) )
  order by p.email
$$;

create or replace function competencias.quitar_coordinador(p_club uuid, p_usuario uuid)
returns void
language plpgsql security definer
set search_path = competencias, public
as $$
declare v_marca uuid;
begin
  select marca_id into v_marca from competencias.club where id = p_club;
  if v_marca is null then raise exception 'Club inválido'; end if;
  if not competencias.es_admin_marca(v_marca) then
    raise exception 'Solo el administrador de la marca puede quitar a un coordinador titular';
  end if;
  delete from competencias.usuario_club
  where usuario_id = p_usuario and club_id = p_club and rol = 'coordinador';
  update competencias.invitacion_club set estado = 'revocada'
  where club_id = p_club and usuario_id = p_usuario and rol = 'coordinador' and estado = 'aceptada';
end $$;

revoke execute on function competencias.coordinadores_de_club(uuid)   from public, anon;
revoke execute on function competencias.quitar_coordinador(uuid,uuid) from public, anon;
grant  execute on function competencias.coordinadores_de_club(uuid)   to authenticated;
grant  execute on function competencias.quitar_coordinador(uuid,uuid) to authenticated;

notify pgrst, 'reload schema';
