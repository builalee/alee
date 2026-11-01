# ALEE — Pre-launch checklist

**Mandatory (docs/decisions.md 15.3).** ALEE does not launch until every box is ticked. Next to each tick, write the date and who checked it.

No prices or amounts belong in this file.

---

- [ ] **No test phone numbers and no placeholder SMS settings on live**
  - **How to check:**
    1. In the Supabase dashboard for The Alee App, open Authentication → Sign In / Providers → Phone.
    2. Confirm Test Phone Numbers and OTPs is empty.
    3. Confirm a real SMS provider is set up, and send a real code to a real phone.

- [ ] **Uptime and error alerts reach the owner's phone**
  - **How to check:**
    1. Take the preview site down on purpose (or point the uptime monitor at a page that doesn't exist).
    2. Confirm an alert arrives on the owner's phone within minutes.
    3. Cause a deliberate error in the preview, and confirm the error alert arrives too.

- [ ] **Live database on Supabase Pro, with daily backups, and one restore actually tested**
  - **How to check:**
    1. In the Supabase dashboard for The Alee App, confirm the plan is Pro.
    2. Confirm daily backups are listed.
    3. Restore one backup into a separate test project (never over live).
    4. Open the restored copy and confirm its data is there.
    5. Write down the date of the test.

- [ ] **Emergency switches work** (hide a rate, pause new sign-ups, maintenance banner)
  - **How to check:**
    1. As an admin on the preview, use each switch.
    2. Hidden rate: confirm a buyer's screen stops showing it at once.
    3. Paused sign-ups: confirm a new sign-up is refused with a plain message.
    4. Maintenance banner: confirm it appears.
    5. Switch each one back.
    6. Confirm each use is recorded with who, when and why.

- [ ] **One-click rollback rehearsed**
  - **How to check:**
    1. Deploy a harmless change to the preview.
    2. Use Vercel Instant Rollback to return to the previous version.
    3. Confirm the old version is back.
    4. Time it, and write down the steps.

- [ ] **Offline saved-rates screen works on a real phone**
  - **How to check:**
    1. On a real Android phone, open the app and load rates.
    2. Switch on airplane mode and reopen the app.
    3. Confirm the saved rates show, clearly marked with when they were saved.

- [ ] **Builds meet current store rules:** Capacitor 8; Android API 36; Xcode 26 (when the iPhone app starts)
  - **How to check:**
    1. In the project, confirm the Capacitor version and the Android target API level.
    2. Upload a test build to the Google Play internal testing track, and confirm no target-level warning.
    3. For iPhone (Phase 1.1), confirm the build is made with Xcode 26 and accepted by App Store Connect.
  - *Checked 2026-11-01: Google Play requires API 36 for new apps and updates from 31 August 2026, and Apple has required Xcode 26 since 28 April 2026. Store rules change every year; check them again just before launch.*

- [ ] **GitHub Dependabot and security alerts on; Supabase security advisor shows no warnings**
  - **How to check:**
    1. In the GitHub repository, open Settings → Code security, and confirm Dependabot alerts and security updates are on.
    2. In the Supabase dashboard (live and alee-dev), open the Security Advisor and confirm it shows no warnings.

- [ ] **Spending caps set on Supabase, Vercel and the SMS provider**
  - **How to check:** in each account's billing settings, confirm a spending cap or alert is set, and that a warning email reaches the owner.

- [ ] **Copies of all keys kept in a password manager, outside the laptop**
  - **How to check:** open the password manager on a different device (for example the owner's phone), and confirm every key for alee-dev and The Alee App is there, along with the SMS provider and any other service keys. Then confirm that losing the laptop would lose no key.

- [ ] **Two-step login on every account, with recovery codes kept offline** (GitHub, Supabase, Vercel, Google Play, domain)
  - **How to check:**
    1. For each account, sign out and back in, and confirm a second step is asked for.
    2. Confirm the recovery codes are printed or written down and kept somewhere offline, not on the computer.

- [ ] **Two or three vetted hourly freelancers on file**
  - **How to check:** a short list kept outside the repository, with name, contact, the skills checked (Supabase/Postgres, Next.js, Capacitor), and a small paid trial task each has completed.
