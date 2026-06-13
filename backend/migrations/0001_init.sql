-- ============================================================================
-- SoarX — Community backend · Schema initial (Supabase / PostgreSQL)
-- Migration 0001_init.sql
-- ============================================================================
-- Convention :
--   * Toutes les tables vivent dans le schéma `public` (exposé par PostgREST).
--   * `auth.users` est géré par Supabase Auth (GoTrue). On NE crée PAS cette
--     table ; on s'y rattache via des FK vers `auth.uid()`.
--   * RLS est ACTIVÉ sur CHAQUE table. Par défaut, sans policy, tout est refusé.
--   * Confidentialité par défaut : un vol est `private`. Rien n'est public sans
--     action explicite du pilote.
--
-- Idempotent autant que possible (IF NOT EXISTS / CREATE OR REPLACE) afin de
-- pouvoir rejouer la migration sans casse pendant le développement.
-- ============================================================================

-- Extensions utiles -----------------------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "citext";      -- username insensible à la casse
-- NB : on évite PostGIS pour rester léger sur le free tier ; les calculs de
-- distance se font avec la formule de Haversine en SQL (cf. 0002_functions.sql).

-- ============================================================================
-- ENUMS
-- ============================================================================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'flight_visibility') then
    create type public.flight_visibility as enum ('private', 'followers', 'public');
  end if;
end$$;

-- ============================================================================
-- TABLE profiles
-- Le profil public d'un pilote. id = auth.uid() (1:1 avec auth.users).
-- ============================================================================
create table if not exists public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  username      citext unique not null
                  check (char_length(username::text) between 3 and 30
                         and username::text ~ '^[a-zA-Z0-9_]+$'),
  display_name  text,
  bio           text check (char_length(bio) <= 500),
  avatar_url    text,
  country       text,                 -- code ISO 3166-1 alpha-2, ex. "FR"
  created_at    timestamptz not null default now()
);

comment on table public.profiles is
  'Profil public d''un pilote. Lisible par tous, écrit par son propriétaire.';

-- ============================================================================
-- TABLE spots
-- Annuaire communautaire des sites de vol (décollages / atterrissages).
-- Lisible par tous, créé / édité par les utilisateurs authentifiés.
-- ============================================================================
create table if not exists public.spots (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null check (char_length(name) between 1 and 120),
  lat                double precision not null check (lat between -90 and 90),
  lon                double precision not null check (lon between -180 and 180),
  country            text,            -- code ISO 3166-1 alpha-2
  wind_directions    text[] not null default '{}',  -- ex. {"N","NE","E"}
  altitude_takeoff   double precision,               -- mètres
  altitude_landing   double precision,               -- mètres
  description        text check (char_length(description) <= 2000),
  created_by         uuid references public.profiles (id) on delete set null,
  created_at         timestamptz not null default now()
);

comment on table public.spots is
  'Annuaire communautaire des sites de vol. Lisible par tous.';

create index if not exists spots_country_idx on public.spots (country);
create index if not exists spots_geo_idx on public.spots (lat, lon);

-- ============================================================================
-- TABLE flights
-- Un vol publié vers le cloud. Référence le pilote via user_id (= auth.uid()).
-- visibility pilote la diffusion : private (défaut) / followers / public.
-- like_count / comment_count sont des compteurs dénormalisés maintenus par
-- trigger (cf. 0002_functions.sql).
-- ============================================================================
create table if not exists public.flights (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  started_at        timestamptz not null,
  duration_seconds  integer not null default 0 check (duration_seconds >= 0),
  spot_name         text,
  lat               double precision check (lat between -90 and 90),
  lon               double precision check (lon between -180 and 180),
  flight_type       text,            -- "Soaring", "Thermique", "Cross"...
  wing_name         text,
  wing_size         text,
  max_altitude      double precision,  -- mètres
  total_distance    double precision,  -- mètres
  gps_track_url     text,              -- chemin/URL dans le bucket Storage
  visibility        public.flight_visibility not null default 'private',
  like_count        integer not null default 0 check (like_count >= 0),
  comment_count     integer not null default 0 check (comment_count >= 0),
  created_at        timestamptz not null default now()
);

comment on table public.flights is
  'Vols publiés vers le cloud. Privé par défaut.';

create index if not exists flights_user_idx       on public.flights (user_id);
create index if not exists flights_visibility_idx  on public.flights (visibility);
create index if not exists flights_public_feed_idx on public.flights (created_at desc)
  where visibility = 'public';

-- ============================================================================
-- TABLE follows
-- Graphe social : follower_id suit following_id. PK composite.
-- ============================================================================
create table if not exists public.follows (
  follower_id   uuid not null references public.profiles (id) on delete cascade,
  following_id  uuid not null references public.profiles (id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)  -- on ne se suit pas soi-même
);

comment on table public.follows is 'Graphe social des abonnements.';

create index if not exists follows_following_idx on public.follows (following_id);

-- ============================================================================
-- TABLE likes
-- Un like d'un user sur un vol. PK composite (un like par user/vol).
-- ============================================================================
create table if not exists public.likes (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  flight_id   uuid not null references public.flights (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, flight_id)
);

comment on table public.likes is 'Likes des vols (compteur maintenu par trigger).';

create index if not exists likes_flight_idx on public.likes (flight_id);

-- ============================================================================
-- TABLE comments
-- Commentaires sur un vol.
-- ============================================================================
create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  flight_id   uuid not null references public.flights (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 1000),
  created_at  timestamptz not null default now()
);

comment on table public.comments is 'Commentaires des vols (compteur par trigger).';

create index if not exists comments_flight_idx on public.comments (flight_id, created_at);

-- ============================================================================
-- TABLE spot_reviews
-- Avis / notes sur un spot.
-- ============================================================================
create table if not exists public.spot_reviews (
  id          uuid primary key default gen_random_uuid(),
  spot_id     uuid not null references public.spots (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  rating      smallint not null check (rating between 1 and 5),
  comment     text check (char_length(comment) <= 1000),
  created_at  timestamptz not null default now(),
  unique (spot_id, user_id)  -- un avis par user et par spot
);

comment on table public.spot_reviews is 'Avis communautaires sur les spots.';

create index if not exists spot_reviews_spot_idx on public.spot_reviews (spot_id);

-- ============================================================================
-- TABLE live_positions
-- Position temps réel d'un pilote en vol. user_id PK (une ligne par pilote).
-- TTL logique : on considère une position périmée après ~2 min (cf. RLS read
-- + edge function de nettoyage). Realtime diffuse les UPDATE aux abonnés.
-- ============================================================================
create table if not exists public.live_positions (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  lat         double precision not null check (lat between -90 and 90),
  lon         double precision not null check (lon between -180 and 180),
  altitude    double precision,
  heading     double precision check (heading >= 0 and heading < 360),
  visibility  public.flight_visibility not null default 'followers',
  updated_at  timestamptz not null default now()
);

comment on table public.live_positions is
  'Position live des pilotes en vol. TTL logique ~2 min.';

create index if not exists live_positions_updated_idx on public.live_positions (updated_at);

-- ============================================================================
-- VUES LEADERBOARDS
-- Materialized views : rafraîchies périodiquement (cron / edge function), pas
-- en temps réel, pour ne pas charger la base. Ne portent QUE sur les vols
-- publics (un classement implique une diffusion publique consentie).
-- ============================================================================

-- Total d'heures de vol public par pilote.
create materialized view if not exists public.leaderboard_spot_hours as
  select
    f.user_id,
    p.username,
    p.display_name,
    p.country,
    count(*)                                  as flight_count,
    sum(f.duration_seconds)                   as total_seconds,
    round(sum(f.duration_seconds) / 3600.0, 1) as total_hours
  from public.flights f
  join public.profiles p on p.id = f.user_id
  where f.visibility = 'public'
  group by f.user_id, p.username, p.display_name, p.country
  order by total_seconds desc;

-- Index unique requis pour REFRESH MATERIALIZED VIEW CONCURRENTLY.
create unique index if not exists leaderboard_spot_hours_user_idx
  on public.leaderboard_spot_hours (user_id);

-- Altitude max atteinte par pilote (sur vols publics).
create materialized view if not exists public.leaderboard_max_altitude as
  select
    f.user_id,
    p.username,
    p.display_name,
    p.country,
    max(f.max_altitude) as max_altitude
  from public.flights f
  join public.profiles p on p.id = f.user_id
  where f.visibility = 'public'
    and f.max_altitude is not null
  group by f.user_id, p.username, p.display_name, p.country
  order by max_altitude desc;

create unique index if not exists leaderboard_max_altitude_user_idx
  on public.leaderboard_max_altitude (user_id);

-- ============================================================================
-- ROW LEVEL SECURITY
-- On active RLS sur CHAQUE table puis on définit des policies explicites.
-- Règle d'or : deny-by-default, on ouvre au cas par cas.
-- ============================================================================

alter table public.profiles       enable row level security;
alter table public.spots          enable row level security;
alter table public.flights        enable row level security;
alter table public.follows        enable row level security;
alter table public.likes          enable row level security;
alter table public.comments       enable row level security;
alter table public.spot_reviews   enable row level security;
alter table public.live_positions enable row level security;

-- ---------------------------------------------------------------------------
-- Helper : un follower de `target` ? (security definer pour traverser la RLS)
-- ---------------------------------------------------------------------------
create or replace function public.is_follower(target uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.follows
    where follower_id = auth.uid() and following_id = target
  );
$$;

revoke all on function public.is_follower(uuid) from public;
grant execute on function public.is_follower(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- profiles : lecture publique, écriture par le propriétaire uniquement.
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_all on public.profiles;
create policy profiles_select_all
  on public.profiles for select
  using (true);

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self
  on public.profiles for insert
  with check (id = auth.uid());

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists profiles_delete_self on public.profiles;
create policy profiles_delete_self
  on public.profiles for delete
  using (id = auth.uid());

-- ---------------------------------------------------------------------------
-- spots : lecture publique, création/édition par utilisateurs authentifiés.
-- (édition limitée au créateur ; suppression réservée au créateur.)
-- ---------------------------------------------------------------------------
drop policy if exists spots_select_all on public.spots;
create policy spots_select_all
  on public.spots for select
  using (true);

drop policy if exists spots_insert_auth on public.spots;
create policy spots_insert_auth
  on public.spots for insert
  with check (auth.uid() is not null and created_by = auth.uid());

drop policy if exists spots_update_creator on public.spots;
create policy spots_update_creator
  on public.spots for update
  using (created_by = auth.uid())
  with check (created_by = auth.uid());

drop policy if exists spots_delete_creator on public.spots;
create policy spots_delete_creator
  on public.spots for delete
  using (created_by = auth.uid());

-- ---------------------------------------------------------------------------
-- flights : visibilité graduée.
--   * propriétaire : accès total à ses vols.
--   * public : lisible par tous (y compris anon).
--   * followers : lisible par les abonnés du propriétaire.
--   * private : invisible aux autres.
-- ---------------------------------------------------------------------------
drop policy if exists flights_select_visible on public.flights;
create policy flights_select_visible
  on public.flights for select
  using (
    user_id = auth.uid()
    or visibility = 'public'
    or (visibility = 'followers' and public.is_follower(user_id))
  );

drop policy if exists flights_insert_self on public.flights;
create policy flights_insert_self
  on public.flights for insert
  with check (user_id = auth.uid());

drop policy if exists flights_update_self on public.flights;
create policy flights_update_self
  on public.flights for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists flights_delete_self on public.flights;
create policy flights_delete_self
  on public.flights for delete
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- follows : on voit les relations qui nous concernent ; on ne crée/supprime
-- que ses propres abonnements (follower_id = soi).
-- ---------------------------------------------------------------------------
drop policy if exists follows_select_involved on public.follows;
create policy follows_select_involved
  on public.follows for select
  using (follower_id = auth.uid() or following_id = auth.uid());

drop policy if exists follows_insert_self on public.follows;
create policy follows_insert_self
  on public.follows for insert
  with check (follower_id = auth.uid());

drop policy if exists follows_delete_self on public.follows;
create policy follows_delete_self
  on public.follows for delete
  using (follower_id = auth.uid());

-- ---------------------------------------------------------------------------
-- likes : on like en son nom ; lecture si on peut voir le vol concerné.
-- ---------------------------------------------------------------------------
drop policy if exists likes_select_visible on public.likes;
create policy likes_select_visible
  on public.likes for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.flights f
      where f.id = likes.flight_id
        and (
          f.visibility = 'public'
          or (f.visibility = 'followers' and public.is_follower(f.user_id))
          or f.user_id = auth.uid()
        )
    )
  );

drop policy if exists likes_insert_self on public.likes;
create policy likes_insert_self
  on public.likes for insert
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.flights f
      where f.id = likes.flight_id
        and (
          f.visibility = 'public'
          or (f.visibility = 'followers' and public.is_follower(f.user_id))
          or f.user_id = auth.uid()
        )
    )
  );

drop policy if exists likes_delete_self on public.likes;
create policy likes_delete_self
  on public.likes for delete
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- comments : lecture si le vol est visible ; écriture en son nom sur un vol
-- visible ; suppression de ses propres commentaires.
-- ---------------------------------------------------------------------------
drop policy if exists comments_select_visible on public.comments;
create policy comments_select_visible
  on public.comments for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.flights f
      where f.id = comments.flight_id
        and (
          f.visibility = 'public'
          or (f.visibility = 'followers' and public.is_follower(f.user_id))
          or f.user_id = auth.uid()
        )
    )
  );

drop policy if exists comments_insert_self on public.comments;
create policy comments_insert_self
  on public.comments for insert
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.flights f
      where f.id = comments.flight_id
        and (
          f.visibility = 'public'
          or (f.visibility = 'followers' and public.is_follower(f.user_id))
          or f.user_id = auth.uid()
        )
    )
  );

drop policy if exists comments_delete_self on public.comments;
create policy comments_delete_self
  on public.comments for delete
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- spot_reviews : lecture publique, écriture en son nom.
-- ---------------------------------------------------------------------------
drop policy if exists spot_reviews_select_all on public.spot_reviews;
create policy spot_reviews_select_all
  on public.spot_reviews for select
  using (true);

drop policy if exists spot_reviews_insert_self on public.spot_reviews;
create policy spot_reviews_insert_self
  on public.spot_reviews for insert
  with check (user_id = auth.uid());

drop policy if exists spot_reviews_update_self on public.spot_reviews;
create policy spot_reviews_update_self
  on public.spot_reviews for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists spot_reviews_delete_self on public.spot_reviews;
create policy spot_reviews_delete_self
  on public.spot_reviews for delete
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- live_positions : on écrit la sienne ; on lit selon la visibilité déclarée
-- et la fraîcheur (TTL logique 2 min côté lecture).
-- ---------------------------------------------------------------------------
drop policy if exists live_positions_select_visible on public.live_positions;
create policy live_positions_select_visible
  on public.live_positions for select
  using (
    user_id = auth.uid()
    or (
      updated_at > now() - interval '2 minutes'
      and (
        visibility = 'public'
        or (visibility = 'followers' and public.is_follower(user_id))
      )
    )
  );

drop policy if exists live_positions_upsert_self on public.live_positions;
create policy live_positions_upsert_self
  on public.live_positions for insert
  with check (user_id = auth.uid());

drop policy if exists live_positions_update_self on public.live_positions;
create policy live_positions_update_self
  on public.live_positions for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists live_positions_delete_self on public.live_positions;
create policy live_positions_delete_self
  on public.live_positions for delete
  using (user_id = auth.uid());

-- ============================================================================
-- GRANTS
-- PostgREST utilise les rôles `anon` (non authentifié) et `authenticated`.
-- Les policies RLS restent la vraie barrière ; ces grants ouvrent juste le
-- droit SQL de base, filtré ensuite par RLS.
-- ============================================================================
grant usage on schema public to anon, authenticated;

grant select on
  public.profiles, public.spots, public.flights, public.spot_reviews,
  public.live_positions, public.likes, public.comments, public.follows,
  public.leaderboard_spot_hours, public.leaderboard_max_altitude
  to anon, authenticated;

grant insert, update, delete on
  public.profiles, public.spots, public.flights, public.spot_reviews,
  public.live_positions, public.likes, public.comments, public.follows
  to authenticated;

-- Fin 0001_init.sql
