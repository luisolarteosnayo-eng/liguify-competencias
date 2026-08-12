-- ============================================================================
-- REVOCAR/QUITAR COORDINADORES Y SUB-COORDINADORES YA ACEPTADOS.
-- Antes solo se podían revocar invitaciones PENDIENTES; ahora revocar una
-- ACEPTADA además elimina el acceso otorgado:
--  · coordinador  → se borra usuario_club (pierde el CLUB completo, todos sus
--                   torneos; sus sub-coordinadores se revocan por separado).
--                   Solo el ADMIN de la marca puede quitar a un coordinador.
--  · subcoordinador → se borran sus categorías de usuario_club_categoria
--                     (las de esa invitación). Puede hacerlo admin o coordinador.
-- "Modificar" un coordinador = revocar + nueva invitación.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

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
  if v.estado = 'revocada' then raise exception 'La invitación ya está revocada'; end if;

  if v.estado = 'aceptada' then
    if v.rol = 'coordinador' then
      if not competencias.es_admin_marca(v.marca_id) then
        raise exception 'Solo el administrador de la marca puede quitar a un coordinador titular';
      end if;
      delete from competencias.usuario_club
      where usuario_id = v.usuario_id and club_id = v.club_id and rol = 'coordinador';
    else
      delete from competencias.usuario_club_categoria
      where usuario_id = v.usuario_id and club_id = v.club_id
        and categoria_id = any(coalesce(v.categorias, '{}'::uuid[]));
    end if;
  end if;

  update competencias.invitacion_club set estado = 'revocada' where id = p_id;
end $$;

notify pgrst, 'reload schema';
