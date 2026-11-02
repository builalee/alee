# Demo setup guide

How to set up the manufacturer demo on **alee-dev**, from empty, in the order that works. Do this the day before the demo. Then follow `docs/demo-script.md` on the day.

- **Everything is created by signing up.** There is no sample data (decision 16.1).
- **Test numbers:** use the Supabase test phone numbers. Their codes are kept by the owner and are never written here.
- **One person per browser:** each account must be logged in on its own phone or browser. Otherwise, log out and log in again between steps.
- Screen and button names below are exactly as they appear in the app.

---

## The cast

| Who | Signs up as | District | Used for |
|---|---|---|---|
| **Admin** | your admin number | — | approvals |
| **Manufacturer** (e.g. Arya Steel) | Manufacturer | his plant district | owns the brand, publishes, client book |
| **Distributor** | Distributor | e.g. Satara | appointed Type B for that district; receives enquiries |
| **Buyer 1** | Retailer / buyer | the distributor's district (Satara) | sees the rate with the "Authorised distributor" tag; sends the enquiry |
| **Buyer 2** | Retailer / buyer | another district the manufacturer sells in, with a different difference (e.g. Kolhapur) | sees a different rate for the same product |

Each buyer sees rates only for **his own account's district**, so choose these districts carefully at sign-up.

---

## Step 1. Create the accounts

For the manufacturer, the distributor and both buyers:

1. Open the site and tap **Log in**. Enter the test number, tap **Send code**, enter the code and tap **Log in**.
2. On **Create your account**, fill in name, business name, **You are a** (the role above) and **Your district**. Tick both agreements, then tap **Create account**.

The manufacturer and distributor now show "waiting for ALEE's approval". Until approved, they work as retailers.

## Step 2. Approve the roles (Admin)

1. Log in with the admin number and tap **Admin**.
2. Under **Role requests**, tap **Approve** for the manufacturer and the distributor.

## Step 3. Business profiles (Manufacturer and Distributor)

Each of them: **Seller setup** → **Business profile**. Fill in business name and **Plant city (district)**. Choose **Public** and save.

The distributor needs this profile too, or he can't be appointed and can't receive enquiries.

## Step 4. The brand (Manufacturer, then Admin)

1. Manufacturer: **Seller setup** → **Brands you sell**.
   - If the brand is in the list: choose it and tap **Add brand**.
   - If not: under **Brand not on the list? Request it**, type the name and tap **Request brand**. Then the Admin approves it under **Brand requests**, and the manufacturer adds it.
2. Manufacturer: next to the brand, tap **I own this brand**.
3. Admin: under **Brand ownership claims**, tap **Approve**.

## Step 5. Grades, sizes and unit (Manufacturer)

**Seller setup** → under the brand, **Grades, sizes and unit**.
1. Choose **Tonne** or **Kg**. It can't be changed later in this version.
2. Untick any grade or size he doesn't sell, and save.

## Step 6. Grade premium, loading and districts (Manufacturer)

**Seller setup** → under the brand, **Grade premium, loading and areas**.
1. **Grade premium:** a figure for every grade. Tick **This is my base grade** on the grade his basic rate is for.
2. **Loading:** one figure, or tick **I don't charge loading**.
3. **Districts you sell in:** use **Add a district…** for each district, including the distributor's district and Buyer 2's district. For each, tick **Same as base rate** or enter how much it differs. Give Buyer 2's district a different figure from Buyer 1's, so the demo shows two different rates.
4. Save. Back on **Seller setup**, the brand should say **Ready to publish**. If it lists anything under "To fix before publishing", fix that first.

## Step 7. Daily closing time (Manufacturer)

**Seller setup** → **Daily closing time**. 6:00 PM is filled in; tap **Accept closing time**.

For the demo, choose a closing time **after the demo ends**. Otherwise enquiries are marked "Received after close".

## Step 8. Appoint the distributor (Manufacturer, then Distributor)

1. Manufacturer: **Seller setup** → **Distributors**. Under **Appoint a distributor**, choose the brand, the district (Satara), the distributor, and **Type B: I set the price**. Tap **Offer**.
2. Distributor: **Seller setup** → **Offers from manufacturers**. Tap **Accept**.

Only distributors approved by ALEE appear in the list (step 2).

## Step 9. The first publish (Manufacturer)

**Publish today's rates**. Enter the basic rate, tap **Next: check the rates**, check each district, then tap **Confirm and publish**.

The demo moves rates from this publish. **Publish the day before the demo**, so the morning screen opens with yesterday's rates ready to move. If you publish on the day itself, the rates show as locked: tap **Change today's rates** first.

## Step 10. Customers and follow-ups (Manufacturer)

**Client book** → **Add a customer**. Add two or three customers with a real-looking name, type and district. Give at least one a mobile number you can safely call, such as your own second phone.

On that customer's page, open **Add a follow-up**. Set the date to **the demo day**, add a note (e.g. "Ask about the slab order"), and tap **Save follow-up**. On the demo day it appears under **Today's follow-ups**.

---

## Check before the demo

- [ ] Buyer 1 → **Rates in my area**: the manufacturer's rate, with "Authorised distributor for Satara: [distributor]".
- [ ] Buyer 2 → **Rates in my area**: a different rate for the same grade and size.
- [ ] Manufacturer → **Client book**: the follow-up shows under Today's follow-ups on the demo day.
- [ ] Every phone is logged in as the right person, with the site open.
