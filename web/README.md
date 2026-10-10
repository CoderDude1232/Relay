# Relay — website

Three static pages, one stylesheet, one small script. No build step, no dependencies,
no framework. Open `index.html` in a browser and it works.

```
index.html     landing page + waitlist
add/index.html /add/<handle>       — contact invite by username
c/index.html   /c/<token>          — contact invite by token
g/index.html   /g/<token>#<key>    — group invite; the fragment is a secret
download.html  release status, TestFlight slot, beta expectations
privacy.html   privacy policy
terms.html     terms of service
support.html   FAQ, contact, security disclosure
security.html  how Relay works: what the server sees, and where the encryption ends
source.html    open-source components, licences, and the AGPL source offer
compare.html   Relay vs WhatsApp, Signal, Telegram (dated; recheck periodically)
changelog.html user-facing what's new, by month
styles.css     shared stylesheet (all design tokens at the top)
site.js        waitlist form handling
images/        hero-light.jpg, hero-dark.jpg, and both logo inks
favicon.svg
og.png         1200x630 link preview image
fonts/         Schibsted Grotesk, self-hosted (one variable woff2 per subset)
_headers       Cloudflare/Netlify headers — sets the AASA content type
_redirects     rewrites /add/* to /add/ so any handle serves the invite page
.well-known/apple-app-site-association
```

## Merged from CoderDude1232/relay-web

`add/`, `_headers`, `_redirects` and `.well-known/` came from the existing repo and are
**deployment-critical** — don't drop them:

- `apple-app-site-association` declares the universal link for
  `2P24M8G2CJ.com.morgandaly.RelayMessenger` over `/add/*`. It must be served as
  `application/json`, which is what the `_headers` entry does. Break either and invite links
  stop opening the app.
- `_redirects` rewrites `/add/anything` to `/add/index.html` with a 200, not a 302 — the path
  has to survive so the page can read the handle out of it.

## Deep links

Three routes, each a universal link into the app with a web page behind it for people who
don't have the app yet. All three are declared in `apple-app-site-association` and given a
catch-all 200 rewrite in `_redirects` — the path has to survive so the page can read the token
out of it.

| Route | Deep link |
| --- | --- |
| `/add/<handle>` | `relay://add/<handle>` |
| `/c/<token>` | `relay://contact/<token>` |
| `/g/<token>#<key>` | `relay://join/<token>#<key>` |

Tokens are validated against `^[A-Za-z0-9_-]{1,128}$` and never displayed — they only go into
the deep link.

### The group key is a secret

`/g/`'s fragment is the group's decryption key. Browsers never put a fragment on the wire, and
nothing in the page changes that: it's read from `location.hash`, checked against the URL-safe
base64 alphabet (`A-Za-z0-9-_`, no padding), and written verbatim into the button's `href`.
It is never rendered, never stored, and never given to anything that makes a request.

**Don't add analytics, error reporting, or any third-party script to these pages.** Most of
them capture `location.href`, which would ship the key straight out. Verified with a
distinctive key in the fragment: it appeared in no request URL, no visible text, and nowhere
in the document except the `relay://` href.

The group's name isn't shown, because it's encrypted with that key and is only readable in the
app. A link arriving without a usable key shows a short notice instead of a dead button.

`_headers` sets `Referrer-Policy: no-referrer` and `X-Robots-Tag: noindex` on all three invite
paths, so the token in the path isn't handed to third parties or indexed.

The one remaining cross-origin request on these pages is **Google Fonts**. Self-hosting the
font matters more here than elsewhere — see the deploy list above.

The invite pages use **root-absolute asset paths** (`/styles.css`, `/images/…`) for that
reason: relative paths would resolve against `/add/ethan` and break for some URL shapes.

The handle is read from the path and validated against `^[A-Za-z0-9_.-]{1,30}$` before being
written to the page, and it's inserted with `textContent` rather than `innerHTML`. Anything
else is ignored and the page falls back to "Someone wants to chat." That path is attacker-
controlled — anyone can send a link — so keep the validation if you touch it.

The old repo's `privacy.html` and `terms.html` are superseded by the ones here.

## Before you deploy

**1. Wire up the waitlist.** Set `WAITLIST_ENDPOINT` at the top of `site.js` to any URL
that accepts a `POST` with `{"email": "..."}` — Formspree, Buttondown, Listmonk, a
Cloudflare Worker. Left empty, the form tells the visitor it isn't live and points them
at an email address, rather than silently dropping their address.

**2. The legal pages name Ethan Daly, operating from Queensland, Australia**, with the terms
governed by Queensland law. No placeholders left. Four
things still worth knowing:

- **There's no postal address on the site, on purpose.** An email contact point is generally
  what an Australian Privacy Principles policy needs. But if you send the waitlist email to
  anyone in the US, CAN-SPAM requires a valid **physical postal address** in commercial email —
  so that email, not this site, is where the gap would show. A PO Box or a virtual office
  solves it without publishing where you live.
- **App Store Connect will want a real address** for the developer account. That's private to
  Apple and separate from anything here.
- **Host log retention is written as 30 days.** Change it to whatever your host actually does;
  right now it's a sensible default, not a checked fact.
- **"Where your data is" doesn't name your host.** APP 8 wants overseas disclosures identified.
  The section is written to be true either way, but once you know who hosts the servers and in
  which country, name them there — it's a stronger clause for it.
- **The Apple section in the terms is required boilerplate**, not optional prose. If you use a
  custom EULA on the App Store it has to be at least as protective as Apple's minimum terms.
  Don't trim that list.

**These are drafts, not legal advice.** They're written plainly and they match what the rest of
the site claims, but have someone qualified read them — especially the liability section, the
governing-law clause, and whether you want to hold yourself to the Privacy Act voluntarily.
(Australian businesses under about A$3M turnover are often outside it; for a privacy product,
opting in reads better, and the policy is written as though you have.)

**3. The hero is a pair** — `images/hero-light.jpg` and `hero-dark.jpg`, one per theme, both
referenced directly from `index.html`. See `images/README.md` to replace them. The feature tiles are text only — an earlier version had a
screenshot in each and they were dropped.

**4. Confirm two things the old repo asserted.** Its legal pages were written from the
implementation and are more reliable than anything drafted here, but they may be stale — they
said no email is collected, which is out of date. Two claims of theirs are now on this site and
need a check before deploy:

- **Attachments held up to 30 days.** In `privacy.html` under "Your messages". If the real
  window differs, change it — a retention period is the sort of thing people hold you to.
- **A push token is stored per device.** Also in "Your account". Correct if the app rotates or
  unlinks them.

Deliberately *not* on the site, pending confirmation: the Signal Protocol (PQXDH + Double
Ratchet), TLS certificate pinning, and the SQLCipher local database keyed from the Secure
Enclave. All three are strong trust signals and all three are in the old repo's privacy page —
worth adding once you're confident they'll still be true at launch.

**5. Check every factual claim.** The feature list — calls, groups, media, disappearing
messages — is confirmed, as is email sign-up. The privacy claims aren't: nothing kept after
delivery, no record of who you talked to, no contacts, no analytics SDK, iOS 17+ all came from
the brief rather than the code. Run `claims-prompt.md` (one directory up) against the repo.

The riskiest one is **"who you were talking to"** on the purple section. With email accounts,
a table linking sender to recipient is the easy thing to end up with by accident. Verify it
before launch or cut that line.


## Deploying

Drag the folder onto [Netlify Drop](https://app.netlify.com/drop), or:

```bash
npx vercel deploy --prod
```

## Turning on TestFlight

`download.html` has the slot ready. Find the comment block near the top — delete the
`<p class="btn-off">TestFlight — not open yet</p>` beneath it and put a real link in its place:

```html
<a class="btn" href="https://testflight.apple.com/join/XXXXXXXX">Join the TestFlight beta</a>
```

Then update the **TestFlight** row in the "Where things stand" table below it, and the
`Not submitted` / `Not open` rows as those change. That table is the one thing on the site
that goes stale on its own — it's worth a look whenever the status changes.

## Brand assets

The nav and footer carry the **wordmark** as the whole lockup — no separate "Relay" text
beside it. Both inks ship, and CSS shows one per theme:

| File | Wordmark | Shown in |
| --- | --- | --- |
| `images/relay-logo-dark-ink.png` | black `#12090F` | light |
| `images/relay-logo-light-ink.png` | white | dark |

Both use the same magenta bolt. (An earlier light-ink version had an amber bolt; the current
one doesn't, which is what makes a single accent colour work across both themes.)

The swap is `.brand .logo-on-light` / `.logo-on-dark`, scoped to the container on purpose —
`.brand img` is (0,1,1) and would out-specify a bare `.logo-on-dark` (0,1,0), leaving both
images rendered. In light mode that shows as a stray magenta bolt beside the wordmark, since
the white one's letters are invisible on white.

**The supplied SVGs still aren't used.** Their wordmark is live `<text>` in Archivo 800 rather
than outlined paths, so anywhere Archivo isn't loaded it silently falls back to Helvetica and
the letterforms change. An `<img src="*.svg">` renders with no access to the page's webfonts,
so that fallback would happen here. Convert the text to outlines and the SVGs become the
better asset — sharper at any size, and only ~700 bytes of drawing (the 8.2 KB is C2PA
metadata that strips out).

`favicon.svg` is the bolt alone on `#12090F` with the same gradient — vector and exact, since
the bolt is a polygon rather than text. It suits both themes, so it doesn't swap.

## Dark mode

Three states, not two. With nothing stored the OS preference decides and the page keeps
following it; clicking the toggle writes an explicit choice to `localStorage` under
`relay-theme`, which then wins until it's cleared.

The CSS follows that shape — only tokens change, never component rules:

```css
:root { /* light */ }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { /* dark */ } }
:root[data-theme="dark"] { /* dark again, so the toggle beats a light OS */ }
```

A small script in each `<head>` applies a stored choice **before first paint** — without it
the page renders light then snaps to dark. `site.js` re-applies it on load as well, so the
toggle still works if the markup is ever embedded without that snippet.

The toggle icon shows the theme you'd switch *to*: a moon while you're in light.

The hero's Dynamic Island is a CSS overlay (`.hero-island`), not part of the captures — see
`images/README.md`.

**The wordmark and the hero screenshot both swap with the theme.** Both swaps are
container-scoped (`.brand .logo-on-dark`, `.hero-shot .on-dark`) because the sizing rules above
them — `.brand img`, `.hero-shot img` — are (0,1,1) and would out-specify a bare class, leaving
both images rendered at once.

Two things that behave differently in dark:

- **Hover goes deeper, not brighter.** `--magenta-deep` is `#9C0CAB` in dark rather than
  `#7E0A8A`, but it's still darker than the base. Brightening on hover drops white-label
  contrast to 3.7:1 and fails.
- **Links take the gradient's bright stop**, `#F63BFF`, which is 6.5:1 on the dark ground.
  `--magenta-ink` `#A50FB4` would be unreadable there.

Dark pairs were checked too: body 17.3:1, secondary 9.6:1, tertiary 5.3:1, links 6.5:1 on the
ground and 5.9:1 on cards. Nothing below 4.5.

### Palette

Taken from the logo. The two magentas are the literal stops of the bolt's gradient; the ink is
the wordmark's own black.

| Token | Hex | Use |
| --- | --- | --- |
| `--magenta` | `#C611D6` | buttons, the full-bleed band, focus rings — the accent |
| `--magenta-bright` | `#F63BFF` | the gradient's bright stop; favicon only so far |
| `--magenta-deep` | `#7E0A8A` | hover / pressed |
| `--magenta-ink` | `#A50FB4` | magenta *text* on paper — links, eyebrows |
| `--ink` | `#12090F` | body text in light — and the page ground in dark |

Surfaces are tokenised as `--page` (the ground) and `--surface` (cards, inputs) so they can
invert. Don't reintroduce a `--white` token; it can't mean anything sensible in dark.

**Every piece of text on the magenta band is pure white, with no opacity.** White on `#C611D6`
is 4.72:1 — it clears AA, but only just, so any tint or `opacity` below 1 drops under 4.5 and
fails. If you need a second level of emphasis there, use size or weight, never transparency.
Hierarchy in the two-column list comes from the headings for exactly this reason.

Every pair was checked: body 19.6:1, secondary 9.9:1, tertiary on grey 4.6:1, links 6.3:1 on
paper and 5.7:1 on grey, white on button and band 4.7:1, hover 9.1:1. Nothing below 4.5.

If the band ever reads too loud at full width, `#9C0CAB` is the same hue a few steps down and
gives white text 6.9:1 — but it reads noticeably more purple than the logo.

## Fonts

Schibsted Grotesk is **self-hosted** — nothing is fetched from Google. It's a variable font, so
one file per subset covers every weight the site uses (400–700), declared with
`font-weight: 400 700`. Latin is preloaded; latin-ext loads only if a character needs it.

Don't reintroduce the Google Fonts `<link>`. The invite pages carry a token in the URL and, for
`/g/`, a secret in the fragment — a third-party request from those pages is the one thing worth
avoiding, and it was the last one left.

## The link preview image

`og.png`, 1200×630, on the brand black with the magenta bolt. Referenced from the landing page
and from all three invite pages, since those are what people actually paste into iMessage,
Discord and Slack.

The invite pages deliberately have **no `og:url`**. A preview crawler fetching the page is
fine — fragments never leave the browser, so the group key is never in what it fetches — but
there's no reason to put the token into metadata as well.

It was built by rendering `og.html` with `qlmanage` and cropping the result. If you rebuild it,
note that qlmanage outputs a square and renders the content slightly low: the working command
was `sips -c 630 1200 --cropOffset 424 0`.

## Voice

Write like an established product, not a startup asking permission. No volunteering that
Relay is new, unreviewed, or unproven — none of that helps a reader decide, and it costs
trust on the way past.

That changed three things, none of which changed a fact:

- The limits section is now **"Where the encryption ends"** — the same boundary, stated as a
  security model rather than a confession. "At your screen", "at the other person" are facts
  every messenger shares; framing them as Relay's shortcomings was the error.
- The download page leads with **"Coming to iPhone"** rather than "Not yet."
- The support FAQ's "How do I know you're telling the truth?" is gone. A product that asks
  that of itself answers it badly by definition.

**What stays off the site regardless:** user counts, testimonials, ratings, press logos,
"trusted by" anything, or any suggestion the code has been externally audited. Those are
claims of fact, and inventing them is the one thing that would actually destroy trust — and
for a privacy app it's the claim people would check first. Confidence in the writing is free;
fabricated proof isn't.

The "Where things stand" table on the download page stays accurate as status changes. It's
the one place the site commits to a fact that goes stale.

## Navigation## Fonts

Schibsted Grotesk is **self-hosted** — nothing is fetched from Google. It's a variable font, so
one file per subset covers every weight the site uses (400–700), declared with
`font-weight: 400 700`. Latin is preloaded; latin-ext loads only if a character needs it.

Don't reintroduce the Google Fonts `<link>`. The invite pages carry a token in the URL and, for
`/g/`, a secret in the fragment — a third-party request from those pages is the one thing worth
avoiding, and it was the last one left.

## The link preview image

`og.png`, 1200×630, on the brand black with the magenta bolt. Referenced from the landing page
and from all three invite pages, since those are what people actually paste into iMessage,
Discord and Slack.

The invite pages deliberately have **no `og:url`**. A preview crawler fetching the page is
fine — fragments never leave the browser, so the group key is never in what it fetches — but
there's no reason to put the token into metadata as well.

It was built by rendering `og.html` with `qlmanage` and cropping the result. If you rebuild it,
note that qlmanage outputs a square and renders the content slightly low: the working command
was `sips -c 630 1200 --cropOffset 424 0`.

## Voice

Write like an established product, not a startup asking permission. No volunteering that
Relay is new, unreviewed, or unproven — none of that helps a reader decide, and it costs
trust on the way past.

That changed three things, none of which changed a fact:

- The limits section is now **"Where the encryption ends"** — the same boundary, stated as a
  security model rather than a confession. "At your screen", "at the other person" are facts
  every messenger shares; framing them as Relay's shortcomings was the error.
- The download page leads with **"Coming to iPhone"** rather than "Not yet."
- The support FAQ's "How do I know you're telling the truth?" is gone. A product that asks
  that of itself answers it badly by definition.

**What stays off the site regardless:** user counts, testimonials, ratings, press logos,
"trusted by" anything, or any suggestion the code has been externally audited. Those are
claims of fact, and inventing them is the one thing that would actually destroy trust — and
for a privacy app it's the claim people would check first. Confidence in the writing is free;
fabricated proof isn't.

The "Where things stand" table on the download page stays accurate as status changes. It's
the one place the site commits to a fact that goes stale.

## Navigation

The nav carries **product** links only — Features, What we store, Limits (anchors on the
landing page) and Download. **Legal and support live in the footer**: privacy policy, terms,
support, contact.
An earlier version had Privacy in both places pointing at two different destinations (the
marketing section vs. the policy), which is why the section id is now `#storage`.

If you add a Terms of Service, it belongs in the footer beside the privacy policy — the App
Store will want a link to one.

## Design notes

Modelled on an Apple product page: centred composition, large type, full-bleed sections that
alternate white / grey / brand purple, and real product imagery doing the selling.

- All tokens live in `:root` at the top of `styles.css`.
- The hero headline runs to ~84px. That scale is the point — don't shrink it.
- **The hero has two layouts.** Below 72rem (1152px) it's a centred stack: copy, then the
  phone underneath. Above it, a two-column grid — copy left, phone right, left-aligned. A
  single centred column at 1920px left the page looking empty either side. Everything below
  the hero stays centred at all widths.
- The phone scales with the viewport: `clamp(15rem, 22vw, 21rem)`. It was pinned at 280px,
  which shrank into the page on a large screen.
- **Purple is used once, at full bleed**, for the privacy section. That single block is the
  only saturated colour on the page, which is what makes it land. Adding purple elsewhere
  weakens it.
- Rounded feature tiles on grey, generous radius. Apple uses exactly this; it's appropriate
  here because the reference is explicit.
- Feature tiles are **text only** and sized by their content. They previously held cropped
  screenshots; the crops read as coloured blobs rather than phones, so they came out.
- There are **no fake device mockups**. An earlier version drew an iPhone in CSS with an
  invented conversation, and it read as fake. The hero is a real capture; the rounded frame and
  shadow come from CSS, which is what makes a flat screen capture read as a device.

## Account model — changed

Relay uses **email sign-up** today, with phone numbers planned later. An earlier version of
this site claimed no account, no phone number, and no account recovery. All of that is
corrected across the three pages. When phone sign-in ships, `privacy.html` has a paragraph
under "Your account" that needs updating before the feature does.
