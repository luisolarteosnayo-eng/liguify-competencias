create or replace function competencias.norm_txt(t text)
returns text language sql immutable as $$
  select translate(lower(trim(coalesce(t,''))),
                   'áàäâéèëêíìïîóòöôúùüûñç','aaaaeeeeiiiioooouuuunc')
$$;

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

notify pgrst, 'reload schema';