# CourtShare London — going live

Three pieces: a Supabase project (database + auth + realtime), the schema
in `supabase-schema.sql`, and the client in `courtshare-supabase.html`.

## Before you start: the one real cost in this stack

Phone number verification (SMS OTP) is not free. Supabase doesn't send SMS
itself — you connect a third-party SMS provider (Twilio, MessageBird, or
Vonage) in your Supabase project's Auth settings, and that provider charges
per text (roughly £0.03–0.08/SMS with Twilio, UK numbers). For a small
community board this is genuinely cheap — a few pounds a month — but it's
not zero, and Twilio requires you to create an account and add a payment
method before it'll send anything. Budget 20–30 minutes for this step
specifically; it's the fiddliest part of the whole setup.

If you'd rather avoid SMS costs entirely for now, Supabase also supports
WhatsApp OTP via Twilio's WhatsApp Business API, or you could fall back to
email-based magic links instead of phone — but since the entire point of
this app is verifying the WhatsApp number people will actually message on,
phone OTP is the right call once you're ready to spend the £5–10/month.

## 1. Create the Supabase project

1. Go to supabase.com, sign up, and create a new project (pick a region
   close to London, e.g. `eu-west-2` if available).
2. Wait for provisioning (~2 minutes).

## 2. Run the schema

1. In Supabase Studio, open **SQL Editor → New query**.
2. Paste the entire contents of `supabase-schema.sql` and click **Run**.
3. Check **Table Editor** — you should see `venues` (pre-populated with
   the 8 real Better/GLL badminton venues), `profiles`, `slots`,
   `slot_members`, `slot_reports`.

## 3. Enable phone auth

1. **Authentication → Providers → Phone**. Toggle it on.
2. You'll be asked for an SMS provider. Pick **Twilio** (most common):
   - Create a free Twilio account at twilio.com.
   - Buy a phone number capable of sending SMS (a few pounds, or free
     trial credit to start).
   - Copy your Twilio **Account SID**, **Auth Token**, and the phone
     number you bought into Supabase's Phone provider settings.
3. Save. Supabase will now actually send real text messages when the app
   calls `signInWithOtp`.
4. **While testing**: Twilio trial accounts can usually only text numbers
   you've manually verified in the Twilio console — add your own number
   there first, or you'll get silent failures.

## 4. Get your API keys

**Project Settings → API**. You need:
- **Project URL** (looks like `https://abcdefgh.supabase.co`)
- **anon public** key (long JWT string — this one is safe to put in
  client-side code; it's designed to be public, since RLS is what
  actually protects the data, not secrecy of this key)

## 5. Configure the client

Open `courtshare-supabase.html` and edit the top of the `<script
type="text/babel">` block:

```js
const SUPABASE_URL = "https://abcdefgh.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...";
```

The app will show a plain "not configured" message if you forget this
step, rather than failing silently.

## 6. Test locally

Just open `courtshare-supabase.html` directly in a browser (double-click
it, or `python3 -m http.server` and visit it) — unlike the old
artifact-storage version, this one doesn't need Claude's runtime at all
anymore. It talks straight to your Supabase project over the internet.

Try the two-browser test from before: sign in with your real phone number
in one browser, post a slot, then open the same file in an incognito
window, sign in with a *different* phone number (or the Twilio-verified
test number), and join it. You should see it update within a second or two
via realtime — no polling delay.

## 7. Deploy it somewhere real

This is a static HTML file — no build step, no server needed. Pick one:

- **Netlify** (easiest): go to app.netlify.com, drag the single
  `courtshare-supabase.html` file (rename it to `index.html`) onto the
  deploy area. You get a live URL in seconds. Free tier is plenty for this.
- **Vercel**: similar — `vercel deploy` from a folder containing the file
  as `index.html`, or drag-and-drop via their dashboard.
- **GitHub Pages**: push the file (as `index.html`) to a repo, enable
  Pages in repo settings, done.

Any of these gives you a real `https://` URL you can share with the
badminton community — no dependency on Claude's artifact environment at
all from this point on.

## What's structurally different from the old version

- **Identity is a verified phone number**, not a typed-in name. Nobody can
  register the same number under two names, because Supabase Auth ties
  one phone number to exactly one account.
- **The double-booking race condition is closed at the database level** —
  a Postgres trigger locks the row during a join, so two people can't both
  take the last spot even if they click at the same instant.
- **WhatsApp numbers never leave the database** until a Postgres function
  confirms server-side that the slot is full *and* the requester is a
  member — this can't be bypassed by editing the page's JavaScript.
- **Updates push via Realtime** instead of polling every 6 seconds.

## Reasonable next steps once this is running

- Add a "my slots" view (slots you've posted or joined) — currently you
  have to remember which venue to check.
- Rate-limit OTP requests (Supabase has some built-in throttling, but
  worth checking Auth → Rate Limits if people start hammering "send code").
- If it grows past a few dozen active slots, consider paginating
  `get_venue_board` rather than returning everything at once.
