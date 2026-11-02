# ALEE — Database Map

Every table in the database, what it holds in plain words, who can see and change it, and how the tables connect.

- **Where the truth lives:** the migration files in `supabase/migrations/`. This page is a guide to them. If the two ever disagree, the migrations are right and this page needs fixing.
- **Keep it current:** whenever a table changes, update this page in the same piece of work (see CLAUDE.md, section 5).
- **Checks:** each area has saved checks in `tests/database/`. Run them with `npm run check:db`.

Last updated: 2026-11-01.

---

## How the tables connect

```mermaid
erDiagram
    auth_users      ||--o| accounts         : "one login, one account"
    accounts        ||--o{ consents         : "agreed to"
    accounts        ||--o| seller_profiles  : "sells as"
    seller_profiles ||--o{ seller_segments  : "deals in"
    segments        ||--o{ seller_segments  : "chosen by sellers"
    segments        ||--o{ products         : "has grades"
    segments        ||--o{ sizes            : "has sizes"
    regions         ||--o{ regions          : "contains (parent)"
    regions         ||--o{ accounts         : "person located in"
    regions         ||--o{ seller_profiles  : "store located in"
    seller_profiles ||--o{ charts           : "owns"
    segments        ||--o{ charts           : "chart for family"
    charts          ||--o{ charts           : "copied from template / replaced by"
    charts          ||--o{ chart_versions   : "saved as"
    chart_versions  ||--o{ chart_version_figures   : "size and loading figures"
    chart_versions  ||--o| chart_version_discounts : "discount"
    sizes           ||--o{ chart_version_figures   : "figure for size"
    seller_profiles ||--o{ seller_grades    : "offers grade"
    products        ||--o{ seller_grades    : "offered by"
    seller_profiles ||--o{ seller_sizes     : "offers size"
    sizes           ||--o{ seller_sizes     : "offered by"
    seller_profiles ||--o{ seller_offering_history : "change log"
    seller_profiles ||--o{ area_setting_versions   : "area setup per family"
    segments        ||--o{ area_setting_versions   : "for family"
    area_setting_versions ||--o{ area_settings     : "one row per area"
    regions         ||--o{ area_settings           : "area (empty = everywhere)"
    charts          ||--o{ area_settings           : "size / loading / discount chart"
    area_settings   ||--o{ area_grade_settings     : "per grade"
    products        ||--o{ area_grade_settings     : "grade"
    seller_profiles ||--o{ publishes               : "publishes"
    publishes       ||--o{ publish_items           : "one per family"
    area_setting_versions ||--o{ publish_items     : "version used"
    publish_items   ||--o{ publish_chart_versions  : "chart versions used"
    chart_versions  ||--o{ publish_chart_versions  : "pinned"
    seller_profiles ||--o{ seller_family_status    : "per family: latest, quoting, closed"
    publishes       ||--o{ seller_family_status    : "latest publish"
    seller_profiles ||--o{ seller_family_status_history : "switches and early closes"
    seller_profiles ||--o{ territory_allocations   : "manufacturer allocates"
    seller_profiles ||--o{ territory_allocations   : "distributor holds"
    segments        ||--o{ territory_allocations   : "for family"
    regions         ||--o{ territory_allocations   : "area"
    territory_allocations ||--o{ territory_allocation_events : "every step"
    accounts        ||--o{ enquiries               : "buyer sends"
    seller_profiles ||--o{ enquiries               : "seller or distributor receives"
    brands          ||--o{ brand_families          : "covers"
    segments        ||--o{ brand_families          : "family"
```

In words:

- **A login** (managed by Supabase, in `auth.users`) has at most one **account**. Every personal record hangs off the account.
- **An account** can have many **consents** and at most one **seller profile**.
- **A seller profile** lists the **product families** (segments) the seller deals in, through **seller_segments**.
- **A product family** (segment) has **grades** (products) and one shared list of **sizes**.
- **Regions** form a tree: state → district → taluka → city. Accounts and seller profiles each point to the region where they are.
- **A chart** (size, loading or discount) belongs to one seller and one product family, or to ALEE as a template. Its figures live in **versions**. Each version holds per-size **figures** (size and loading charts) or one **discount** (discount charts).
- **A seller chooses which grades and sizes he sells** (seller_grades, seller_sizes). Every change is logged in seller_offering_history.
- **A seller's area settings** for each product family are saved as **versions**. Each version lists the areas he mentions, with their settings and per-grade settings.
- **A territory allocation** is a manufacturer's area, for one family, offered to and accepted by a distributor. Every step is logged in territory_allocation_events.
- **A publish** is one action by a seller for one or more product families. Per family it records the basic rate and pins the area-settings version and chart versions used. **seller_family_status** points to each family's latest publish and says whether he is quoting, open or closed.

**Deleting a login deletes everything personal.** It removes the account, which removes that person's consents, seller profile, seller product families, grade and size choices with their history, his charts with all their versions, and his area settings with all their versions. This is the only way any of those rows can be deleted. Catalogue, region and template rows are never deleted at all, only switched off.

---

## Area: regions

### `regions` — every place ALEE knows about
One table for states, districts, talukas and cities, each pointing to the place it sits inside.

| Field | Meaning |
|---|---|
| `id` | Permanent identifier. Always look places up by this, never by name (Sangli is a district, a taluka and a city). |
| `name` | Current official name. |
| `level` | `state`, `district`, `taluka` or `city`. |
| `parent_id` | The place it sits inside. A state has none; a district sits under a state; a taluka under a district; a city under a taluka or directly under a district. |
| `alternate_names` | Old names and other spellings, used by search (Aurangabad → Chhatrapati Sambhajinagar). |
| `is_active` | Switched off instead of deleted. |
| `replaced_by_id` | For a switched-off place, the place that replaced it, if any. |
| `is_approved` | New cities added by buyers start unapproved and stay hidden until an admin approves them. |
| `search_text` | Name plus alternate names, kept up to date automatically, for fast search. |

- **Who can see:** anyone sees approved, active places. Admins see all.
- **Who can change:** admins only. Nobody can delete, not even the database owner.
- **Seeded:** Maharashtra (36 districts) and Goa (North Goa, South Goa). Kushavati is deliberately deferred.
- **Search:** `search_regions(query, only_level, max_results)` searches names and old names. It follows the same visibility rules.
- **Checks:** `tests/database/regions.sql`.

---

## Area: catalogue

### `segments` — product families
TMT Bars, MS Angles, MS Channels.

| Field | Meaning |
|---|---|
| `name`, `sort_order` | Display name and position in lists. |
| `short_name` | Short name for display, e.g. "Regular **TMT**". Defaults to the full name if not given. |
| `default_base_unit` | `tonne` or `kg`: the pricing unit a seller starts with when he adds this family. All three default to tonne. |
| `is_active` | Switched off instead of deleted. |

### `products` — grades within a family
For example Fe500, Fe500D and Fe550D within TMT Bars.

| Field | Meaning |
|---|---|
| `segment_id` | The family it belongs to. |
| `name` | Grade name. |
| `is_active` | Switched off instead of deleted. |

Grades carry **no pricing unit**. The unit is chosen by each seller per family (see `seller_segments`).

### `sizes` — sizes within a family, shared by all its grades
For example 8mm–32mm for TMT, 25×3 for angles, ISMC 100 for channels.

| Field | Meaning |
|---|---|
| `segment_id` | The family it belongs to. All grades of the family share this list. |
| `display_name`, `sort_order` | How it is shown and its position. Unique per family, ignoring capitals. |
| `weight_per_metre_kg` | Standard weight of one metre. The basis of every unit conversion. |
| `piece_length_m` | Standard length of one piece. |
| `weight_source` | Where the weight came from (e.g. "IS 1786:2008", or "Calculated" if not in a standard). |
| `is_verified` | The owner has confirmed the weight and length. |
| `is_active` | Switched on for use. **A size cannot be switched on until it is verified.** |

### `sizes_with_piece_weight` (a view, not a table)
The same rows as `sizes`, plus `weight_per_piece_kg` = weight per metre × piece length. Piece weight is calculated every time and never stored, so the two figures can never disagree.

**Catalogue rules**
- **Who can see:** anyone sees active families, grades and sizes. Admins see all.
- **Who can change:** admins only. Nobody can delete.
- **Seeded:**
  - TMT: 3 grades and 7 verified sizes, using IS 1786 weights and 12 m length.
  - Angles: 6 sizes, all unverified and switched off.
  - Channels: 6 sizes (ISMC 75–200), all unverified and switched off.
- **Checks:** `tests/database/catalogue.sql`.

---

## Area: brands

Brands (decisions 2.37 to 2.44) run through everything a seller sets up: grades and sizes, area settings, publishing, status, factories and territory are all **per brand line** (seller, brand, product family). Every function that takes a brand must be told it; Regular is named like any other brand.

### `brands` — ALEE's brand list

| Field | Meaning |
|---|---|
| `name` | The brand's name. No two live brands share a name, ignoring capitals. |
| `is_regular` | The one unbranded option, **Regular**. It covers every family, is never owned, and is shown as "Regular TMT". It can't be rejected, switched off or duplicated. |
| `alternate_names` | Old names and other spellings, used for search and to catch duplicate requests. |
| `status` | `requested` → `approved` or `rejected`. The decision is final; a rejected name can be requested again as a new request, and the old one stays. |
| `requested_by`, `decided_by`, `decided_at` | Who asked for it, and which admin decided, when. |
| `is_active` | Switched off instead of deleted. |

### `brand_families` — which product families a brand covers
Regular has no rows here, because it covers every family.

### How brands are added
- **`request_brand(name, families)`:** a seller asks for a missing brand. If the name, or one of its known spellings, is already on ALEE or already requested, it's refused in plain words: "check tiscon is already on ALEE (as Check Tiscon)."
- **`decide_brand(brand, approve)`:** an admin approves or rejects a request.
- **Direct edits:** admins can also add brands, spellings and families directly.
- **`brand_covers_family(brand, family)`:** whether a brand covers a family; Regular covers all of them.
- **`brand_display_name(brand, family)`:** how a brand is shown. "Regular TMT" for Regular, otherwise its own name. The one place this is decided.

### Who can see and change
- **Approved, active brands** and their families: anyone.
- **A request:** only the seller who made it, and admins.
- **Changes:** only admins change brands. Nothing is ever deleted, not even with the master key.
- **Checks:** `tests/database/brands.sql`.

### Ownership (step 2): `brands.owner_id` and `brand_claims`
- **`brands.owner_id`:** the manufacturer who owns the brand. Public.
  - **Set only by approving a claim:** not even an admin or the master key can set it directly.
  - **Never Regular:** Regular is never owned.
  - **Several brands:** one manufacturer can own several.
- **`brand_claims`:** every claim to own a brand.
  - **What it records:** brand, claimant and time, and status `claimed` → `approved` or `rejected`; `approved` → `ended`. It also records who decided and when, and who ended it and when.
  - **History:** the status only moves forward, and claims are never deleted.
  - **Who sees them:** the claimant and admins.
- **`claim_brand(brand)`:** a manufacturer ALEE has approved claims an approved brand that has no owner. Plain refusals, e.g. "Check Steel already has an owner. If you believe it is yours, contact ALEE."
- **`decide_brand_claim(claim, approve)`:** an admin approves, making the claimant the owner, or rejects. A brand that already has an owner must have it ended first.
- **`end_brand_ownership(brand)`:** an admin ends ownership, for example when a brand is sold.
- **Checks:** `tests/database/brand_ownership.sql`.

### Brand lines (step 3): `seller_brands`
Which brands each seller sells, per product family, e.g. *Bala Traders – Tata – TMT*. Each brand line will get its own setup, rates and status in the next steps.

| Field | Meaning |
|---|---|
| `seller_id`, `brand_id`, `segment_id` | Who, which brand, which family. Never change. |
| `is_active` | Switched off when he stops selling it; never deleted. |

- **What can be added:** only an approved brand that covers the family, in a family the seller deals in. Refusals are in plain words: "Check Tiscon is not listed for MS Angles."
- **No owner needed:** any seller can sell any approved brand, even one with no owner on ALEE.
- **Who sees and changes:** anyone sees active brand lines. The seller and admins add and change them.
- **Copying a brand's setup (step 7):** `copy_brand_setup(family, from brand, to brand, seller)` makes one brand line's grades, sizes and area settings match another's in one call.
  - **Shared charts:** the copy points at the same charts, which are shared rather than duplicated.
  - **Zero and not set:** "not set" and zero are kept apart.
  - **Unit changes:** if his unit for the family changed since the source was saved, amounts are converted exactly or the copy is refused.
  - **Afterwards:** the two brands are separate. Copying again overwrites the target, and its old versions are kept.
- **No automatic lines:** adding a product family does not add any brand line; a seller sells only the brands he chooses, Regular included. (While brands were being built, a Regular line was added automatically; existing sellers' families were carried across as Regular lines.)
- **Checks:** `tests/database/seller_brands.sql`.

### Factories (step 8)
A brand can have several factories. Each is its own seller account, with its own rates, setup and closing time.

| Table | What it holds |
|---|---|
| `brand_factories` | A factory account linked to a brand. `offered` → `active` (the factory accepted), `declined`, or `withdrawn` (the owner took it back); `active` → `left` (the factory left) or `ended` (the owner ended it). Moves forward only; brand and factory never change. |
| `brand_factory_events` | Every step of a link, with time, who and whether an admin. Never changed. |
| `factory_coverage_versions` | Saved versions of which factory covers which area, **per brand and product family**, with who saved it. Never edited. |
| `factory_coverage_areas` | One factory per area in a version. Empty region = "everywhere", chosen explicitly. |

- **Linking:**
  - **`offer_factory_link(brand, factory)`:** only the brand's owner, or an admin, offers.
  - **`respond_to_factory_link(link, accept)`:** only the factory accepts or declines.
  - **`end_factory_link(link)`:** the factory leaves, or the owner ends the link or withdraws an offer.
- **`save_factory_coverage(brand, family, areas)`:** only the owner (or an admin) saves. Every factory named must be linked (active) and must sell that brand in that family. Refusals are plain: "Farid Steel does not sell Check Steel Angles yet."
- **`resolve_brand_factory(brand, family, area)`:** the factory serving a buyer's area, where the closer area wins. If that factory has since left, it says so (`factory_is_linked` false): the area isn't served until the owner reassigns it. There's never a quiet fall-back to another factory.
- **Who sees:** the owner, the brand's linked factories and admins. Other sellers, buyers and visitors see nothing; to buyers the brand appears as one brand.
- **Account deletion:** if a factory account is deleted, its coverage rows go with it (see the open question on account deletion).
- **Checks:** `tests/database/factories.sql`.

---

## Area: accounts and sellers

### `accounts` — one per person
Linked to the person's login; same identifier.

| Field | Meaning |
|---|---|
| `id` | Same as the login. Deleting the login deletes the account and everything linked to it. |
| `full_name`, `firm_name` | Person and firm. |
| `phone` | Indian mobile, `+91…`. For an ordinary user it must be the number they logged in with. |
| `gst_number` | Recorded as entered; not verified. |
| `signup_role` | `manufacturer`, `distributor`, `wholesaler` or `retailer`. Only decides the first home screen; everyone can buy and sell. |
| `region_id` | Where the person is located. |

- **Who can see:** only the person and admins. Visitors who are not logged in cannot read this table at all. This is enforced by the database, not by the screens.
- **Who can change:** the person changes their own; admins can create and change any (the owner sets up the first sellers). No one can delete an account directly; it goes when the login is deleted.
- **Helper:** `current_login_phone()` returns the caller's own verified login phone. It is used to enforce the phone rule and never reveals anyone else's number.

### `consents` — what each person agreed to
An add-only log.

| Field | Meaning |
|---|---|
| `account_id` | Whose consent. |
| `purpose` | What was agreed to, one row per purpose (e.g. `terms_of_use`, `privacy_notice`). |
| `notice_version` | Which version of the notice they saw. |
| `granted` | `true` = agreed, `false` = withdrew (a withdrawal is a new row). |
| `recorded_at` | Set by the database to the moment of saving; cannot be back-dated. |

- **Who can see:** only the person and admins.
- **Who can add:** only the person, for themselves. Admins cannot record consent on someone's behalf.
- **Never changed:** no one can edit a row or delete one on its own, not even the database owner. Rows go only when the login is deleted.

### `seller_profiles` — one per person who sells
The public face of a seller.

| Field | Meaning |
|---|---|
| `account_id` | The seller's account; same identifier. |
| `store_name`, `description` | Shown publicly. |
| `banner_path` | Where the banner picture is kept in file storage. Storage is set up later. |
| `region_id` | Where the store is. |
| `market_close_time` | Daily closing time, Indian time. Empty until set. |
| `is_public` | Public: subscribers see rates at once. Private: each subscription needs approval. Must be chosen; there is no default. |

- **Who can see:** anyone, including private profiles. The profile holds no phone or contact details; those stay in `accounts`.
- **Who can change:** the seller changes his own; admins can create and change any. It cannot be deleted on its own.

### `seller_segments` — which families each seller deals in
And the unit he prices each in.

| Field | Meaning |
|---|---|
| `seller_id` | The seller (his account / profile). |
| `segment_id` | The family. |
| `base_unit` | `tonne` or `kg`. **This is the only pricing unit in ALEE.** It starts from the family's default; the seller may change it. |
| `is_active` | A seller who stops dealing in a family is switched off, not removed. |

- **Who can see:** anyone sees active rows. The seller and admins see all of his.
- **Who can change:** the seller changes his own; admins can change any. A switched-off family cannot be added. A row cannot be deleted on its own.
- **Checks:** `tests/database/accounts.sql` covers all four tables in this area.

---

## Area: charts

A seller's size differences, loading and trade discount are kept in named **charts**. A chart's figures are never edited: every save creates a new **version**, so any past rate can be rebuilt exactly as it was.

### `charts` — a named chart
One seller, one product family, one type.

| Field | Meaning |
|---|---|
| `seller_id` | The seller who owns it. Empty for an ALEE template. |
| `is_template` | An ALEE template. Sellers copy templates; they never use them directly. |
| `segment_id` | The product family. Fixed once created. |
| `chart_type` | `size`, `loading` or `discount`. Fixed once created. |
| `name` | No two active charts of the same seller, family and type share a name. |
| `copied_from_template_id` | Which template a seller's chart was copied from. Information only: the copy is fully separate. |
| `in_use_since` | When a publish first used this chart. Set only by the publish engine, never through the app, and never cleared. |
| `replaced_by_id` | For a switched-off chart, the chart that replaced it: same seller, family and type, and active. |
| `is_active` | Switched off instead of deleted. **A chart that a publish has used can be switched off only by naming its replacement.** |

### `chart_versions` — each saved state of a chart

| Field | Meaning |
|---|---|
| `chart_id` | The chart. |
| `version_number` | 1, 2, 3… per chart. |
| `unit` | `tonne` or `kg`: the unit of every figure in this version, so a figure is never ambiguous. |
| `created_at` | When it was saved. Set by the database. |

### `chart_version_figures` — the figures of a size or loading chart version

| Field | Meaning |
|---|---|
| `version_id` | The version. |
| `size_id` | The size this figure is for. **Size chart:** always a size from the chart's own product family, each size at most once. **Loading chart:** exactly one row with no size (the figure for all sizes), plus optional rows for particular sizes. |
| `amount` | Exact rupees per the version's unit. Positive, negative or **zero; zero means "same as base" and is stored as 0, never left empty.** |

### `chart_version_discounts` — the discount of a discount chart version

| Field | Meaning |
|---|---|
| `version_id` | The version (one discount per version). |
| `kind` | `flat` or `percent`. |
| `flat_amount` | For flat: exact rupees per the version's unit. Never negative. |
| `percent` | For percent: from 0 to 100. |

### How charts are written
Figures are written only by two functions, so a version is always complete when saved and nothing can be added to it later:

- **`save_chart_version(chart, unit, figures, discount)`** saves a new version and returns its id. A seller may save only his own charts. Only admins may save templates. Admins may also save any seller's chart, to set sellers up. A switched-off chart cannot be saved.
- **`copy_template(template, name, seller)`** copies an active template's latest version into a new chart owned by the seller. It records which template it came from. Later changes to the template never reach the copy. A seller copies for himself; an admin may copy for any seller.
  - **Converted into the seller's unit:** the seller must deal in the template's product family. The copy is saved in his unit for that family: ₹6,500/tonne becomes ₹6.5/kg; flat discounts convert the same way; percentages don't change.
  - **Exact or refused:** if any figure can't be converted exactly to 4 decimal places, the whole copy is refused and nothing is left behind.
- **Which figure applies to a buyer** is worked out per size by `resolve_size_figures` (see area settings below). A size chart only needs the sizes that differ for its area.

### Who can see and change charts
- **Seller:** sees and changes only his own charts. Another seller gets nothing back, even when asking for a chart by its id.
- **Templates:** any logged-in seller sees active templates. Only admins create or change them.
- **Admins:** see and change all charts.
- **Visitors:** see nothing yet. Once area settings exist, visitors will see only the charts for their own area.
- **Never changed, never deleted:** no one can change or delete a saved version or figure, not even the database owner. No one can delete a chart. A seller's charts go only when his whole account is deleted.
- **Checks:** `tests/database/charts.sql` (rules, using test data) and `tests/database/templates.sql` (the real shipped templates).

### Templates shipped with ALEE
| Template | Type | Figures |
|---|---|---|
| Standard TMT – Maharashtra & Goa | TMT Bars size chart, per tonne | 8mm 6,500 · 10–25mm 5,500 · 32mm 6,500 |

No loading template is shipped; each seller enters his own loading (decisions 2.16).

---

## Area: what each seller offers

For each brand he sells in a product family (each brand line), a seller explicitly chooses which grades and which sizes he sells. **Nothing is selected by default, and anything not selected is "not offered" to his buyers.**

- **One brand at a time:** every choice, and every history entry, carries the brand (`brand_id`). Choices for one brand never affect another.
- **Needs an active brand line:** choosing requires one ("Add Check Rods to the brands you sell first."). Unselecting is always allowed.
- **The brand must be named:** a choice, or "select all", that names no brand is refused: "Name the brand (Regular is a brand too)."

### `seller_grades` and `seller_sizes` — his current choices
One row per seller per grade (`product_id`) or per size (`size_id`).

| Field | Meaning |
|---|---|
| `seller_id` | The seller. |
| `product_id` / `size_id` | The grade or size. |
| `is_selected` | Offered or not. **No row, or `false`, means not offered.** Unselecting sets `false`; rows are never deleted. |

- **What can be selected:** only active grades and sizes, in a product family the seller currently deals in. Unselecting is always allowed.
- **Select all:** `select_all_in_family(family, 'grades' or 'sizes', selected, seller, brand)` selects or unselects every grade or size of one family, for one brand. It returns how many choices changed.
- **New sizes:** "select all" covers what is switched on in the catalogue now. A size switched on later starts unselected for every seller.
- **Who can see:** anyone sees what a seller offers (selected rows only). The seller and admins see all his choices.
- **Who can change:** the seller changes his own; admins can change any seller's, to set sellers up.

### `seller_offering_history` — every change, kept forever

| Field | Meaning |
|---|---|
| `seller_id` | The seller. |
| `product_id` or `size_id` | The grade or size (exactly one). |
| `is_selected` | What it was changed to. |
| `changed_at` | When. |
| `changed_by` | Who: the seller himself, or the admin who made the change. |

- **Written automatically** whenever a choice actually changes. Nobody can write, change or delete it directly, not even the database owner. It goes only when the seller's whole account is deleted.
- **Who can see:** the seller and admins.
- **Checks:** `tests/database/offerings.sql`.

---

## Area: area settings

What a seller attaches to areas, per product family: area difference, charts, grade premium, display unit, exclusions and grades not sold (CLAUDE.md sections 8 and 9). **Private: only the seller and admins can read them**, because they reveal his margins by area. Buyers will only ever see their own final rate, through the rate engine.

**"Not set" and zero:** throughout these tables an empty field means **not set**, and the setting carries down from the area above. A value, **including 0**, means set here. Zero never carries down.

**Brands:** all of this is per brand line. Saving and both lookups must name the brand; a call that names none is refused.

**Not set anywhere:** the lookups return empty, never 0. For loading, area difference, grade premium and size difference, empty means **missing**: the rate engine must flag it and leave that price out, never price it at zero. A seller who means zero enters 0. Only a missing discount simply means no discount (decisions 2.24).

### `area_setting_versions` — each saved area setup

| Field | Meaning |
|---|---|
| `seller_id`, `brand_id`, `segment_id` | Whose setup, for which brand and product family (the brand line). Each brand has its own versions; charts stay per seller and family, so two brands can point at the same chart. |
| `version_number` | 1, 2, 3… per seller, brand and family. A publish will record which version it used. |
| `unit` | `tonne` or `kg`: the unit of every amount in this version (the seller's unit for the family when saved). |
| `created_at` | When it was saved. |

### `area_settings` — one row per area mentioned in a version
An area the version doesn't mention has no row; everything carries down to it from above.

| Field | Meaning |
|---|---|
| `version_id` | The version. |
| `region_id` | A state, district, taluka or city. **Empty = "everywhere"**, the level above every state. It is only written when the seller explicitly chooses it. |
| `is_excluded` | Not served here. An excluded area carries no other settings. |
| `area_difference` | Exact rupees in the version's unit. Empty = not set; 0 = zero. May be negative. |
| `size_chart_id`, `loading_chart_id`, `discount_chart_id` | The seller's own active charts of that type and family. Empty = not set. |
| `display_unit` | `tonne`, `kg`, `piece` or `metre`. Empty = not set. |

### `area_grade_settings` — per-grade settings within one area

| Field | Meaning |
|---|---|
| `area_setting_id` | The area (within a version). |
| `product_id` | The grade, from the same product family. |
| `grade_premium` | Exact rupees. Empty = not set; 0 = no premium, set here. |
| `size_chart_id` | A size chart just for this grade in this area. Empty = not set. |
| `is_sold` | `false` = not sold here; `true` = sold here (overrides a broader "not sold"); empty = not set. If never set, the grade is sold. |

### How area settings are written and looked up
- **`save_area_settings(family, areas, seller, brand)`** is the only way to save. The seller must sell that brand in that family ("Add Check Rods to the brands you sell first."). It saves the whole setup as a new, complete version and returns its id.
  - "Everywhere" must be given as `"everywhere": true`. An area with no region is refused.
  - A misspelt setting name is refused, so a typo can never become "not set".
  - An empty list means the seller serves nowhere.
  - A seller saves his own; an admin may save for any seller.
- **`resolve_area_settings(seller, family, area, grade, version, brand)`** looks up the settings that apply to the whole area: served or not, area difference, discount chart, display unit, grade premium, and whether the grade is sold. It also says which area each came from (for the seller's breakdown). One query; latest version unless one is given.
  - **Order:** each setting is looked up separately, most specific first: city, taluka, district, state, everywhere. The first value actually set wins, so 0 is used and never skipped.
  - **Served:** decided by the most specific area the seller mentioned. An exclusion there beats any broader area, including "everywhere". Nothing mentioned means not served. A city named inside an excluded district is served.
  - **Not served:** every setting comes back empty, so nothing is revealed.
  - **No size or loading figures:** it deliberately returns none; those are per size.
- **`resolve_size_figures(seller, family, area, grade, version, publish, brand)`** looks up, for one brand line, size differences and loading **one size at a time**. It returns one row per size switched on in the family, and no rows if the area isn't served.
  - **Size difference:** for each size, closest area first. At each area, the grade's own size chart is looked at first (if that area gives the grade one), then the area's family size chart. The first figure found wins. Example: Maharashtra 8mm 6,500, 10mm/12mm 5,500; Satara 10mm/12mm 5,000 → a Satara buyer gets 8mm 6,500 (Maharashtra) and 10mm/12mm 5,000 (Satara).
  - **Loading:** for each size, the closest area with a loading chart answers. It uses that chart's figure for the size, or else its all-sizes figure.
  - **For each size it reports** the figure, its unit (the chart's), where it came from (area name or "everywhere"), whether it came from the grade's chart or the family chart, and whether the seller offers the size.
  - **`is_missing`:** marks a size the seller offers that has no figure anywhere. **That is an error, never zero:** publishing must flag it and leave the size out.
  - **Chart versions:** each chart's latest version is used. A publish must record which chart versions it used.
- **Whose settings:** today only the seller and admins can use either lookup. The rate engine will call them for buyers and return only the final rate. Territory allocation (not built yet) will be checked first.

### Who can see and change
- **Seller:** reads and saves only his own.
- **Admins:** read and save any seller's.
- **Everyone else** (other sellers, buyers, visitors): reads nothing and cannot look settings up.
- **Never changed, never deleted:** no one can change, add to or delete a saved version, not even the database owner. A seller's settings go only when his whole account is deleted.
- **Checks:** `tests/database/area_settings.sql` (settings, privacy, versions) and `tests/database/size_figures.sql` (per-size figures, the Maharashtra/Satara example).

---

## Area: publishing

### `publishes` — one per publish
One action by a seller, covering one or more product families, so buyers get one notification.

| Field | Meaning |
|---|---|
| `publish_number` | Strict order of publishes. |
| `seller_id` | Whose rates. |
| `published_at` | Set by the database at the moment of publishing; can never be back-dated. |
| `published_by`, `by_admin` | The login that published: the seller, or an admin on his behalf during setup. |
| `is_correction`, `corrects_publish_id` | Marks a publish that corrects an earlier one, optionally naming which (always the seller's own). The earlier one stays, unchanged. |
| `request_key` | Sent with each Publish tap. The same key again returns this publish instead of making a second one, so a double tap is one publish and one alert (decision 16.10). Unique per seller; empty on publishes made before it existed. |

### `publish_items` — one per brand line in a publish

| Field | Meaning |
|---|---|
| `brand_id`, `segment_id` | The brand and product family (the brand line). One publish can cover many brands and families, and is still one notification. |
| `base_rate` | The seller's basic rate: exact rupees, above zero. **Private.** |
| `unit` | `tonne` or `kg`: the seller's unit for the family at the time. |
| `area_setting_version_id` | The area-settings version in force. |

### `publish_chart_versions` — the exact chart versions used
One row per chart that the area settings pointed to, pinned to the version that was latest at the moment of publishing. With the area-settings version, this lets any past rate be rebuilt exactly.

### `seller_family_status` — the current state per brand line (seller, brand, family)
**Public; holds no rate.**

| Field | Meaning |
|---|---|
| `latest_publish_id`, `last_published_at` | The latest publish: the quick way to a seller's current rate. The rate engine works out the buyer's figure from it; final rates are not pre-calculated. |
| `is_quoting` | `false` = "not quoting today": buyers see "not quoting" and no figure. Stays off until the seller switches it back on or publishes that family (publishing switches it on, recorded in the history). |
| `closed_early_at` | The latest "close market now". It closes the family only if it came after the latest publish. |

### `seller_family_status_history` — every switch and early close
`stopped_quoting`, `resumed_quoting` or `closed_early`, with when it happened, who did it and whether it was an admin. Add-only; seen by the seller and admins.

### How publishing works
- **`publish_rates(items, is_correction, corrects, seller)`** is the only way to publish. Each item is `{segment_id, brand_id, base_rate}`; the seller must sell that brand there, and each brand line appears once. Refusals name the brand: "Choose where you sell Check Rods TMT before publishing." (For Regular they name the family, "TMT Bars".) A problem on one brand line never blocks another.
  - **The seller must** have a daily closing time set.
  - **Each family must** be one the seller deals in, with area settings saved, and no switched-off chart in use. The rate must be above zero.
  - **Refusals are in plain words** naming the family, area and chart (decisions 2.32), e.g. "Satara still uses 'Old TMT rates', which you switched off. Choose a chart for Satara."
  - **What it does:** pins the versions, marks the charts used ("used since"), and updates the status. A new publish reopens a closed market and switches "not quoting" back on, recorded in the history.
  - **Who:** a seller publishes for himself; an admin may publish for any seller, recorded as such.
- **Four-tap publishing (brands step 10):**
  - **`publish_prefill(seller)`:** lists every brand line he sells, with its last published rate and unit, his current unit, and `move_status`: `move`, `needs_rate` (no rate yet), `unit_changed` (enter a fresh rate), or `not_quoting` (paused; left untouched).
  - **`publish_moved(moves, seller, entered)`:** in **one** publish, it moves every `move` line of the named families by **one amount per family**, in that family's unit. It also publishes the rates `entered` for `needs_rate` and `unit_changed` lines.
  - **Never a silent skip:** if a named family has a line needing a rate that was not entered, it is refused, naming the lines: "Enter today's rate for Check Rods before publishing."
  - **Paused lines:** they are left untouched, and entering a rate for one is refused.
  - **Other refusals, in plain words:** a family with no brands, and a move taking a rate to zero or below.
- **Rebuilding a past rate:** `resolve_area_settings(..., version = the publish's area-settings version)` and `resolve_size_figures(..., publish)` give exactly what that publish used.
- **`market_status(seller, family, at, brand)`** is the one place open/closed is worked out. Anyone can call it. It answers `not_published`, `not_quoting`, `open` or `closed` (with the closing time), now or at any given moment.
  - **Closed** means that, after the latest publish, either the seller's daily closing time (Indian time) has passed or he pressed "close market now".
  - **Published after today's closing time:** it stays open until tomorrow's.
  - **Closing time required:** a seller needs one before his first publish (the setup screen pre-fills 6:00 PM). After publishing he can change it but not clear it, not even with the master key.
- **`set_quoting(family, on/off, seller, brand)`** is the "not quoting today" switch. Switching to the state it's already in records nothing.
- **`close_market_now(families, seller, brands)`** closes the given families and brands now; if none are named, every brand line he sells. Only families currently open are closed and recorded.

**Brands:** every publish item, switch and status lookup must name its brand. Publishing one brand line reopens and resumes only that line.

### Who can see and change
- **Basic rates, publishes and pinned versions:** the seller and admins only. Other sellers, buyers and visitors get nothing, even asking the database directly. Buyers will only ever see their own final rate, through the rate engine.
- **Quoting, open and closed:** anyone (`seller_family_status`, `market_status`). The switch and close history: the seller and admins.
- **Never changed, never deleted:** no one can change, add to or delete a publish or its pinned versions, not even with the master key. They go only if the seller's whole account is deleted (see decisions, open questions).
- **Checks:** `tests/database/publishes.sql`.

---

## Area: territory allocation

**Per brand (step 9):** a manufacturer allocates **a brand he owns**, for a product family that brand covers, in an area, to a distributor. It takes effect only once the distributor accepts. The rate engine checks territory **first**, before exclusions and area settings.

### `territory_allocations` — one row per offer
Each row is followed through to its end.

| Field | Meaning |
|---|---|
| `manufacturer_id`, `distributor_id` | The two sides. Never the same seller. |
| `brand_id`, `segment_id` | The brand (owned by the manufacturer) and product family. |
| `region_id` | The area: state, district, taluka or city. The closer area wins. |
| `allocation_type` | `distributor_prices` (Type A): the manufacturer's rate isn't shown there; buyers are pointed to the distributor, who publishes his own rates. `manufacturer_prices` (Type B): the manufacturer's rate is shown, tagged "Authorised distributor for [area]: [distributor]"; enquiries from there go to the distributor. Can change only while it's an offer. |
| `status` | `offered` (no effect yet) → `active` (accepted, in effect), `declined` (never took effect), or `withdrawn` (the manufacturer took the offer back). `active` → `ended` (by either side). It only moves forward; finished allocations are never revived. |
| `offered_at`, `accepted_at`, `closed_at` | When it was offered, accepted, and finished. |

- **One open allocation** (offered or active) per brand, family and area: a second distributor can't be given the same area and family. Different families can go to different distributors.
- **Fixed once offered:** the manufacturer, distributor, family, area and offer time never change, not even with the master key. To change them, offer a new allocation.

### `territory_allocation_events` — every step, kept forever
`offered`, `type_changed`, `accepted`, `declined`, `withdrawn` or `ended`, with the type at that moment, when, who did it, and whether it was an admin. Nobody can change or delete it.

### How territory is changed and looked up
These are the only ways to change an allocation:
- **`offer_territory(brand, distributor, family, area, type, manufacturer)`:** the brand's owner offers (an admin may offer for him), for a family the brand covers, to a distributor ALEE has approved. Refusals are in plain words, e.g. "You don't own Check Rods, so you cannot allocate it." or "Satara Check Steel TMT is already offered to or held by Bala Traders. End that first."
- **`change_territory_type(allocation, type)`:** the manufacturer changes the type, only while it's an offer.
- **`respond_to_territory(allocation, accept)`:** the distributor accepts or declines. Only an approved distributor can accept.
- **`end_territory(allocation)`:** either side ends an active allocation; the manufacturer can withdraw an offer. The manufacturer's own rate then shows again there, if he serves it.
- **Losing the role (decision 16.9):** when a distributor's approval is removed or refused, his active allocations end and his open offers are withdrawn, recorded as an admin's action. The records stay, and approving him again doesn't bring them back.

**`appointable_distributors()`** is the appointment list: approved distributors with a seller profile, for a brand owner or an admin. Anyone else gets an empty list.

**`resolve_territory(brand, family, buyer's area)`** finds the allocation in effect. Only allocations made by the brand's **current** owner, and held by a distributor approved **now** (`allocation_holder_approved`), count. One that doesn't count is passed over, so a wider allocation or the manufacturer's own settings decide.

**`territory_effect(seller, brand, family, buyer's area)`** is what the rate engine checks first, for every seller it shows:

| Effect | When | What the buyer sees |
|---|---|---|
| `pointed_to_distributor` | The seller is the brand's owner or one of its factories, and the area is Type A | Not his rate; pointed to the distributor |
| `shown_with_tag` | The owner or a factory, and Type B | His rate, tagged "Authorised distributor for [area]: [distributor]" |
| `hidden` | He is the appointed distributor, and Type B | Not his rate for that brand there; his other brands are unaffected |
| `none` | Anyone else, or no allocation | His own rate as usual |

About `resolve_territory`:
- **Single query:** it returns the allocation in effect closest to the buyer (to whom, which type, for which area), or nothing.
- **Public, and no rates:** anyone can call it, and it never returns a rate.

### Who can see and change
- **Allocations in effect:** anyone, because buyers will see the tags and be pointed to distributors.
- **Offers, declines, withdrawals, endings and the history:** only the manufacturer, the distributor and admins.
- **No rates anywhere:** nothing here holds a rate, amount or margin. The manufacturer can't read a distributor's publishes, rates, area settings or charts by any route; the saved checks try each one.
- **Checks:** `tests/database/territory.sql`.

---

## Area: enquiries

### `enquiries` — one per enquiry a buyer sends
| Field | Meaning |
|---|---|
| `buyer_id` | Who sent it. |
| `seller_id` | Whose rate or profile he enquired from. |
| `recipient_id` | Who receives it: the seller, or the authorised distributor when the buyer's area is a Type B area for that brand. |
| `brand_id`, `segment_id` | The brand line. |
| `region_id` | The buyer's area when he sent it. |
| `product_id`, `size_id` | Grade and size, if he named them. |
| `quantity`, `quantity_unit` | How much, if he said. |
| `note` | His message, up to 1,000 letters. |
| `show_identity` | Whether the seller may see his name and phone. |
| `received_after_close` | The seller's market for that brand line was closed when it was sent; the buyer is told the seller will respond when the market opens. |
| `request_key` | From the form. The same key again returns this enquiry, so a double tap sends one. |

- **`send_enquiry(...)`** is the only way in: a logged-in buyer, as himself, from his own area. Refusals in plain words, e.g. "This seller doesn't sell that brand."
- **`received_enquiries()`** is what a seller sees of the enquiries sent to him. A hidden name comes back empty, with the buyer's area, type and how many enquiries he sent in the last 30 days instead.
- **Who sees:** the buyer sees what he sent; admins see all. A seller never reads the table itself, so a hidden name stays hidden.
- **Never changed or deleted;** it leaves only with the buyer's account.
- **Checks:** `tests/database/enquiries.sql`.

---

## Area: roles, settings, plans and reach

Which role each account has, the limits admins set, which plans each seller holds, and so how far his rates reach (docs/decisions.md 9.3, 10, 14.1, 14.4). **No price, plan cost or commission is stored anywhere.**

### `role_requests` — every request for a higher role
| Column | Meaning |
|---|---|
| `account_id` | Who asked. |
| `requested_role` | Wholesaler, distributor or manufacturer (never retailer: everyone is one already). |
| `status` | `requested` → `approved` or `refused`, once. |
| `decided_by`, `decided_at` | The admin, and when. |

- **Signing up** as a wholesaler, distributor or manufacturer creates a waiting request automatically. Until an admin approves it, the account **is a retailer**, with a retailer's reach.
- **Who acted** (`decided_by` here, and the same in every table) is stored as a plain id, never linked to the login, so deleting an account is never blocked by a record that names him.
- **`approved_role(account)`:** the role an account actually has: the latest approved one not removed since, otherwise retailer. Internal (the engines use it); nobody can call it directly.
- **`holds_role(account, role)`:** whether an account holds that role now. Internal too, so nobody can look up another person's role.
- **`request_role(role)`:** asking later. One waiting request at a time.
- **`decide_role_request(request, approve)`:** admins only.
- **Who sees:** each person his own requests; admins all. Nobody changes a decision or deletes a request, not even the database owner.
- **Checks:** `tests/database/roles.sql`.

### `role_removals` — an approved role that ALEE later removed
| Column | Meaning |
|---|---|
| `request_id` | The approval that was removed. One removal per approval. |
| `reason` | Why. Required. |
| `removed_by`, `removed_at` | The admin, and when. |

- **The approval itself is never changed;** this record sits beside it. From that moment the account no longer has the role. To have it again he asks again, and an admin decides.
- **`remove_role(account, role, reason)`:** admins only. No screen yet (decision 16.9).
- **Who sees:** each person his own removals; admins all. Nobody writes one directly, and nobody changes or deletes one, not even the database owner.
- **Checks:** `tests/database/roles.sql`, and `tests/database/territory.sql` and `rate_engine.sql` for what a buyer sees afterwards.

### `settings` — values admins change without a code change
| Key | Starts at |
|---|---|
| `free_reach_retailer` | `taluka` |
| `free_reach_wholesaler`, `free_reach_distributor` | `district` |
| `free_reach_manufacturer` | `state` |
| `free_customer_limit` | 20 |
| `free_outside_buyer_limit` | 10 |

- **`change_setting(key, value)`:** admins only. A value of the wrong kind is refused ("must be a whole number", "must be taluka, district or state").
- **`settings_history`:** every change, with the old and new value, who and when. Never changed or deleted.
- **Lowering a limit** never deletes anything; it only stops more being added.
- **Who sees:** logged-in users see settings; only admins see their history.
- **Checks:** `tests/database/settings.sql`.

### `plans` — plans and their limits, set by admins
| Column | Meaning |
|---|---|
| `name` | E.g. "District reach". |
| `kind` | `reach` or `client_book`. A seller can hold one of each, both or neither. |
| `reach_level` | Reach plans: how far his rates reach from his location: `taluka`, `district` or `state`. Used only if wider than his role's free reach. |
| `extra_states` | Reach plans: how many extra states the admin may name when switching it on. |
| `customer_limit` | Client-book plans: customers allowed. Empty = no limit. |
| `outside_buyer_limit` | Reach plans: outside buyers he may approve. Empty = no limit. |
| `is_free` | Only the old "Free (replaced by settings)" row, switched off 2026-11-01. Free limits now live in `settings`. |

- **Who sees and changes:** logged-in users see plans; only admins add or change them. A plan's kind never changes. Nobody can delete a plan.

### `seller_plans` and `seller_plan_areas` — which paid plans a seller holds, and the states they add
- One row each time an admin switches a plan on (`switch_on_plan(seller, plan, starts, ends, extra states)`; payment happens outside the app in Phase 1). Two plans of the same kind can't overlap. Extra states must be whole states, no more than the plan allows.
- **Never changed**, except `end_plan_early(record)`, once. Never deleted. The history of every plan a seller had stays.
- **`seller_plan_at(seller, kind)`:** the paid plan of that kind in force now, if any.
- **Who sees:** the seller his own; admins all.

### Reach: `seller_reach(seller)` and `within_reach(seller, area)`
- **Every seller has a reach** (decision 14.1). Free: his role's level from settings, taken from his profile location: a retailer's taluka, a wholesaler's or distributor's district, a manufacturer's state. A higher role counts only once approved.
- **No area at that level above him** (for example a city directly under a district, for a retailer): his own location.
- **Paid reach:** the wider of the free level and his reach plan's level, plus the states the plan names.
- **Home area:** his own area at his free level. An approved outside buyer sees the rate for this area, labelled "[area] rate".
- **When a plan lapses**, reach returns to the free level. His settings beyond it stay saved; the rate engine stops applying them.
- **`client_book_limit(seller)`:** his client-book plan's limit, otherwise the free limit.
- Internal; the rate engine, area setup and the request functions use them.
- **Checks:** `tests/database/plans.sql`.

### Area setup is limited to reach
- **`area_settings_within_reach`** (a check on every area saved): an area beyond his reach is refused with "Upgrade to reach more areas. [Area] is outside your reach."
- **Always allowed:** "everywhere" (it means every area he reaches) and exclusions.
- **After a lapse:** an area already in his previous saved version may stay; a new one may not.
- An admin acting for a seller is held to the same reach.
- **Checks:** `tests/database/reach.sql`.

---

## Area: outside-buyer rate requests

### `rate_requests` — a buyer outside a seller's reach asking for his rates
| Column | Meaning |
|---|---|
| `seller_id`, `buyer_id` | Who asked whom. |
| `status` | `requested` → `approved`, `declined` or `withdrawn`; `approved` → `ended`. Forward only. |
| `requested_at`, `decided_at`, `closed_at`, `closed_by` | When, and who closed it. |

- **`request_rates(seller)`:** only a buyer outside the seller's reach can ask (every role has a reach). One open request per pair at a time.
- **`decide_rate_request(request, approve)`:** the seller (or an admin). Approving stops at the outside-buyer limit (his reach plan's, or the free setting), with "Upgrade to approve more."
- **`end_rate_request(request)`:** the buyer withdraws a waiting request; either side ends an approval.
- **`is_approved_outside_buyer(seller, buyer)`:** internal, for the rate engine.
- **Who sees:** the seller and the buyer their own requests; admins all. Nothing deleted.
- **Checks:** `tests/database/rate_requests.sql`.

---

## Area: ex-works switches and plant city

### `seller_ex_works_states` — ex-works on or off, per state
- Each change is a new row (`state_id`, `is_on`, when, who, whether an admin). **No row = off.**
- **`set_ex_works(state, on, seller)`:** a whole state only. Switching on only where his reach touches that state: "Ex-works can be switched on only where you reach. Upgrade to reach more areas." Switching off is always allowed.
- **Retailers:** a free retailer can't switch it on ("Ex-works rates come with a paid plan. Contact ALEE to upgrade."). A paid retailer can, for his own state only ("As a retailer you can switch ex-works on only in your own state."). If his plan lapses, his saved switch stops applying.

### `seller_plant_cities` — his plant city
- Each change is a new row. **No row = his profile location.**
- **`set_plant_city(place, seller)`.**

### Both
- **`ex_works_for(seller, buyer's area)`:** whether ex-works is on in that area's state (always off for a retailer without a paid reach plan), and the plant city. Internal, for the rate engine.
- **Who sees:** the seller his own; admins all. Never changed or deleted. An admin can act for a seller, recorded as admin.
- *(Replaces `seller_ex_works_versions`, a single on/off switch, dropped 2026-11-01 while it held no rows.)*
- **Checks:** `tests/database/ex_works.sql`.

---

## Area: the rate engine

No tables: it reads everything above and records nothing. Decisions: CLAUDE.md section 8, docs/decisions.md 12 and 14.

### What it answers
For one seller, brand, product family and buyer's area (optionally one grade and size, a buyer, or an earlier publish), one line per grade and size:
- **the area rate:** basic + grade premium + size difference + loading + area difference, labelled "[area] rate";
- **or the ex-works rate**, only where there is no area rate (an area he hasn't set up, or one with a missing setting) and ex-works is on in that state: basic + grade premium + size difference + loading at his plant city, labelled "Ex-[plant city]". **Never both.**
- **the discount** beneath: flat per unit, or that percentage of the figure;
- in the area's display unit, converted through weight and **rounded once to the paisa**;
- open or closed, closing time, when published, **published today or not** (earlier days are greyed out), whether it was a correction;
- a tag or message, and a **status**.

### The order of checks
| Step | Status when it stops | What the buyer sees |
|---|---|---|
| 1. Factory (brand owner and his factories, once coverage is set) | `served_by_factory` / `not_served` | "Check Shakti in Pune is supplied by Gopal Steel" / "Doesn't currently supply Pune" |
| 2. Territory, per brand | `buy_from_distributor` (Type A) / `priced_by_brand_owner` (Type B, the distributor's own line) | "For Check Shakti in Sangli, buy from Dev Traders, the authorised distributor." No figure, no ex-works. Type B for the factory: priced, with the tag. |
| 3. Reach (every seller) | `reach_limited` | "Tara Hardware shares rates with buyers in Karad." No figure, no ex-works. An approved outside buyer instead gets the home-area rate, labelled "Karad rate". |
| 4. Not quoting | `not_quoting` | "Not quoting today" |
| 5. No publish yet | `not_published` | "No rate published yet" |
| 6. Grade and size offered, grade sold here | `not_offered` | "Not offered" / "Fe500D is not sold in Sangli" |
| 7. Excluded | `not_served` | "Doesn't currently supply Kolhapur" |
| 7. Not set up | `ex_works` / `price_on_request` | "₹55,750/tonne — Ex-Karad City" where on; otherwise "Price on request — send enquiry" |
| 8–9. Settings from the publish's pinned versions; anything missing | `missing` (or `ex_works`, if on and the plant city's figures are complete) | "Rate not available". The seller is told exactly what to fix. |
| Otherwise | `priced` | The area rate only |

`reach_limited` is a distinct status so the weekly "What you're missing" message can count it.

### Ways in
| Function | Who can call | Returns |
|---|---|---|
| `buyer_rate(...)` | The seller himself and admins, for any area. Any other logged-in person only as himself, for his own area (his account's district), for a **public** seller or one who approved him as an outside buyer, and only for now, not a past publish. A visitor is told "Log in to see rates." | `buyer_rate_line`: final figures, labels, discount lines, unit, market, tag, message. **Never** the basic rate, grade premium or any individual difference. |
| `seller_rate(...)` | The seller and admins | `rate_line`: every component in his pricing unit, where each came from, and what's missing. |
| `rate_preview(brand, family, basic rate)` | The seller and admins | `rate_line` for every area in his current setup, worked out with the rate he's about to publish (default: his latest) and his **current** settings. Areas beyond his reach show "Saved, not applied on your plan". For the publish confirmation. |
| `ex_works_preview(brand, family, state, grade, size)` | The seller and admins | Before switching ex-works on in a state: what buyers in each district of that state within his reach, and each area of his setup there, would see. E.g. "Satara: Satara rate ₹56,250/tonne", "North Goa: Ex-Karad City ₹56,050/tonne". |
| `rates_on_day(seller, brand, family, area, day)` | The seller and admins | Every publish of that brand line that day, exactly as published; or "No data available for that day". |
| `area_rates(family, seller)` | Any logged-in person | Every public seller's lines for his own area, each worked out by `buyer_rate`; optionally one seller. His own lines are left out. The "Rates in my area" screen. |
| `rate_engine(...)` | Nobody directly | The shared engine they all use. |

- **A past publish** returns only what the seller published, from the versions it pinned. Today's plan, territory, factory and ex-works arrangements are never applied to it. An area it didn't cover shows "No data available for that day" (decision 14.5).
- **Checks:** `tests/database/rate_engine.sql`, covering every rate engine case in CLAUDE.md section 20.

---

## Shared machinery

| Name | What it does |
|---|---|
| `is_admin()` | True when the logged-in user's login is marked admin (`app_metadata.role = 'admin'`, which users cannot set themselves). Used by every admin rule. |
| `set_updated_at()` | Keeps `updated_at` current on every table that has one. |
| `prevent_delete()` | Blocks deletes on catalogue tables (segments, products, sizes), for everyone. |
| `prevent_direct_delete()` | Blocks deletes on personal tables except when the whole account is being deleted. |
| `prevent_update()` | Blocks every change to rows that must never change once saved (chart versions and their figures), for everyone. |
| `convert_per_unit(amount, from, to)` | Converts a stored amount between per tonne and per kg (used when copying templates). Exact to 4 decimal places or refused. |
| `convert_rate(amount, from, to, size)` | The one place a rate is converted between tonne, kg, piece and metre, **through weight** (`kg_per_unit`: weight per metre, times piece length for a piece). Exact; never rounded. A size whose weight isn't verified is refused. |
| `format_rupees(amount)` | The one place rupees are written: Indian grouping, rounded to the paisa (half rounds up), ".00" hidden on whole figures. ₹56,500; ₹1,23,456.50; ₹6.50. |
| `region_within(region, area)` | Whether a region is the area or inside it. |
| `resolve_territory(manufacturer, family, area)` | The territory allocation in effect closest to a buyer, if any. Public; no rates. The rate engine checks it first. |
| `market_status(seller, family, at)` | Open, closed, not quoting or not published, now or at any moment. Public. The market status engine. |
| `rupees` | Every money amount. Exact, up to 4 decimal places. More precision is refused, never rounded. |
| `percentage` | Exact, from 0 to 100. |
| `unit` | The four units: `tonne`, `kg`, `piece`, `metre`. Pricing uses only tonne or kg; piece and metre are for display. |
| `region_level` | `state`, `district`, `taluka`, `city`. |
| `account_role` | `manufacturer`, `distributor`, `wholesaler`, `retailer`. |
| `chart_type` | `size`, `loading`, `discount`. |
| `discount_kind` | `flat`, `percent`. |

---

## Not built yet

These appear in CLAUDE.md but have no tables yet. Phase 1 unless marked; phases are in CLAUDE.md section 18:

- screens for role requests, plans, outside-buyer requests, ex-works (with its preview) and factories (the database parts are built)
- the client book itself (its limit, `client_book_limit`, is built), the gap nudge, and "What you're missing" (built switched off; an admin switches it on per district)
- emergency switches (hide a rate, pause sign-ups, maintenance banner), with a record of every use
- the WhatsApp rate card, the seller's weekly chart, alerts that say what changed, the admin "who published today" screen, and language per state
- logging admin reads of seller data (decision 6.5), with the API layer
- client book, follow-ups and activity log; nudges and "What you're missing"
- ALEE Assist (enquiry routing and seller opt-in); per-buyer notification delivery records (deleted after 90 days)
- orders and bills *(Phase 1.1)*; supplier prompt *(Phase 1.1)*; online payments *(Phase 1.1)*

- the area setup screen (it must show a plain coverage summary, e.g. "Kolhapur district: not served, except Kolhapur city")
- notifications on publish (one per publish)
- subscriptions and the buyer feed (they will let approved subscribers of a private seller ask `buyer_rate`; public sellers are already open to any logged-in buyer)
- quoting or declining an enquiry, and forwarding it to other sellers
