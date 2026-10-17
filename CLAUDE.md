# CLAUDE.md — ALEE

Read this fully before doing anything. These rules override defaults.

---

## 1. What ALEE is

ALEE is a rate publishing and trade record platform for the Indian steel industry — manufacturers, distributors, wholesalers and retailers. A seller publishes one base rate with area-based adjustments; each subscribed buyer sees only the final rate for his own area. Phase 1 also covers enquiries, orders with dispatch details, territory allocation, retailer store profiles and a client book.

ALEE is intended to become infrastructure — the system of record the trade relies on. That means **correctness, consistency and an unalterable history matter more than speed of delivery.** A wrong rate shown to a buyer is the worst possible failure.

Launch market: Goa and Maharashtra. Products: TMT bars, angles, channels.

---

## 2. Who you are working with

The owner is a steel trader with 15 years' industry experience. He is **not technical** and does not read code fluently. He understands logic and business deeply.

- Explain every change in plain language and in business terms. No jargon without a one-line explanation.
- State consequences, not mechanics: "a buyer in Sangli would see the wrong rate" rather than "the join returns null".
- When something needs his decision, ask one clear question at the end. Do not scatter questions through the explanation.
- When you are unsure of a fact (administrative boundaries, regulations, costs), check it rather than recall it, and say if you could not check.
- If you find a problem, say so plainly. Do not hide it inside a long summary.
- Do not make product decisions on his behalf. Trade logic is his call.

---

## 3. Non-negotiable rules

1. **Screens never talk to the database directly.** Every data request goes through the API layer. No Supabase client calls inside UI components. This keeps a future move to AWS a configuration change rather than a rewrite.
2. **One shared place for every calculation, format and permission check.** Never repeat logic inside a screen. See section 11.
3. **Permissions are enforced in the database** with Row Level Security. Never rely on hiding a button or a screen. Assume an attacker calls the API directly with a valid login.
4. **Every database change is a migration file.** Never change structure by clicking in the Supabase dashboard.
5. **Always work on alee-dev.** Never apply anything to the live database unless the owner explicitly asks. **State which database you are about to change before every database operation.**
6. **Never delete** regions, charts, differences, rates, orders or bills. Deactivate instead. History must never change.
7. **Never edit a migration that has already run anywhere.** If it was wrong, write a new migration that corrects it.
8. **The secret key never reaches the browser.** Only variables prefixed `NEXT_PUBLIC_` may be used in client code.
9. **TypeScript throughout.** No plain JavaScript.

---

## 4. Environments

| | Supabase project | Purpose |
|---|---|---|
| Development | `alee-dev` | All building and testing. CLI is linked here. |
| Live | `The Alee App` | Real users. Touched only deliberately. |

- `.env.local` must point at alee-dev during development.
- `.env.local` is never committed. Before any commit that adds a file containing secrets, run `git status` and confirm it is not listed.
- Hosting: Vercel. Stack: Next.js (App Router, `src/`), TypeScript, Tailwind, Supabase Postgres, Capacitor for Android/iOS later, FCM and APNs for push.

---

## 5. Migrations

### Rules
- One migration, one purpose. Never bundle unrelated tables or changes.
- Every new table has Row Level Security enabled and explicit policies.
- New tables are not exposed to API roles by default in this project — grant access explicitly in the migration, and let RLS decide what each role sees.
- Index anything used for lookup or search.

### Required header — every migration file opens with this

```sql
-- ============================================================
-- OBJECTIVE:      What this change does, in one or two plain sentences.
-- WHY:            The product decision it comes from.
-- CHANGES:        Tables and columns added or altered.
-- DEPENDS ON:     Earlier migration(s) that must already have run.
-- TOUCHES EXISTING DATA: Yes / No. If yes, describe exactly what.
-- REVERSIBLE:     Yes / No, and how. Flag loudly if data would be lost.
-- TESTED:         What was checked on alee-dev and passed.
-- DATE:           YYYY-MM-DD
-- ============================================================
```

**TOUCHES EXISTING DATA: Yes** means extra care, an explicit warning to the owner, and a backup before it reaches live.

### Verification after every migration
1. Confirm the table and columns exist as expected.
2. Confirm Row Level Security is enabled.
3. Run the access tests: sign in as an ordinary user and attempt to read and write data that user should not see. Every such attempt must be refused.
4. Run **`npm run check:db`**. Every saved check must pass, not only the new ones.
5. Report results to the owner in plain language.

### Whenever a table changes
Do all of these in the same piece of work as the migration. A table change is not finished until all are done:

1. **Save its checks** in `tests/database/<area>.sql`, using the helpers in `tests/database/_helpers.sql`. **Every new table gets saved checks.** At minimum:
   - Row Level Security is on;
   - visitors and ordinary users are refused everything they should not read or change, including another person's private details;
   - admins can do what they should;
   - anything that must never be deleted cannot be.

   Checks never commit. The runner rolls every file back. Never throw checks away after running them.
2. **Update `docs/database.md`**: what the table holds in plain words, who can see and change it, and how it connects to other tables.
3. **If a new decision was made**, by the owner or proposed and accepted, add an entry to `docs/decisions.md`. Never delete an old entry; mark it superseded and add the new one with the reason.

---

## 6. Moving from alee-dev to live

1. Change applied and tested on alee-dev.
2. Committed to GitHub.
3. On the owner's explicit instruction only: link the CLI to live, apply pending migrations, run the same access tests (`npm run check:db -- --allow-live`; checks are rolled back and leave nothing behind), then **link back to alee-dev immediately** and confirm.

Before launch, live may be updated at the end of each build stage. After launch: take a backup first, apply at a quiet time (not during morning publishing), and treat it as a deliberate checklist.

---

## 7. Region model

- Four levels: **state → district → taluka → city**.
- A district sits under a state; a taluka under a district; a city under a taluka or directly under a district.
- Regions carry alternate names for search. Renamed districts keep old names as aliases:
  - Chhatrapati Sambhajinagar ← Aurangabad
  - Dharashiv ← Osmanabad
  - Ahilyanagar ← Ahmednagar
- **Kushavati is deliberately deferred — do not flag its absence.** Goa's new district (carved from South Goa; four talukas moved: Quepem, Sanguem, Dharbandora, Canacona; HQ Quepem; notified 31 Dec 2025) is not yet in the regions table. Goa is seeded as North Goa and South Goa only. Add Kushavati only when the owner says so.
- Regions are never deleted, only deactivated, with an optional pointer to a successor region.
- Buyer-added cities are created unapproved and require admin approval, to prevent duplicate spellings.
- Always resolve regions **by ID, never by name.** Sangli is simultaneously a district, a taluka and a city. Every dropdown must display level and parent.
- Seeded at launch: all 36 Maharashtra districts and Goa's two districts (North Goa, South Goa — Kushavati deferred, see above). Talukas and cities are added as growth reaches them.

---

## 8. How a rate is built

### Catalogue structure
- **Segment** (TMT Bars) → **product / grade** (Fe500, Fe500D, Fe550D).
- **Sizes belong to the segment, not the grade.** TMT has one size list (8–32mm) shared by every TMT grade; the same holds for angles and channels.

### The formula
A buyer's final rate is resolved, in one central function, as:

```
final rate = base rate + grade premium + size difference + loading + area difference
             (trade discount shown separately, beneath)
```

1. **Base rate** — set by the seller, per **his unit for that product family** (tonne or kg).
2. **Grade premium** — the premium a grade carries over the base (e.g. Fe550D over Fe500). An **area-level setting**, resolved like the charts (section 9). In Maharashtra and Goa it is a single premium per grade. *Design only — its table is built together with area settings.*
3. **Size difference** — from the applicable size chart. A size chart is assigned **per segment by default**, and **per grade where a region needs it** (some regions give each grade its own size differences). Per-grade assignment has no screen yet, but nothing in the data model may prevent it.
4. **Loading** — from the applicable loading chart.
5. **Area difference** — for the buyer's area.
6. **Trade discount** — from the applicable discount chart, flat or a percentage of value. **Not added into the rate**: shown as a separate line beneath it.

**Loading and discount follow the seller's unit for that product family**: per tonne if he prices that family per tonne, per kg if per kg. Never mix units inside one calculation.

**Discount is shown to the buyer as a separate line beneath the rate**, e.g. `₹40,300 — less ₹500/tonne`. All other components are combined: the buyer sees only his final figure, never the base, the grade premium or the individual differences.

### Precedence
1. **Territory allocation** — if the area is allocated to a distributor, the manufacturer's rate is not shown there; the buyer is pointed to the distributor.
2. **Explicit exclusion** — the seller has marked this area as not served.
3. **Area resolution** — most specific first: city → taluka → district → state. First match wins.
4. **No match** — the seller does not serve this buyer.

### Critical correctness rules
- **Zero is a real value, not absence.** A difference of ₹0 means "same as base". It must never fall through to a less specific level. Test this explicitly.
- A seller may publish one flat rate with no area configuration at all. This is a distinct mode and must not resolve as "not served".
- Resolution must be a single indexed query, not a loop of separate lookups.

### Units
- **Each seller chooses, per product family, whether he prices per tonne or per kg.** This is the only pricing unit in ALEE. It starts from the family's catalogue default (all three families default to tonne) and the seller may change it. Grades carry no unit of their own: every grade in a family is priced in the seller's unit for that family.
- The base rate, grade premium, size difference, loading, area difference and flat discount are all in that same unit.
- Supported units: **tonne, kg, piece, metre**. Every conversion goes **through weight**, using the size's standard weight per metre and standard piece length.
- Weight per piece = weight per metre × piece length. It is derived, never stored, so the two can never disagree.
- The unit a buyer sees is the **display unit**, an area-level setting (section 9). Conversion to it happens in the rate engine, never in a screen.
- A size whose weight is not yet verified cannot be active, and must never be used to convert a rate.

---

## 9. Area-level settings

Each of the following can be attached to an area and **resolves independently**, most specific first. If not set at a level, it inherits from the level above:

- grade premium (per grade)
- size difference chart (per segment by default; per grade where needed)
- loading chart
- discount chart
- area difference value
- products sold in that area
- whether the area is served
- display unit (tonne, kg, piece or metre)

Example: Maharashtra → Chart A, +₹200. Pune → +₹300 (inherits Chart A). Mumbai → Chart B, +₹500.

- Sellers can hold multiple named charts of each type.
- **The structure is fully flexible; the screens stay simple.** A seller with one chart never sees chart-assignment options. They appear only when he creates a second chart.
- On a public profile, a visitor sees only the charts applying to his own area.
- ALEE ships **template charts** for common configurations. A template is **copied** into the seller's own chart, never linked. Changing a template must never change any seller's existing rates.

---

## 10. Versioning and history

- Charts and area settings are saved as **versions**. Editing creates a new version; old versions are never edited or deleted.
- Each publish records which versions were in force at that moment, so any historical rate rebuilds exactly as it was shown.
- A chart in use cannot be deleted, only replaced.
- A wrong rate is never deleted. The seller publishes a correction; the wrong one remains in history, marked superseded.
- Rate history visible to buyers is scoped to their own area only.

---

## 11. Central machinery

These live in one shared location each, and are used everywhere. Never reimplement them inside a screen.

- **Dates and times** — stored in UTC, displayed in IST, market close evaluated in local time.
- **Money** — formatting and all arithmetic, including rounding rules.
- **Rate resolution** — the single function in section 8. The publish confirmation screen, buyer feed, enquiries and orders must all call the same function. If two places calculate separately they will eventually disagree, and that destroys trust in the record.
- **Permissions** — who can see and do what.
- **User-facing text** — all strings in one file, to allow Marathi and Hindi later.
- **Settings** — file size caps, enquiry expiry, free tier limits and similar values. Never hardcoded.

---

## 12. Access and privacy

- A seller's profile is **public or private**, his choice. Public: subscribers see rates immediately. Private: he approves each subscription request.
- A seller can **remove or block** any subscriber.
- Manufacturers see territory **coverage only** — never a distributor's rates or margin.
- Sellers see subscriber name and city.
- Enquiries: buyer identity is optional. If hidden, the seller sees area, buyer tier and activity level. A seller's quote is visible only to that buyer — never to other sellers.
- Contact details and rates are hidden on a public profile until subscribed.

---

## 13. Sensitive data

- **Transacted prices** (from orders and bills) are the most sensitive data in the system. They must **never** feed any average, aggregate or analytics without the seller's explicit agreement.
- Any future aggregate data is built only from voluntarily published rates or explicitly consented sources.
- Admin **reads** of seller data are logged, not only writes.

---

## 14. Bills and storage

- Bills are **attached to an existing order**, not uploaded independently.
- Every upload is **compressed to roughly 200KB** and a hard size cap is enforced **before** upload. Files stored at full size cannot be shrunk later.
- Bills are **never deleted on non-payment.** A lapsed account loses the ability to upload new bills; existing ones remain, and the other party to the order keeps permanent access.

---

## 15. Security essentials

- OTP requests rate-limited per phone number per hour.
- Anti-scraping: rate limits per account, limits on subscription velocity, flag accounts that subscribe broadly but never enquire.
- Payments via hosted checkout only; card details never reach ALEE servers. Payment confirmed server-side via signed callback, never trusted from the app.
- Entitlements (what a paying seller can access) enforced in the database, not the screen.
- Consent logged separately from Terms at signup; every personal record traceable to one user ID so account deletion is complete.
- Admins identified by `app_metadata.role = 'admin'`, which users cannot set themselves.

---

## 16. Commits

- Commit regularly, in small logical steps.
- Plain-language messages describing what changed and why, e.g. `Add regions table with four levels and renamed-district aliases`.
- Never commit secrets. Check `git status` first.
- Do not push without telling the owner what is being pushed.

---

## 17. Glossary

- **Segment** — a product family: TMT bars, angles, channels.
- **Grade** — a product within a segment, e.g. Fe500D within TMT. Grades share the segment's size list.
- **Base rate** — the seller's reference price, per his unit for that product family (tonne or kg). Grades add a grade premium on top.
- **Grade premium** — the premium a grade carries over the base rate. An area-level setting.
- **Unit** — what a rate is quoted per: tonne, kg, piece or metre. Each seller chooses, per product family, the unit he prices in (tonne or kg; starts from the family's default); each area has a display unit the buyer sees. Units convert through weight.
- **Weight per metre** — the standard weight of one metre of a size, in kg (e.g. 12mm TMT = 0.888 kg/m, from IS 1786). The basis of every unit conversion; multiplied by piece length it gives the weight of one piece.
- **Size difference** — the premium or discount for a particular size relative to base.
- **Loading** — a handling charge added to the rate, in the seller's unit for that product family (per tonne or per kg).
- **Trade discount** — an upfront discount, flat per the seller's unit for that product family (tonne or kg) or a percentage, shown on the invoice.
- **Taluka** — the administrative level between district and city; the level freight is typically priced at.
- **Market close** — the seller's daily closing time; after it, his last rate shows tagged "market closed".
- **Territory allocation** — a manufacturer assigning an area to a distributor, who then publishes his own rates there.

---

## 18. Phase 1 scope — what is being built

- **Accounts** — phone OTP login, role chosen at signup. Every account can both buy and sell.
- **Seller setup** — profile, banner, location, market close time, public or private setting. Size, loading and discount charts, templates, area-level settings.
- **Publishing** — four taps maximum: open, Publish, enter rate (yesterday's pre-filled), confirm. The confirmation shows the **final rate for each area**, not the differences. Supports updating one segment or all segments at once.
- **Market close** — after the seller's close time, his last rate still shows, tagged "market closed", until he publishes again.
- **Search and public profile** — find sellers by product, area or name.
- **Subscriptions** — subscribe to receive rates, alert preference chosen per subscription, approval for private profiles, blocking.
- **Buyer feed** — subscribed sellers' current rates for the buyer's area, with history scoped to his area.
- **Enquiries** — direct to a seller, optional buyer identity, forward to other sellers without retyping, private quotes.
- **Orders** — buyer places order at the verbally agreed rate, seller accepts, seller adds actual weight and vehicle number on dispatch, bill attached to the order. Built last in Phase 1, after publish and subscribe work end to end.
- **Territory allocation** — manufacturer assigns an area to a distributor.
- **Retailer stores** — every outlet gets a shareable store profile.
- **Supplier prompt** — when a seller publishes, his subscribed retailers who also sell are prompted to update their own rates.
- **Client book** — contact import, name, phone, category, one or two tags, a note.
- **Admin** — manage regions, approve buyer-added cities, manage templates.

---

## 19. Out of scope — do not build

Do not build any of the following, even partially, even if it seems helpful. If a task appears to need one, stop and ask the owner.

- Ratings, reviews, following or any social features
- AI recommendations, win-chance scores, competitor comparison, market averages
- Open marketplace or multi-seller bidding
- Field sales team module (hierarchy, visits, expenses, attendance)
- GST number verification (capture only)
- Separate retail and bulk pricing
- Freight, credit terms, minimum order quantity
- Partial dispatch, order amendments, invoicing
- Transporter role or delivery tracking
- Payments and paid subscriptions
- Dashboards or statistics that depend on data that will not yet exist

**Every feature must work with very few users.** Empty statistics on day one make the product look abandoned.

---

## 20. Engines — central machinery

Each engine is built once, tested thoroughly, and used everywhere. Screens never reimplement what an engine does.

| Engine | Job |
|---|---|
| **Rate** | Returns a buyer's final rate from seller, product, size and location. Applies territory, exclusions, area resolution, charts and discount. |
| **Access** | Decides who can see and do what: subscription, public/private, approval, blocking, territory. |
| **Notification** | On publish: finds recipients, respects alert settings, sends **one** message per publish event however many products changed, queues and retries. Publishing must return immediately without waiting for sends. |
| **Market status** | Open or closed now, from the seller's close time in IST. |
| **History** | Records which chart and setting versions applied at each publish. |
| **Supplier prompt** | Finds subscribed retailers who also sell, and prompts them. |
| **Search** | Sellers by product, area or name, including region aliases. |
| **Order** | Moves orders between placed, accepted and dispatched; controls who can make each move. |
| **Bill handling** | Compresses and size-checks uploads before storage. |

### Build order rule
**Engines are built and tested before any screen that uses them.** The rate engine in particular must pass every case below before any screen displays a price:

- Exact city match
- Fall back to taluka, then district, then state
- Explicit exclusion overrides a broader served area
- Territory allocation suppresses the manufacturer's rate
- A difference of ₹0 is used, not skipped
- Flat-rate seller with no area configuration is served everywhere he sells
- Different charts in different areas of the same state
- Discount as a flat amount and as a percentage
- A historical rate rebuilds exactly after charts have since been changed
- A buyer outside every configured area is not served

---

## 21. Further reference

Read the relevant document before building a new area of the product:

- **`docs/decisions.md`**: why ALEE is built the way it is, decision by decision, with the reasoning and open questions. Read it before changing anything that looks odd or overcomplicated; most of it is deliberate.
- **`docs/database.md`**: every table, what it holds in plain words, who can see and change it, and how the tables connect.
- **`README.md`**: setting up on a new laptop, how the folders are organised, and how to run the checks.
- **`tests/database/`**: the saved database checks, run with `npm run check:db`.
