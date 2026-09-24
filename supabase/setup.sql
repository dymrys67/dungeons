-- ============================================================
--  Dungeon Legends — Supabase setup
--  Run this ONCE in your Supabase project:
--    Dashboard → SQL Editor → New query → paste all → Run.
-- ============================================================

-- 1. TABLES ---------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text unique not null,
  best_floor  int  not null default 0,
  banned      boolean not null default false,
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now(),
  last_active timestamptz not null default now()
);

create table if not exists public.saves (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb not null default '{}'::jsonb,   -- the {s, deck} game blob
  updated_at timestamptz not null default now()
);

-- 2. ROW LEVEL SECURITY --------------------------------------
alter table public.profiles enable row level security;
alter table public.saves    enable row level security;

-- helper: is the current caller an admin?
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- profiles: anyone may read (leaderboard); only admins may update/delete directly.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using ( true );

drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update
  using ( public.is_admin() ) with check ( public.is_admin() );

drop policy if exists profiles_admin_delete on public.profiles;
create policy profiles_admin_delete on public.profiles for delete
  using ( public.is_admin() );

-- saves: a user reads only their own row (admins read any); writes go through save_game().
drop policy if exists saves_select on public.saves;
create policy saves_select on public.saves for select
  using ( auth.uid() = user_id or public.is_admin() );

drop policy if exists saves_admin_update on public.saves;
create policy saves_admin_update on public.saves for update
  using ( public.is_admin() ) with check ( public.is_admin() );

drop policy if exists saves_admin_delete on public.saves;
create policy saves_admin_delete on public.saves for delete
  using ( public.is_admin() );

-- 3. FUNCTIONS (all security-definer: they are the only write path for users) ---

-- Create/fetch the caller's profile, giving a unique username from their first name.
create or replace function public.ensure_profile(p_first_name text)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  base text := nullif(btrim(coalesce(p_first_name, '')), '');
  cand text;
  n    int  := 1;
  prof public.profiles;
begin
  if uid is null then raise exception 'not authenticated'; end if;

  select * into prof from public.profiles where id = uid;
  if found then return prof; end if;

  if base is null then base := 'Player'; end if;
  base := left(base, 20);
  cand := base;
  while exists (select 1 from public.profiles where username = cand) loop
    n := n + 1;
    cand := base || n::text;
  end loop;

  insert into public.profiles (id, username) values (uid, cand) returning * into prof;
  insert into public.saves (user_id, data) values (uid, '{}'::jsonb)
    on conflict (user_id) do nothing;
  return prof;
end; $$;

-- Save the caller's game blob (rejects banned users; throttled to 1 write / 3s).
create or replace function public.save_game(p_data jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  last timestamptz;
  is_banned boolean;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select banned into is_banned from public.profiles where id = uid;
  if coalesce(is_banned, false) then raise exception 'account banned'; end if;

  select updated_at into last from public.saves where user_id = uid;
  if last is not null and now() - last < interval '3 seconds' then
    return;  -- throttle: silently ignore too-frequent writes
  end if;

  insert into public.saves (user_id, data, updated_at) values (uid, p_data, now())
    on conflict (user_id) do update set data = excluded.data, updated_at = now();
  update public.profiles set last_active = now() where id = uid;
end; $$;

-- Submit a deepest-floor score (validated 1..500, monotonic, banned blocked).
create or replace function public.submit_score(p_floor int)
returns void
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  is_banned boolean;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_floor is null or p_floor < 1 or p_floor > 500 then return; end if;
  select banned into is_banned from public.profiles where id = uid;
  if coalesce(is_banned, false) then return; end if;

  update public.profiles
     set best_floor = greatest(best_floor, p_floor), last_active = now()
   where id = uid;
end; $$;

-- 4. GRANTS ---------------------------------------------------
grant execute on function public.is_admin()            to authenticated;
grant execute on function public.ensure_profile(text)  to authenticated;
grant execute on function public.save_game(jsonb)      to authenticated;
grant execute on function public.submit_score(int)     to authenticated;

-- ============================================================
--  After running this, make yourself an admin (replace the email):
--    update public.profiles set is_admin = true
--    where id = (select id from auth.users where email = 'YOUR_GOOGLE_EMAIL');
--  (Run that AFTER you've signed in once so your row exists.)
-- ============================================================
