# Dungeon Legends — Online Accounts, Cloud Save & Leaderboard (Phase 1)

**Date:** 2026-09-24
**Status:** Approved design, pre-implementation
**Game:** `index.html` (single-file HTML5 study-RPG), hosted on GitHub Pages at `dungeons.reillyl.com`
**Backend:** Supabase (chosen by user)

---

## 1. Goal

Add real accounts to Dungeon Legends so players can sign in with Google, keep their progress in the cloud across devices, and compete on a leaderboard — while keeping a no-login "Play Offline" mode. Give the owner admin tools to moderate cheaters. Everyone starts from a hard reset.

## 2. Scope

**In scope (this build):**
- Google sign-in via Supabase Auth (one-tap, no typed accounts).
- Username derived from Google **first name**, auto-numbered on collision (`Ethan`, `Ethan2`, …).
- Landing gate: **Sign in with Google** vs **Play Offline**.
- Cloud save/sync of the existing save blob for signed-in players; local-only save for offline/guest.
- **Leaderboard** ranked by **deepest floor reached** (global), banned players excluded.
- **Guardrails** (deter casual cheating): throttled saves, rate-limited + sanity-checked score submissions, monotonic best-floor.
- **Admin/moderation panel** (owner-only): view players, ban/unban, reset a player, wipe a player's items.
- **Hard reset** of all existing local saves on launch.

**Out of scope (later rounds):**
- Daily shop (Phase 3).
- Server-authoritative or replay-verified anti-cheat (explicitly declined — audience is school friends; owner moderates instead).
- Migrating/importing any existing local save (hard reset means none carry over).

## 3. Anti-cheat stance (explicit)

The game runs entirely in the browser, so the leaderboard is **not cryptographically cheat-proof** — a determined person with dev tools can forge a score. This is accepted. Defense is: (a) automatic guardrails that stop lazy cheating, plus (b) the owner watching the board and using admin tools to ban/reset obvious cheaters. Cheating is irrelevant in offline mode (no leaderboard there).

## 4. Player experience

**Landing gate** (new screen shown before the game boots, when there's no active session):
- 🔵 **Sign in with Google** → Google OAuth popup/redirect → online mode.
- 👻 **Play Offline** → local-only guest mode (game behaves exactly as today).

**Online mode (signed in):**
- On first sign-in, a profile is created with `username` = Google first name (+ number if taken).
- Progress auto-saves to the cloud (with a local copy as backup); follows the player to any device.
- **Leaderboard** available (Hub → 🏆), top players by deepest floor.
- If the player is the admin, a **🛠 Admin** entry appears in the Hub.

**Offline mode (guest):**
- Local save only, no leaderboard/cloud. A small "Sign in to save & compete" prompt is shown.
- A signed-in player who drops offline keeps playing from the local cache and re-syncs when back.

## 5. Data model (Supabase / Postgres)

**`profiles`**
| column | type | notes |
|--------|------|-------|
| id | uuid PK | = `auth.users.id`, on delete cascade |
| username | text unique not null | first name + dedupe number |
| best_floor | int not null default 0 | leaderboard metric |
| banned | boolean not null default false | |
| is_admin | boolean not null default false | set manually in dashboard for owner |
| created_at | timestamptz default now() | |
| last_active | timestamptz default now() | |

**`saves`**
| column | type | notes |
|--------|------|-------|
| user_id | uuid PK | = `auth.users.id`, on delete cascade |
| data | jsonb not null | the existing `{s, deck}` blob |
| updated_at | timestamptz default now() | throttle basis |

## 6. Server functions (RPC, `security definer`)

- **`ensure_profile(p_first_name text)`** — called right after sign-in. Creates the caller's profile if missing, assigning a unique username from `p_first_name` (append 2,3,… until free). Returns the profile row.
- **`save_game(p_data jsonb)`** — upserts the caller's `saves` row. Rejects if the caller is `banned`. Throttled: rejects if the row was updated < ~5s ago (rate limit). Updates `last_active`.
- **`submit_score(p_floor int)`** — sets `best_floor = greatest(best_floor, p_floor)` for the caller. Rejects if banned, if `p_floor` isn't a whole number in `[1, 500]` (sanity cap), or if called too frequently (rate limit). Never lowers the score.

## 7. Row-Level Security (RLS)

- **`profiles` SELECT:** allowed to all (leaderboard needs username + best_floor; no secrets in the table).
- **`profiles` UPDATE/DELETE by owner-user:** blocked directly — best_floor only via `submit_score`, username only via `ensure_profile`.
- **`saves` SELECT/UPSERT by owner-user:** only their own row (`user_id = auth.uid()`), and writes go through `save_game`.
- **Admin policies:** a requester where `EXISTS (select 1 from profiles p where p.id = auth.uid() and p.is_admin)` may UPDATE/DELETE any `profiles` and any `saves` row. This powers all moderation. **No service-role key is ever placed in client code** — admin power comes from these RLS policies on the admin's normal session.

## 8. Admin / moderation panel (Hub → 🛠 Admin, admins only)

- **List players:** username, best_floor, last_active, banned.
- **Ban / unban:** toggles `profiles.banned` (blocks their `save_game`/`submit_score`, hides from leaderboard).
- **Reset a player:** deletes their `saves` row (they start fresh next load) and sets `best_floor = 0`.
- **Wipe a player's items:** loads their save JSON, clears inventory + equipped slots, writes it back (keeps level/account).
- (Optional stretch: fine-grained per-item removal — heavier UI, deferred unless asked.)

## 9. Save-sync behavior

- **Authority:** cloud is source of truth for signed-in players. On sign-in: load cloud save → hydrate the game; if no cloud row yet, start fresh (hard-reset era).
- **Writing:** the game's existing `save()` is wrapped — online it debounces and calls `save_game` (plus writes the local cache); offline it only writes localStorage.
- **Two-device edge case:** last-write-wins with debounce. Acceptable for v1.

## 10. Hard reset

Bump the save key from `dungeon_legends_save_v1` → `dungeon_legends_save_v2`. Old local data is ignored (everyone fresh). On load, also `removeItem` the v1 key for tidiness. Cloud starts empty by definition.

## 11. Client integration (single-file game)

- Load the Supabase client from an allowed CDN: `https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2`.
- Initialize with the **project URL + anon (public) key** — both safe to embed; RLS does the protecting.
- Insert an **auth/landing layer** that runs before the game boots and decides online vs offline.
- Wrap `save()`/`load()` with cloud variants; add a **Leaderboard** screen and an **Admin** screen, both gated by session/role.
- Keep all game logic where it is; this is additive, consistent with the existing "additive over freshState()" save-safety pattern.

## 12. Setup the owner must do (guided, one-time)

1. Create a **Supabase project** → copy Project URL + anon key.
2. Run the provided **SQL** (tables, RLS, RPCs) in Supabase's SQL editor.
3. **Google Cloud Console:** OAuth consent screen + OAuth Web client ID. Authorized JS origin `https://dungeons.reillyl.com` (+ `http://localhost:8777` for dev); redirect URI `https://<project-ref>.supabase.co/auth/v1/callback`.
4. **Supabase → Auth → Providers → Google:** paste Google client ID + secret, enable.
5. **Supabase → Auth → URL config:** Site URL `https://dungeons.reillyl.com`, add redirect URLs (live + localhost).
6. Flag the owner's account: set `is_admin = true` on their `profiles` row.

## 13. Testing

- Local dev via `.claude/launch.json` (`python -m http.server 8777`); add localhost to Google + Supabase allowed origins for OAuth in dev.
- Verify: sign-in creates a numbered username; cloud save round-trips; offline mode works with no network; leaderboard shows/excludes banned; each admin action behaves; hard reset wipes old local save.
- Screenshots lag due to the rAF loop — verify game state via `javascript_tool` DOM/state inspection.

## 14. Open considerations

- Sanity cap of floor 500 is a guess; tune to real max reachable.
- Save throttle (~5s) may need tuning against how often the game calls `save()`.
