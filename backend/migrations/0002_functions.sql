-- ============================================================================
-- SoarX — Community backend · Triggers, compteurs & RPC
-- Migration 0002_functions.sql  (à jouer APRÈS 0001_init.sql)
-- ============================================================================

-- ============================================================================
-- 1) Compteurs dénormalisés : like_count / comment_count sur flights
--    Maintenus par trigger AFTER INSERT/DELETE pour rester cohérents même en
--    cas d'écritures concurrentes. On clamp à >= 0 par sécurité.
-- ============================================================================

-- --- likes -----------------------------------------------------------------
create or replace function public.tg_likes_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.flights
      set like_count = like_count + 1
      where id = new.flight_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.flights
      set like_count = greatest(like_count - 1, 0)
      where id = old.flight_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists likes_count_aiud on public.likes;
create trigger likes_count_aiud
  after insert or delete on public.likes
  for each row execute function public.tg_likes_count();

-- --- comments --------------------------------------------------------------
create or replace function public.tg_comments_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.flights
      set comment_count = comment_count + 1
      where id = new.flight_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.flights
      set comment_count = greatest(comment_count - 1, 0)
      where id = old.flight_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists comments_count_aiud on public.comments;
create trigger comments_count_aiud
  after insert or delete on public.comments
  for each row execute function public.tg_comments_count();

-- ============================================================================
-- 2) touch updated_at sur live_positions (défense en profondeur : même si le
--    client oublie de l'envoyer, on horodate côté serveur).
-- ============================================================================
create or replace function public.tg_touch_live_position()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists live_positions_touch_biu on public.live_positions;
create trigger live_positions_touch_biu
  before insert or update on public.live_positions
  for each row execute function public.tg_touch_live_position();

-- ============================================================================
-- 3) RPC nearby_spots(lat, lon, radius_km)
--    Distance Haversine (km) sans PostGIS. Pré-filtre par bounding box pour
--    profiter de l'index (lat, lon), puis filtre fin par distance, trié.
--    Exposée à anon + authenticated (les spots sont publics).
-- ============================================================================
create or replace function public.nearby_spots(
  p_lat       double precision,
  p_lon       double precision,
  p_radius_km double precision default 50
)
returns table (
  id                 uuid,
  name               text,
  lat                double precision,
  lon                double precision,
  country            text,
  wind_directions    text[],
  altitude_takeoff   double precision,
  altitude_landing   double precision,
  description        text,
  created_by         uuid,
  created_at         timestamptz,
  distance_km        double precision
)
language sql
stable
set search_path = public
as $$
  with bounds as (
    select
      -- 1 degré de latitude ≈ 111.045 km ; longitude corrigée par cos(lat).
      p_radius_km / 111.045                                   as d_lat,
      p_radius_km / (111.045 * cos(radians(p_lat)))           as d_lon
  )
  select
    s.id, s.name, s.lat, s.lon, s.country, s.wind_directions,
    s.altitude_takeoff, s.altitude_landing, s.description,
    s.created_by, s.created_at,
    (
      111.045 * degrees(
        acos(
          least(1.0, greatest(-1.0,
            cos(radians(p_lat)) * cos(radians(s.lat))
              * cos(radians(s.lon) - radians(p_lon))
            + sin(radians(p_lat)) * sin(radians(s.lat))
          ))
        )
      )
    ) as distance_km
  from public.spots s, bounds b
  where s.lat between p_lat - b.d_lat and p_lat + b.d_lat
    and s.lon between p_lon - b.d_lon and p_lon + b.d_lon
  -- filtre fin : seuls les spots réellement dans le rayon
  and (
      111.045 * degrees(
        acos(
          least(1.0, greatest(-1.0,
            cos(radians(p_lat)) * cos(radians(s.lat))
              * cos(radians(s.lon) - radians(p_lon))
            + sin(radians(p_lat)) * sin(radians(s.lat))
          ))
        )
      )
    ) <= p_radius_km
  order by distance_km asc
  limit 200;
$$;

grant execute on function public.nearby_spots(double precision, double precision, double precision)
  to anon, authenticated;

-- ============================================================================
-- 4) Rafraîchissement des leaderboards
--    Appelé périodiquement (pg_cron si dispo, sinon edge function planifiée).
--    SECURITY DEFINER pour pouvoir REFRESH sans droits propriétaire côté appel.
-- ============================================================================
create or replace function public.refresh_leaderboards()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  refresh materialized view concurrently public.leaderboard_spot_hours;
  refresh materialized view concurrently public.leaderboard_max_altitude;
end;
$$;

-- Réservé au rôle de service (cron / edge function avec service_role).
revoke all on function public.refresh_leaderboards() from public, anon, authenticated;

-- ============================================================================
-- 5) Purge des positions live périmées (TTL ~2 min).
--    Appelée par l'edge function planifiée (cf. backend/functions/).
-- ============================================================================
create or replace function public.purge_stale_live_positions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count integer;
begin
  delete from public.live_positions
    where updated_at < now() - interval '2 minutes';
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke all on function public.purge_stale_live_positions() from public, anon, authenticated;

-- ============================================================================
-- 6) Création automatique du profil à l'inscription (optionnel mais pratique)
--    À l'arrivée d'un nouvel auth.users, on ne crée PAS le profil tout de
--    suite : le username est choisi par l'utilisateur dans l'app (onboarding).
--    On laisse donc volontairement le client appeler `upsert profiles`.
--    Ce bloc est fourni en commentaire si l'on veut un profil auto plus tard.
-- ----------------------------------------------------------------------------
-- create or replace function public.handle_new_user()
-- returns trigger language plpgsql security definer set search_path = public as $$
-- begin
--   insert into public.profiles (id, username, display_name)
--   values (new.id,
--           'pilot_' || substr(new.id::text, 1, 8),
--           coalesce(new.raw_user_meta_data->>'full_name', 'Pilote'))
--   on conflict (id) do nothing;
--   return new;
-- end; $$;
-- drop trigger if exists on_auth_user_created on auth.users;
-- create trigger on_auth_user_created
--   after insert on auth.users
--   for each row execute function public.handle_new_user();

-- ============================================================================
-- 7) Suppression de compte (RGPD — droit à l'effacement)
--    Supprime auth.users → cascade vers profiles → cascade vers tout le reste
--    (flights, follows, likes, comments, spot_reviews, live_positions).
--    Les spots créés voient created_by passé à NULL (préservation de
--    l'annuaire communautaire ; cf. ON DELETE SET NULL dans 0001).
--    SECURITY DEFINER + contrôle auth.uid() = self : un user ne peut effacer
--    QUE son propre compte.
-- ============================================================================
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  -- Cascade complète des données personnelles via la FK auth.users → profiles.
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- Fin 0002_functions.sql
