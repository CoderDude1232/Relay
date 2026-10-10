# Screenshots

| File | Shown in | Source |
| --- | --- | --- |
| `hero-light.jpg` | light theme | a light-mode capture |
| `hero-dark.jpg` | dark theme | a dark-mode capture of the same conversation |
| `relay-logo-dark-ink.png` | light theme | black wordmark |
| `relay-logo-light-ink.png` | dark theme | white wordmark |

Both hero captures load on every visit, because the theme toggle can switch after load — a
`<picture>` with a `prefers-color-scheme` media query would only follow the OS and would break
the toggle. That's ~390 KB for the pair, so keep them compressed.

## The Dynamic Island

The simulator doesn't draw it, so it's **overlaid in CSS**, not burned into the captures —
`.hero-island` in `styles.css`, a black pill sized to the real device's proportions (125×37pt
on a 402pt-wide screen) and centred on the status bar clock.

It's black in both themes because it is on a real phone, which is why it vanishes against the
dark capture — exactly as it does in life.

**If you ever supply captures that already include the island, delete that `<span>` from
`index.html`** or you'll get two of them stacked.

## Replacing a hero

Shoot the **same conversation in both themes** so switching doesn't change what's being said.
Raw iPhone screenshot, no cropping and no mockup frame — the page adds the rounded corners and
the shadow. Then:

```bash
sips --resampleWidth 900 new.png --out tmp.png
sips -s format jpeg -s formatOptions 88 tmp.png --out hero-light.jpg && rm tmp.png
```

900px is 3x the largest size the hero displays, so nothing visible is lost. The current pair
came down from ~800 KB each to under 200 KB.

The conversation itself is scripted in `chat-script.md` at the workspace root, along with the
rules it follows — nobody mentions the app, timestamps all precede the status-bar clock, and
whoever holds the documents is the one attaching them.
