# ALEE

ALEE is a rate publishing and trade record platform for the Indian steel trade: manufacturers, distributors, wholesalers and retailers.

- **Publishing:** a seller publishes one base rate with area-based adjustments, and each subscribed buyer sees only the final rate for his own area.
- **Phase 1 (launch)** also covers enquiries, territory allocation, small retailers publishing their own rates, a client book with follow-ups, ALEE Assist, and the Android app. Orders, the iPhone app and online payments follow in Phase 1.1. The full lists are in CLAUDE.md section 18.
- **Launch market:** Goa and Maharashtra. Products: TMT bars, angles, channels.

ALEE is meant to become the record the trade relies on. **Correctness, consistency and an unalterable history matter more than speed.** A wrong rate shown to a buyer is the worst possible failure.

**Read before changing anything:**

| File | What it tells you |
|---|---|
| [CLAUDE.md](CLAUDE.md) | The rules. They are not optional. |
| [docs/decisions.md](docs/decisions.md) | Why things are built the way they are. |
| [docs/database.md](docs/database.md) | Every table and how they connect. |

---

## Set up on a new laptop

You need:
- **Node.js 24 or later** ([nodejs.org](https://nodejs.org)). Check with `node --version`.
- **Git.**
- **A code editor** (VS Code is fine).
- **From the owner:**
  - access to the GitHub repository;
  - membership of the Supabase organisation;
  - the alee-dev database password.

Nothing else needs installing. The Supabase command-line tool comes with the project.

### 1. Get the code

```bash
git clone https://github.com/builalee/alee.git
cd alee
npm install
```

### 2. Connect to the development database (alee-dev)

```bash
npx supabase login
npx supabase link --project-ref rgbveznorkvvukrgxrag
```

- `login` opens a browser to sign in to Supabase.
- `link` asks for the alee-dev database password.
- `rgbveznorkvvukrgxrag` is **alee-dev**. Never link to the live project (The Alee App) unless the owner asks; see CLAUDE.md, section 6.

### 3. Create `.env.local`

Create a file called `.env.local` in the project folder with these three lines:

```
NEXT_PUBLIC_SUPABASE_URL=https://rgbveznorkvvukrgxrag.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=<publishable key>
SUPABASE_SECRET_KEY=<secret key>
```

Get the two keys from the Supabase dashboard: alee-dev → Project Settings → API Keys.

- **`.env.local` is never committed.** Git ignores it already.
- **It must point at alee-dev**, never at live.
- **The secret key must never reach the browser.** Only variables starting `NEXT_PUBLIC_` may be used in screens.

### 4. Run the app

```bash
npm run dev
```

Open http://localhost:3000.

### 5. Run the database checks

```bash
npm run check:db
```

Every check should pass. If one fails, stop and find out why before changing anything.

---

## How the folders are organised

| Folder / file | What is in it |
|---|---|
| `src/app/` | The screens (Next.js App Router). All application code lives under `src/`; imports starting `@/` point here. |
| `public/` | Static images and icons. Stays at the top level, as do the settings files (`package.json`, `next.config.ts`, `tsconfig.json`) and `.env.local`. |
| `supabase/migrations/` | Every change ever made to the database, in order. Each file opens with a header saying what it does and why. **A file that has run is never edited**; corrections are new files. |
| `tests/database/` | Saved database checks, one file per area. `_helpers.sql` holds the shared check functions. |
| `scripts/check-db.mts` | Runs the database checks. |
| `docs/decisions.md` | Why ALEE is built the way it is. Add to it when a decision is made; never delete old entries. |
| `docs/database.md` | Map of every table and how they connect. Update it whenever a table changes. |
| `CLAUDE.md` | The project rules, also read by Claude Code. |
| `AGENTS.md` | Notes for AI coding tools about this version of Next.js. It is maintained automatically by `next dev`. |
| `.env.local` | Your connection settings. On your laptop only; never committed. |

The API layer, central engines (rates, access, notifications…) and shared machinery (money, dates, text) described in CLAUDE.md are not built yet. So far the work has been on the database.

---

## Running the database checks

```bash
npm run check:db                  # every check
npm run check:db -- accounts      # only files whose name contains "accounts"
```

**What happens:**
- Each file in `tests/database/` runs against the database the command-line tool is linked to, normally alee-dev.
- Checks act as different people: a visitor, an ordinary user, an admin, and the database owner. Each check confirms what that person can and cannot do. For example, an ordinary user trying to read another person's phone number must get nothing back.
- **Nothing is kept.** Each file runs inside a transaction that is always rolled back, so test logins and test sellers vanish afterwards. The runner refuses any check file that tries to commit.
- **It refuses to run against anything except alee-dev** unless you add `--allow-live`. That flag is only for the live checklist in CLAUDE.md, section 6.
- The command ends with "All N checks passed", or lists each failure with what was expected and what happened. It exits with an error code on failure.

### Adding checks for a new table

Every new table gets saved checks. This is a project rule.

1. Add a file `tests/database/<area>.sql`, or add to the area's existing file.
2. Use the helpers from `_helpers.sql`:
   - `as_visitor()`, `as_user(id)`, `as_admin(id)`, `as_owner()` to act as someone;
   - `expect_refused`, `expect_rows`, `expect_value` to state what must happen.
3. At minimum, check that:
   - Row Level Security is on;
   - visitors and ordinary users are refused everything they should not see or change;
   - admins can do what they should;
   - anything that must never be deleted cannot be.
4. Run `npm run check:db` and make sure every check passes.

---

## Changing the database

In short (the full rules are in CLAUDE.md, section 5):

1. Write a new migration in `supabase/migrations/` with the standard header.
2. Apply it to alee-dev with `npx supabase db push`, and say which database you are changing before you do.
3. Save its checks in `tests/database/` and run `npm run check:db`.
4. Update `docs/database.md`.
5. If a new decision was made, add it to `docs/decisions.md`.
6. Commit in small steps with plain-language messages. Check `git status` first to make sure no secrets are included.
