-- ============================================================================
-- PATCH: ESCUDO COMPARTIDO entre clubes HOMÓNIMOS de marcas de la MISMA
-- organización (mismo erp_org_id). Mismo principio que el coordinador
-- multimarca: entre organizadores distintos NO se comparte nada.
-- 1) Backfill inmediato · 2) al crear un club copia el escudo del homónimo ·
-- 3) al cambiar un escudo se propaga a los homónimos de la organización.
-- Ejecutar en Supabase SQL Editor.
-- ============================================================================

-- 1) Backfill: clubes sin escudo toman el del homónimo de su organización
update competencias.club c
set escudo_url = src.escudo_url,
    color      = src.color
from competencias.club src
join competencias.marca ms on ms.id = src.marca_id and ms.erp_org_id is not null
where c.escudo_url is null
  and src.escudo_url is not null
  and src.id <> c.id
  and exists (select 1 from competencias.marca mc
              where mc.id = c.marca_id and mc.erp_org_id = ms.erp_org_id)
  and competencias.norm_txt(src.nombre) = competencias.norm_txt(c.nombre);

-- 2) Al CREAR un club sin escudo: hereda del homónimo de la organización
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
drop trigger if exists t_heredar_escudo on competencias.club;
create trigger t_heredar_escudo before insert on competencias.club
for each row execute function competencias.heredar_escudo_club();

-- 3) Al CAMBIAR el escudo/color: se propaga a los homónimos de la organización
create or replace function competencias.propagar_escudo_club()
returns trigger
language plpgsql security definer
set search_path = competencias, public
as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;   -- evita cascada infinita
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
drop trigger if exists t_propagar_escudo on competencias.club;
create trigger t_propagar_escudo after update on competencias.club
for each row execute function competencias.propagar_escudo_club();

notify pgrst, 'reload schema';
