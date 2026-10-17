# ALEE — Decisions Record

This file records **why** ALEE is built the way it is. CLAUDE.md says what the rules are; this says the reasoning behind them.

Read this before changing anything that looks odd or overcomplicated. Most of it is deliberate, and most of it came from how the steel trade actually works or from why an earlier version of this product failed.

When a decision changes, do not delete the old entry. Mark it superseded and add the new one, with the reason.

---

## Background: the earlier attempt

A version of this product was built and used before. It reached five manufacturers and around fifty buyers, then stalled. Two causes:

1. **Updating rates was hard.** The screens were clumsy, so sellers stopped publishing daily.
2. **Buyers had no reason to come back.** They opened the app only when they needed a rate. If the seller hadn't updated, the rate was stale, and they stopped coming.

The developers disappeared and no code survived. Many decisions below exist specifically to avoid repeating those two failures.

---

## 1. The product

### 1.1 One publish, each buyer sees only his own final number
**Decision:** A seller sets one base rate and area adjustments. A buyer in Sangli sees only the Sangli figure — never the base rate, never the adjustment.
**Why:** Today a manufacturer sends separate WhatsApp messages to each area group. The adjustment is his pricing logic and, for a distributor, his margin. Exposing it would stop sellers from using ALEE at all.

### 1.2 Publishing takes four taps, with yesterday's rate filled in
**Decision:** Open, Publish, enter rate, confirm. A one-tap option moves every product at once.
**Why:** The earlier version died because updating was harder than forwarding a WhatsApp message. If ALEE is slower than WhatsApp, sellers go back.

### 1.3 The confirmation shows final rates per area, not the adjustments
**Why:** The seller must see exactly what each area will receive before it goes out. He thinks in final numbers, and a mistake caught here never reaches a buyer.

### 1.4 Market close
**Decision:** Each seller sets a closing time. After it, his last rate stays visible, tagged "market closed", until he publishes again.
**Why:** Without it, a quiet day looks the same as an abandoned profile. That ambiguity was part of what made the earlier version feel dead.

### 1.5 Instant notifications, with alerts chosen per seller
**Decision:** Every rate change notifies subscribers immediately. When subscribing, the buyer chooses whether he wants alerts from that seller.
**Why:** The rate must come to the buyer rather than him remembering to look — that was the second failure. But a buyer following ten sellers who each publish twice a day would get twenty alerts and mute the app. Per-seller choice prevents that.

### 1.6 One notification per publish, however many products changed
**Why:** A seller who moves all ten products at once must not send ten messages. That is how an app gets muted on its first day.

### 1.7 Public or private profiles, approval, and blocking
**Decision:** Public: anyone who subscribes sees rates. Private: the seller approves each request. Either way, he can remove or block any subscriber.
**Why:** A distributor will not publish where his manufacturer or a competitor can see his rates. Blocking also closes a specific gap: a manufacturer could register under another firm name and subscribe to his own distributor.

### 1.8 Profiles are visible; rates and contact details are not
**Decision:** Anyone can see a seller's store name, location, products, size differences and loading. Rates and phone number need a subscription.
**Why:** A buyer needs enough to decide whether to subscribe. Size differences and loading are public for now — this is to be revisited, since one subscribed rate plus the public differences reveals a seller's full product ladder.

### 1.9 Every account can buy and sell
**Decision:** The role chosen at signup only sets which home screen appears first.
**Why:** In this trade almost everyone is both. A retailer buys from wholesalers and sells to builders.

### 1.10 Retailer stores and the supplier prompt
**Decision:** Every retailer gets a shareable store profile. When a seller he subscribes to publishes, he is prompted to update his own rates in one tap.
**Why:** Retailers update only when something moves upstream. Prompting at exactly that moment keeps their stores current without nagging them.

### 1.11 Enquiries are direct, optionally anonymous, and sealed
**Decision:** A buyer sends an enquiry to one seller, and can forward it to others without retyping. He may hide his name; the seller then sees area, buyer type and activity level. Each seller sees only his own quote.
**Why:** A retailer will not shop around if his regular supplier can see him doing it. Sealed quotes stop sellers undercutting each other into a race to the bottom. The area and activity details tell a seller the enquiry is genuine without revealing who sent it.

### 1.12 Territory allocation shows coverage only
**Decision:** A manufacturer can hand an area to a distributor. He sees that the area is covered, never the distributor's rates. A buyer searching the manufacturer is pointed to the distributor.
**Why:** The distributor's margin is his own business. Without this guarantee he will not accept the arrangement.
*(Extended 2026-10-17 by 2.33 to 2.36: this describes Type A, "distributor sets the price". There is also Type B, "manufacturer sets the price", where buyers see the manufacturer's rate tagged with the authorised distributor. Coverage-only still holds for both: the manufacturer never sees the distributor's rates or margin.)*

### 1.13 Orders are in Phase 1, kept minimal
**Decision:** The buyer places an order at the rate agreed on the phone, the seller accepts, and on dispatch the seller adds actual weight and vehicle number. A bill can be attached.
**Why:** Rates published are not final — negotiation happens by phone and always will. What the trade lacks is a record of what was finally agreed. The commonest dispute in steel distribution is "you promised that rate"; an accepted order settles it. Built last in Phase 1, after publishing works.

### 1.14 Client book, stripped down
**Decision:** Contact import, name, phone, category, a tag or two, a note. No scoring.
**Why:** Retailers have no customer records at all, so it helps a single user on day one. Behaviour scoring needs order data that won't exist yet.

### 1.15 What is deliberately not built
Ratings, AI suggestions, market averages, open bidding, dashboards and similar features are excluded from Phase 1 (full list in CLAUDE.md).
**Why:** Every one of them needs many users to mean anything. On day one they show empty numbers, and an app full of zeros looks abandoned.

---

## 2. The pricing model

### 2.1 The formula
**base rate + grade premium + size difference + loading + area difference**, with trade discount shown separately beneath.

### 2.2 Discount is shown as its own line
**Why:** That is how it appears on the invoice. A discount shown on the bill reduces the value GST is charged on, so traders always refer to it separately.

### 2.3 Settings attach to an area and resolve independently
**Decision:** Size chart, loading chart, discount chart, grade premium, area difference, products sold, whether served, and display unit can each be set at any area level. Each is looked up separately, most specific area first, inheriting from above if not set.
**Why:** Manufacturers genuinely vary these by area — Chart A for Maharashtra, Chart B for Karnataka, or Chart A for Pune and Chart B for Mumbai. Deeper markets work differently again. Treating each as an independent setting means the next variation discovered becomes one more setting, not a rebuild.

### 2.4 Multiple charts, simple screens
**Decision:** The structure allows any number of charts. A seller with one chart never sees chart-assignment options.
**Why:** Flexibility makes software hard to use. The power sits underneath for the sellers who need it; everyone else sees a simple screen.

### 2.5 Templates are copied, never linked
**Decision:** ALEE provides ready-made charts. A seller's copy becomes his own.
**Why:** Speeds up setup. Copying ensures a correction to a template can never silently change a seller's live rates.

### 2.6 Grade premium, and sizes belong to the product family
**Decision:** In Maharashtra and Goa a higher grade carries only a premium, and the same size differences apply to every grade. Sizes are listed once per product family, not once per grade. A size chart can still be assigned to a single grade where a region needs it.
**Why:** That is how these markets price. It varies elsewhere, so grade premium is an area-level setting and per-grade charts remain possible.

### 2.7 Units
**Decision:** Each seller chooses, per product family, whether he prices per tonne or per kg. Buyers may see tonne, kg, piece or metre depending on their area. Every conversion goes through weight. Weight per piece is calculated, never stored.
**Why:** The same item sells in different units in different places — pipes per kg in one area, per metre in another. A manufacturer quotes per tonne; a small retailer often per kg. Converting through weight means the seller maintains one price, not one per unit. Storing piece weight as well as metre weight would allow the two to disagree.

### 2.8 Changing unit converts charts automatically
**Why:** A size difference of ₹6,500 per tonne must become ₹6.50 per kg, or every rate is wrong by a factor of a thousand. The conversion is saved as a new version so past rates are untouched.

### 2.9 Zero is a real value
**Why:** An area difference of ₹0 means "same as base". If treated as "not set", the lookup falls through to a broader area and every buyer there is quoted wrongly — the kind of error nobody notices for weeks.

### 2.10 Unverified weights cannot be used
**Why:** A wrong weight produces a wrong converted rate. Sizes stay switched off until their weight is confirmed.

### 2.11 A chart belongs to one seller and one product family
**Decision (2026-10-17):** Each size, loading or discount chart belongs to one seller and one product family, or to ALEE as a template. Its owner, family and type never change; a different arrangement is a new chart.
**Why:** A TMT size chart means nothing for angles. Fixing the owner and family means a chart can never quietly start pricing something it was not written for.

### 2.12 Every save is a new version, and each version states its unit
**Decision (2026-10-17):** Chart figures live in versions. Saving creates a new version; an existing version is never edited or added to, not even by the database owner. Each version records whether its figures are per tonne or per kg, and when it was saved.
**Why:** This is decision 4.1 applied to charts. Recording the unit on the version means "6.5" can never be mistaken for rupees per tonne when it was rupees per kg, a thousand-fold error (see 2.8).

### 2.13 Money is stored exactly
**Decision (2026-10-17):** Every money amount is an exact decimal, never an approximate number that can drift by fractions of a rupee.
**How:** amounts keep up to 4 decimal places, so a per-tonne figure converted to per kg stays exact (₹6,533/tonne = ₹6.533/kg). A figure with more precision is refused, not silently rounded. Rounding for display belongs to the money engine (CLAUDE.md section 11), never to storage.

### 2.14 A used chart is switched off only with a replacement
**Decision (2026-10-17):** No chart is ever deleted. A chart any publish has used can be switched off only by naming the active chart that replaces it, of the same seller, family and type.
**Why:** History must lead somewhere. A buyer's area pointing at a switched-off chart with no successor would silently lose its size differences.
**How, until publishing exists:** each chart carries a "used since" mark that only the publish engine can set, and that can never be cleared.

### 2.15 Charts stay private until area settings exist
**Decision (2026-10-17):** For now only the owning seller and admins see a seller's charts. Logged-in sellers see templates. Visitors see nothing. Once area settings are built, a visitor will see only the charts that apply to his own area.
**Relation to 1.8:** 1.8 says size differences and loading are public. That still stands, but takes effect only with area settings, and only for the visitor's own area.

### 2.16 ALEE ships a TMT size template, but no loading template
**Decision (2026-10-17):** ALEE's first template is the TMT Bars size chart "Standard TMT – Maharashtra & Goa", per tonne:

| Size | Figure (₹/tonne) |
|---|---|
| 8mm | 6,500 |
| 10mm | 5,500 |
| 12mm | 5,500 |
| 16mm | 5,500 |
| 20mm | 5,500 |
| 25mm | 5,500 |
| 32mm | 6,500 |

**No loading template is shipped.**

**Why:** Size differences are largely common across sellers in these markets, so a template saves a new seller from typing them and keeps them consistent. Loading is different: it varies per seller, so any template figure would be wrong for most sellers and would invite them to publish a loading that isn't theirs. Each seller enters his own loading.

### 2.17 Sellers choose exactly what they sell; a missing figure is an error, never zero
**Decision (2026-10-17):**
- **Choosing:** ~~within each product family he deals in, a seller explicitly selects which grades and which sizes he sells~~ **Updated 2026-10-17 (brands, 2.40):** for each brand he sells in a product family, a seller explicitly selects which grades and which sizes he sells, with a select-all option. Nothing is selected by default.
- **Not selected means not offered:** a grade or size not selected is "not offered" to his buyers.
- **New sizes start unselected:** a size switched on in the catalogue later starts unselected for every seller. "Select all" covers only what exists at that moment.
- **Nothing is deleted:** selecting and unselecting never deletes anything, and every change is kept as history, with who made it.
- **A missing figure is an error:** if a seller has selected a size but his size chart has no figure for it, that is an error, not zero. The rate engine must never treat it as zero. Publishing must flag it and leave that size out until it is fixed.

**Why:** A seller who doesn't stock 32mm must never appear to quote it. Making him choose, rather than assuming everything, means ALEE only ever shows what he actually sells. A missing figure treated as zero would quote that size at the base rate, a wrong rate nobody notices until a buyer orders it. Leaving the size out and flagging it is safe; guessing is not.
**How:** `resolve_size_figures` lists, for a buyer's area, every size the seller offers that has no figure in any applicable area (2.22). Publishing and the rate engine must both use it. *(Originally `size_chart_missing_figures`, which judged one chart on its own; superseded 2026-10-17.)*

### 2.18 Copying a template converts into the seller's unit
**Decision (2026-10-17):** When a seller copies a template, his copy is saved in the unit he prices that product family in. A per-tonne template copied by a per-kg seller becomes per kg: ₹6,500 per tonne becomes ₹6.50 per kg. Flat discounts convert the same way; percentages don't change. A seller must deal in the template's product family to copy it.
**Why:** A seller's charts should read in the unit he thinks and prices in. This replaces the earlier proposal that copies keep the template's unit (see open questions).
**How:** conversion between per tonne and per kg happens in one place, `convert_per_unit`. If a figure cannot be converted exactly to 4 decimal places, the whole copy is refused rather than rounded (2.13).

### 2.19 Area settings: what can be attached, and "everywhere" only by choice
**Decision (2026-10-17):** Per product family, a seller can attach any of these to an area:
- an area difference (may be zero or negative);
- a size chart, for the whole family or for one grade;
- a loading chart;
- a discount chart;
- a grade premium per grade;
- a display unit;
- an explicit exclusion ("not served");
- grades not sold there.

An area is a state, district, taluka or city, or **"everywhere"**, a level above every state for a seller who charges the same everywhere. "Everywhere" must be chosen explicitly. **No seller serves anywhere by default**: with no area settings, or with none covering a buyer's area, the buyer is not served.
**Why:** Serving by default would show a seller's rate in places he cannot deliver (3.3). "Everywhere" exists so a flat-rate seller does not have to list every state, but it must be his choice, never something that happens because a field was left blank.

### 2.20 Area settings are saved as versions, and are private
**Decision (2026-10-17):**
- **Versions:** a seller's whole area setup for ~~one product family~~ **one brand in one product family (updated 2026-10-17, brands, 2.40)** is saved as a version. Every save makes a new version; old versions are never changed, added to or deleted, not even by the database owner. Each version records its unit, and a publish will later record which version it used.
- **Who can read them:** only the seller and admins. Not buyers, not other sellers, not visitors.

**Why:**
- Versions, as with charts (4.1, 2.12), so any past rate can be rebuilt exactly.
- Privacy, because area settings reveal a seller's margins by area (1.1). Buyers only ever see their own final rate, through the rate engine.

### 2.21 How area settings are looked up
**Decision (2026-10-17):**
- **Most specific first:** each setting is looked up separately: city, taluka, district, state, everywhere.
- **Carry down:** a setting not set at a level carries down from the level above.
- **Zero stops there:** zero is a real value and never carries down. "Not set" (stored empty) and zero (stored 0) can never be confused.
- **Exclusions:** an exclusion beats a broader area. Excluding a district inside a served state means that district is not served, even when "everywhere" is chosen.
- **Territory allocation** (not built yet) will be checked before any of this.

**How:**
- **One lookup:** `resolve_area_settings` is the one place this lookup happens, in a single query. The rate engine must use it, never repeat it. Size differences and loading are looked up per size instead (2.22).
- **Mistyped settings:** a misspelt setting name is refused when saving, so a typo can never silently become "not set".
- **A grade is sold** in an area unless set "not sold" there or above. The rate engine must also check the seller has selected the grade (2.17).
- **Settled by the owner (2026-10-17): the more specific area wins.**
  - **Served or not** is decided by the most specific area the seller has mentioned for that buyer. A city the seller names inside an excluded district is served: "Kolhapur district: not served, except Kolhapur city".
  - **A grade's own size chart** is looked at before the family size chart *at the same area*. A closer area still beats a broader one, whether its figure comes from the family chart or a grade chart (detail in 2.22).
  - **Why the grade chart is the exception:** in TMT, a better grade is normally priced as a **grade premium on top of the shared size difference**, so most sellers will never give a grade its own size chart. Where a region does price each grade's sizes separately, the grade chart is there.

### 2.22 Size differences are looked up one size at a time
**Decision (2026-10-17):** An area only needs the sizes that differ. For each size, the closest area that has a figure for that size wins: city, taluka, district, state, everywhere.

**Example:**
- Maharashtra: 8mm +6,500, 10mm and 12mm +5,500.
- Satara: only 10mm and 12mm, at +5,000.
- **A Satara buyer gets** 8mm +6,500 from Maharashtra, and 10mm and 12mm +5,000 from Satara.

**Rules:**
- **Zero is a real figure** and never carries down: Pune 8mm 0 stays 0.
- **A size the seller offers with no figure anywhere is an error, never zero** (2.17). It is flagged and left out.
- **A grade's own size chart:** at each area, closest first, look in the grade's own chart, then in that area's family chart. Only if neither has the size, move up to the next area.
  - So in Satara, Fe550D 12mm comes from Satara's Fe550D chart, 10mm from Satara's family chart, and 8mm from Maharashtra's Fe550D chart if it has one, otherwise Maharashtra's family chart.
  - A family figure in a closer area beats a grade figure in a broader area.
- **Loading** follows the same per-size rule. At each area, a loading chart's figure for that size is used if it has one, otherwise its "all sizes" figure. Every loading chart has an "all sizes" figure, so the closest area with a loading chart always answers for every size: a Satara loading chart of 200 for all sizes gives 32mm 200, even if Maharashtra's chart says 300 for 32mm.

**Why:** A seller who charges Satara ₹500 less on two sizes should change two figures, not copy the whole chart. Copying would leave the other sizes stale the next time he changes Maharashtra.

**How:**
- **One lookup:** `resolve_size_figures` is the one place this happens. For every size it reports the figure, where it came from, and whether an offered size is missing a figure. The rate engine and publishing must use it.
- **Removed:** the earlier check `size_chart_missing_figures` judged one chart on its own, and would wrongly flag Satara's chart for not repeating Maharashtra's 8mm.
- **Latest chart versions:** each chart's latest version is used. A publish must record the chart versions it used, so a historical rate rebuilds exactly (4.1).

### 2.23 The area setup screen shows coverage in plain words
**Decision (2026-10-17), for the future setup screen:** it must show a plain coverage summary of where the seller serves, for example **"Kolhapur district: not served, except Kolhapur city"**.
**Why:** Most-specific-wins (2.21) makes exceptions possible inside exceptions. A seller must be able to see at a glance where he actually serves, without working it out from a list of areas.

### 2.24 Anything that could make a price look cheaper is never assumed to be zero
**Decision (2026-10-17):** If a setting is not set in any area covering the buyer, and leaving it out would make the price look cheaper than intended, the rate engine treats it as **missing**. It flags it and leaves that price out. It never treats it as zero. A seller who means zero enters zero.

**Settings this applies to (missing = flagged, never zero):**

| Setting | Missing means | Why |
|---|---|---|
| Base rate | No price can be shown | Nothing to build on. |
| Size difference, per size the seller offers | That size is flagged and left out (2.17, 2.22) | Most size differences are a premium. Treating a missing one as 0 quotes that size at the base rate. |
| Loading, per size | Flagged; prices that need it are left out | Loading is added to the rate. A missing loading treated as 0 quotes every size too cheaply. |
| Area difference | Flagged; that area's prices are left out | Usually a premium for freight. Treated as 0, a far district would get the near-district price. |
| Grade premium, per grade the seller offers and sells there | That grade is flagged and left out | Treated as 0, Fe550D would be quoted at the Fe500 price. The grade the base rate is for needs an explicit 0 as well. |

**Settings where "not set" has a safe meaning (not flagged):**

| Setting | Not set means | Why it's safe |
|---|---|---|
| Discount | No discount | Leaving it out makes the price higher, never cheaper. |
| Served / excluded | Not served (2.19) | Nothing is shown. |
| Grade sold in this area | Sold, if the seller has selected the grade (2.17) | Doesn't change the price. |
| Display unit | The seller's own pricing unit for the family | Doesn't change the price, only how it's shown, and it is the unit the seller himself thinks in. |

Size and piece weights cannot be missing: a size cannot be switched on until its weight is verified (2.10).

**Why:** A price that is too low is the worst kind of wrong. A buyer acts on it, and the seller either honours a loss or breaks his word. A price left out and flagged costs only a moment of the seller's attention. "Not set" and zero are already stored differently (2.21), so the engine can always tell them apart.

**For the setup screen:** zero must be one tap, never a typed workaround. For example:
- "I don't charge loading" sets loading to 0;
- "Same price in every area" sets the area difference to 0;
- "This is my base grade" sets that grade's premium to 0.

**How:** the lookups report "not set" as empty and an entered zero as 0. Saved checks prove both (`tests/database/size_figures.sql`). The rate engine must flag every empty value in the first table.

### 2.25 One publish is one action, for one or more product families
**Decision (2026-10-17):**
- **One action:** a publish is one action by a seller. Updating several ~~product families~~ **brands and product families (updated 2026-10-17, brands, 2.42)** together is one publish, so buyers get **one** notification (1.6).
- **Time:** set by the database at the moment of publishing, and can never be back-dated.
- **Basic rate:** must be above zero, exact to 4 decimal places (2.13), in the seller's unit for that family.
- **Who:** a seller publishes only for himself. An admin may publish on his behalf during setup, and the publish records that an admin did it, and which one.

**Why:** One notification per publish is what keeps the app from being muted (1.6). A publish time anyone could set would make the record worthless in a dispute.

### 2.26 A publish pins every version it used
**Decision (2026-10-17):** For each product family, a publish records the basic rate, its unit, the area-settings version in force, and the exact version of every chart those settings point to. So any past rate can be rebuilt exactly as it was shown, after any later change.
**How:**
- **Rebuilding:** the same lookups the rate engine uses take an "as published in publish X" option (`resolve_size_figures(..., publish)`; `resolve_area_settings` with that publish's area-settings version). Past and present are worked out by the same code, so they can never disagree.
- **Proven by a saved check:** a seller publishes ₹42,000, then changes his size chart and area settings. The publish still rebuilds to ₹42,000, Pune +200, 8mm +500.
- **Charts in use:** each chart a publish uses gets its "used since" mark, so it can never be switched off without a replacement (2.14).

### 2.27 A publish is never changed or removed; corrections are new publishes
**Decision (2026-10-17):**
- **Never altered:** nothing in a publish is ever changed or removed, not even with the master key.
- **Fixing a wrong rate:** publish again. The seller can mark the new publish as a correction, optionally naming the publish it corrects, so buyers can be told the earlier figure was wrong. The earlier publish stays in history, unchanged.
- **Own publishes only:** a correction can only name one of the seller's own publishes.

**Why:** 4.2: a record that can be rewritten cannot settle a dispute.

### 2.28 Current rates point to the latest publish; final rates are not pre-calculated
**Decision (2026-10-17):** For each seller ~~and product family~~ **, brand and product family (updated 2026-10-17, brands, 2.40)**, ALEE keeps a pointer to the latest publish. The rate engine works out each buyer's final figure from it when asked. Final rates for every area are not calculated in advance.
**Why:** Pre-calculating every area would multiply storage (4.1) and create a second copy of the truth that could drift from what the engine would say.

### 2.29 "Not quoting today" is a switch, not a publish
**Decision (2026-10-17):**
- **One tap, no publish:** a seller can switch ~~a product family~~ **a brand in a product family (updated 2026-10-17, brands, 2.40)** off with one tap, without publishing. Buyers then see "not quoting" and no figure.
- **Switching back on:** it stays off until the seller switches it back on, **or publishes that family**. Publishing switches it back on automatically, the same way publishing reopens a closed market, and that is recorded in the history at the publish time. *(Changed 2026-10-17: originally publishing left it off.)*
- **History:** every switch on or off is kept with its time and who made it.
- **Separate from sizes:** this is temporary and separate from not selling a size or grade at all (2.17).

**Why:** A seller who is out of stock for the day must be able to stop quoting at once. Leaving a stale rate up, or deleting his setup, would both be wrong.

### 2.30 Market open and closed
**Decision (2026-10-17):**
- **When it closes:** a product family's rate counts as closed after the seller's daily closing time (Indian time), or immediately if he presses "close market now".
- **Reopening:** publishing again reopens it.
- **History:** every early close is kept with its time and who did it.
- **After close:** the last published rate stays visible, marked closed, with the closing time.
- **Public:** whether a seller is open, closed or not quoting can be seen by anyone. It reveals no rate.

**How:**
- **One function:** `market_status` is the one place this is worked out (the "market status" engine in CLAUDE.md section 20).
- **Closing time:** the first daily closing time after the latest publish. So a rate published after today's closing time stays open until tomorrow's.
- **Closing time required (settled 2026-10-17):**
  - **Before the first publish:** a seller must have a daily closing time. The setup screen pre-fills **6:00 PM**, so accepting it is one tap. It is not filled in by the database, so every seller has actually accepted his own time.
  - **After publishing:** he can change it but never clear it, or his rate would never close.
- **Any moment:** it can be asked about any moment, which is how the daily close is tested.

### 2.31 Enquiries after close are allowed (note for the enquiry step)
**Decision (2026-10-17), nothing built yet:** a buyer may send an enquiry after a seller's market has closed. The enquiry must be marked **"received after close"**, and the buyer told the seller will respond when the market opens.

### 2.32 A refused publish says in plain words what to fix
**Decision (2026-10-17):** a product family can't be published without area settings, or while an area still points to a switched-off chart. In both cases publishing stops with a plain message naming the family, area and chart, so the seller knows exactly what to fix:

| Situation | Message |
|---|---|
| No area settings | "Choose where you sell TMT Bars before publishing." |
| An area's chart switched off | "Satara still uses 'Old TMT rates', which you switched off. Choose a chart for Satara." |
| A grade's own chart switched off | "Satara (Fe550D) still uses 'Old TMT rates', which you switched off. Choose a chart for Fe550D in Satara." |
| No closing time | "Set your daily closing time before your first publish." |
| No basic rate | "Enter your basic rate for TMT Bars." |
| A family he doesn't sell | "You don't sell MS Angles yet. Add it to your product families before publishing." |

**Why:** A seller who is stopped must be able to fix the problem in one step. A vague error at the moment of publishing is exactly what made the earlier version feel harder than WhatsApp. The wording is checked word for word by the saved checks.
**For later:** these messages are the first candidates for the single user-facing text file (CLAUDE.md section 11), so they can be translated into Marathi and Hindi.

### 2.33 Territory allocation is an offer the distributor accepts
**Decision (2026-10-17):**
- **What it is:** a manufacturer allocates an area to a distributor, for ~~one product family~~ **one brand he owns, in one product family that brand covers (updated 2026-10-17, brands, 2.43)**. The area can be any level: state, district, taluka or city.
- **Offer first:** it is only an offer until the distributor accepts. Until then it has no effect. He can also decline.
- **One distributor per area, per ~~family, per manufacturer~~ brand and family (updated 2026-10-17, brands, 2.43):** while one distributor holds an area, or has an open offer for it, no other distributor can be given it. Different families can go to different distributors: Satara TMT to one, Satara angles to another.
- **Who does what:** only the manufacturer offers. Only the distributor accepts or declines. Either side can end it. Admins can do any of these, and it is recorded that an admin did.

**Why:** A distributor takes on obligations in his area. An allocation he never agreed to would point buyers at someone who isn't expecting them.

### 2.34 The closer area wins, and the rate engine checks territory first
**Decision (2026-10-17):** if Satara district is allocated to one distributor and Karad taluka to another, a Karad buyer belongs to the second. The rate engine checks territory before exclusions and area settings (CLAUDE.md section 8).
**How:** `resolve_territory(manufacturer, family, buyer's area)` is the one lookup. It returns the allocation in effect closest to the buyer: to whom, which type, and for which area. It never returns a rate.

### 2.35 Two types: who sets the price
**Decision (2026-10-17), chosen by the manufacturer when allocating:**
- **Type A, "distributor sets the price" (`distributor_prices`):** in that area the manufacturer's rate is not shown. Buyers are pointed to the distributor, who publishes his own rates.
- **Type B, "manufacturer sets the price" (`manufacturer_prices`):** how brands like Tata or Apollo work. Buyers in that area see the manufacturer's own rate, tagged **"Authorised distributor for [area]: [distributor]"**. The distributor does not publish that brand's rate there.
  - **For the enquiry step (nothing built yet):** enquiries from a Type B area go to the distributor.

**Changing the type:** the manufacturer may change it while it is still an offer. Once accepted, the type is fixed; to change it, end the allocation and offer a new one, so the distributor always agrees to the arrangement in force.

### 2.36 Ending, history, and who sees what
**Decision (2026-10-17):**
- **Ending:** either side can end an allocation. The manufacturer's own rate then shows again in that area, if he serves it. Before it is accepted, the manufacturer can withdraw an offer.
- **Nothing is deleted:** every offer, type change, acceptance, decline, withdrawal and ending is kept with its time and who did it. An ended or declined allocation can never be revived. Its manufacturer, distributor, family or area can never be changed, not even with the master key. To change any of them, offer a new allocation.
- **Who sees what:**
  - **The manufacturer** sees his own allocations: who covers which area. He never sees anything about the distributor's rates or margin; the saved checks try every route.
  - **The distributor** sees allocations offered to him or held by him.
  - **Everyone:** that an allocation is in effect is public, because buyers will see "authorised distributor" tags and be pointed to distributors. Offers, declines and history stay between the two sides and admins.


### 2.37 Brands: ALEE keeps the list
**Decision (2026-10-17):**
- **ALEE's list:** ALEE keeps the brand list. A seller can request a missing brand, and an admin approves it, to prevent duplicate spellings. Old names and other spellings are kept for search, as with regions.
- **Regular:** an unbranded option called **"Regular"** exists for every product family. It is shown with the family's name, "Regular TMT" or "Regular Angles", and is never owned.
- **Families:** a brand can cover more than one product family.
- **Who sells:** any seller can sell any approved brand, even before its manufacturer joins ALEE.

**Why:** Distributors and retailers quote different rates for different brands of the same product. Without brands, a rate can't say what is being sold.

### 2.38 Brand ownership
**Decision (2026-10-17):**
- **Claiming:** a manufacturer claims a brand, and an admin approves the claim.
- **Owners:** one owner per brand; a manufacturer can own several.
- **Appointing distributors:** only the owner can appoint authorised distributors for it.
- **History:** every claim, approval and rejection is kept.

### 2.39 Factories
**Decision (2026-10-17):**
- **Separate accounts:** a brand can have several factories. Each is its own seller account, with its own rates, setup and closing time.
- **Linking:** a factory account must **accept** being linked to a brand, and can decline, or leave later. Every step is kept in history.
- **Coverage:** the owner decides which factory covers which area, **per brand and product family**, so a brand can serve TMT and angles in the same area from different factories. One factory per area, and the closer area wins.
- **What buyers see:** the rate from the factory serving their area. The brand appears as one brand.

**Why the factory must accept:** otherwise an owner could attach someone else's account and show that seller's rates under his brand.

### 2.40 Each brand a seller sells has its own setup
**Decision (2026-10-17):**
- **Brand line:** each brand a seller sells, in each product family, has its own setup:
  - basic rate;
  - grades and sizes;
  - area settings (size chart, loading, discount, premiums, areas);
  - "not quoting".

  This is called a **brand line**, for example *Bala Traders – Tata – TMT*.
- **Unit:** the pricing unit stays per product family, shared by all his brands in it.
- **Closing time:** stays per seller account.
- **Shared charts:** charts can be shared between brands; two brand lines can point at one chart.
- **Copying setup:** a new brand's setup can be copied from another of his brands in one tap. The copy points at the same charts.

**Why:** Brands differ, but are often similar. Sharing and copying keep a seller's work to a minimum without ever mixing two brands' rates.

### 2.41 Regular
"Regular" is one special brand covering every product family. It has no owner, no factories and no territory, and is shown as "Regular" plus the family's short name ("Regular TMT"). Everything set up before brands existed belongs to Regular.

### 2.42 Publishing stays four taps
**Decision (2026-10-17):**
- **Pre-filled:** all his brands are pre-filled from yesterday.
- **One move per family:** "move everything by ±₹X" is **one amount per product family**, never across families, because families may be priced in different units.
- **Confirm:** the last tap.
- **One notification:** one publish can cover many brands and families, and is one notification.

### 2.43 Territory is per brand
**Decision (2026-10-17):**
- **Per brand:** a manufacturer allocates **a brand he owns, for a family that brand covers** (replacing "a family he sells").
- **Type A:** the owner's factories' rate for that brand is not shown in that area; buyers are pointed to the distributor.
- **Type B:** the factories' rate is shown, tagged with the authorised distributor. **Only that distributor's rate for that brand in that area is hidden;** his other brands are unaffected.
- **Other sellers of the brand:** territory only affects the brand owner's factories and his appointed distributor. Other sellers of that brand keep showing their own rates.

### 2.44 How brands are added without breaking what works
**How (2026-10-17):**
- **Transition:** while brands are built in, every existing function treats "no brand given" as **Regular**. So the existing saved checks keep passing unchanged throughout.
- **Removing the shortcut:** in the final step it is removed, so no screen can ever save to the wrong brand by forgetting to name it. Every check is then updated to name its brand, and all must pass before the rate engine is built.

---

## 3. Regions

### 3.1 Four levels: state, district, taluka, city
**Why:** Taluka is where freight is actually priced. A district is too coarse, a village too fine. Sellers configure down to taluka; buyers register down to city.

### 3.2 Most specific area wins, working outward
**Why:** A seller sets one state figure and adds exceptions only where needed, instead of listing hundreds of cities.

### 3.3 Exclusions are stored explicitly
**Why:** Without them, a seller who sets "Maharashtra +₹200" would silently appear to serve districts 900km away that he cannot deliver to. One such enquiry damages trust in the rate itself.

### 3.4 Start small, grow as needed
**Decision:** States and districts are seeded. Talukas and cities are added as the business reaches them. Buyers can add a missing city; it waits for admin approval.
**Why:** India has over 600,000 villages, most with no steel trade. Growth will be watched area by area. Approval prevents "Kolhapur", "Kolapur" and "Kolhapur City" becoming three places.

### 3.5 Old names stay searchable
**Why:** Aurangabad, Osmanabad and Ahmednagar were renamed in 2023. Traders will use the old names for years.

### 3.6 Regions are never deleted
**Why:** Districts get redrawn. In December 2025 Goa created Kushavati from four South Goa talukas. Rate history must still make sense against the boundaries as they were.

### 3.7 Regions are always identified by ID, never by name
**Why:** Sangli is a district, a taluka and a city at once.

### 3.8 Other countries are not designed for yet
**Why:** The four level names are Indian. Expansion abroad would need country-specific levels, but tax, currency and payments are the harder part, and designing for markets not served adds daily complexity.

---

## 4. History

### 4.1 Settings are saved as versions
**Decision:** Changing a chart or area setting creates a new version. Each publish records which versions applied.
**Why:** An earlier design copied every area's final rate at each publish, writing roughly fifteen times more data. Versioning keeps history equally exact with far less storage.

### 4.2 Nothing in the trade record is deleted
**Why:** ALEE exists to be the record of what was quoted and agreed. A record that can be rewritten cannot settle a dispute. A wrong rate is corrected by publishing again; the wrong one stays, marked superseded.

---

## 5. Architecture

### 5.1 One Next.js project; screens never reach the database directly
**Why:** Keeping an API layer in between means a future move off Supabase changes one connection, not every screen. One project rather than two keeps setup and deployment simple for a solo build; the rule keeps the boundary real.

### 5.2 Supabase and Postgres
**Why:** ALEE's data is relational — sellers, areas, charts, subscriptions. Postgres handles that naturally, costs are predictable, and the data can move anywhere.

### 5.3 TypeScript
**Why:** The owner cannot read code fluently. TypeScript catches a whole class of errors — text where a price should be — before anything runs.

### 5.4 Web app wrapped for Android and iOS
**Why:** Profiles must open from a WhatsApp link. iOS is required for manufacturers, and one codebase serves web, Android and iOS.

### 5.5 Central machinery
**Decision:** Dates, money, rate calculation, permissions, text and settings each live in one place.
**Why:** The earlier version repeated logic in many places. If the confirmation screen and the buyer's screen calculate a rate separately, they will eventually disagree, and a seller who cannot explain a number to his customer stops trusting ALEE.

### 5.6 Engines are built and tested before screens
**Why:** A screen built before its engine ends up doing the calculation itself, which breaks 5.5.

---

## 6. Security and privacy

### 6.1 The database is the only real wall
**Why:** The app's public key can be extracted by anyone. Every rule must hold for someone who skips the app entirely and asks the database directly.

### 6.2 Phone numbers are private, and must be the person's own
**Why:** Contact details are what a competitor would harvest. A person can only record the number he verified at login, so nobody can sign up as someone else's firm.

### 6.3 Consent records can only be added to
**Why:** They are proof. Proof that can be edited or back-dated is worthless.

### 6.4 Actual transaction prices never feed averages without the seller's agreement
**Why:** The price a seller actually gave a buyer reveals his discounts. If that leaked, ALEE would be finished in this trade.

### 6.5 Admin reads are logged
**Why:** The person who can see every seller's rates will one day be an employee.

### 6.6 Payments never touch ALEE's servers, and are confirmed by the payment provider
**Why:** It avoids handling card data entirely, and stops anyone forging a "payment succeeded" message to unlock paid features.

### 6.7 Nothing is deleted when someone stops paying
**Why:** Deleting a trader's records over a lapsed payment would destroy trust faster than anything else.

---

## 7. Storage

### 7.1 Bills attach to orders, compressed and size-capped
**Why:** The order holds the real data; the bill is supporting paperwork. Uncompressed phone photos would make storage costs roughly ten times higher at scale, and files saved at full size can never be shrunk afterwards.

---

## 8. How work is done

- **Two databases.** Every change goes to alee-dev first. Mistakes cost nothing there.
- **Every database change is a file**, with a header explaining what and why. Nothing is set up by clicking, so anyone can rebuild the database and see its history.
- **A migration that has run is never edited.** Corrections are new migrations, so both databases always followed identical instructions.
- **Checks after every change**, including an ordinary user trying to see what he shouldn't.

---

## 9. Open questions

| Question | Notes |
|---|---|
| Account deletion vs the trade record | Deleting an account currently removes everything, **including his publishes** (nothing else can remove them). Once orders exist, the other party must keep his order history and bills. Likely answer: remove personal details, keep the trade record without the name. Consent proof may also need keeping for a period. Take legal advice before launch. |
| ~~Publishing requirements~~ | **Confirmed 2026-10-17, see 2.32:** no publish without area settings or while an area points to a switched-off chart, with a plain message saying what to fix. |
| ~~"Close market now" with no family named~~ | **Confirmed 2026-10-17:** closes every open family the seller deals in. |
| ~~No closing time set~~ | **Settled 2026-10-17, see 2.30:** a closing time is required before the first publish, pre-filled at 6:00 PM, and can't be cleared afterwards. |
| ~~Type B and "that brand's rate"~~ | **Settled 2026-10-17 by brands (2.37, 2.43):** brands are added before the rate engine. Type B hides only that distributor's rate for that brand in that area; his other brands are unaffected. |
| ~~Territory details~~ | **Confirmed 2026-10-17:** (1) ~~a manufacturer can only allocate a family he himself sells~~ **updated 2026-10-17 (2.43): a manufacturer can only allocate a brand he owns, for a family that brand covers**; (2) the type is fixed once accepted (2.35); (3) "everywhere" cannot be allocated, so the widest area is a state. |
| Public visibility of size differences and loading | Public for now; revisit. |
| Angle and channel weights | Unverified and switched off. Confirm weights, whether 25×6 and 32×3 are traded, and the usual length (assumed 6m). |
| Kushavati | Deferred. Add before any Goa talukas. |
| Freight, credit terms, minimum quantity | After Phase 1. Credit terms and minimum quantity probably attach to the buyer rather than the area. |
| ~~A size with no figure in a size chart~~ | **Resolved 2026-10-17, see 2.17.** Sellers select the sizes they offer. A selected size with no figure is an error, never zero: publishing flags it and leaves that size out until fixed. |
| Admins editing sellers' charts (proposed 2026-10-17) | Admins can create and change any seller's chart and copy templates for a seller, to match setting up the first sellers personally. Admin reads must also be logged (6.5) once the API layer exists. Confirm. |
| ~~Template copies keep the template's unit (proposed 2026-10-17)~~ | **Superseded 2026-10-17 by 2.18:** copies are converted into the seller's unit. Converting a seller's existing charts when he later changes his unit (2.8) is still to be built. |
| ~~A served city inside an excluded district~~ | **Settled 2026-10-17, see 2.21:** the more specific area wins, so the city is served. The setup screen shows it plainly (2.23). |
| ~~Grade size chart vs family size chart across levels~~ | **Settled 2026-10-17, see 2.21 and 2.22:** the closer area wins; at the same area the grade's chart is looked at first. In TMT a better grade is normally a premium on the shared size difference, so a grade's own chart is the exception. |
| ~~No loading chart anywhere for a buyer's area~~ | **Settled 2026-10-17, see 2.24:** missing loading is flagged, never zero. A seller who charges no loading says so with one tap. |
| Limits on chart figures (proposed 2026-10-17) | A flat discount cannot be negative. Loading and size figures may be any sign. Confirm whether loading should also be barred from going negative. |
