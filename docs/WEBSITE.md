# CmdMD Website

The public landing page for CmdMD.

- **Live:** https://cmdmd.cmdspace.work
- **Source repo:** https://github.com/johnfkoo951/CmdMD-web
- **Local path:** `/Users/yohankoo/DEV/cmdmd-web/` (separate repo, *not* part of this app repo)

## What it is

A single static `index.html` built with the `cmdspace-web-builder` **Landing** template
(CMDSPACE v4.3 design system — Apple SF Pro × CMDS Green/Pink, light/dark + KO/EN toggles,
17 OG meta tags, round-logo favicon). Sections: Hero → The Idea → Features → How it works →
Screenshots → Keyboard shortcuts → Install → CTA.

## Screenshots are shared with this repo

The site reuses the **real app captures** in `docs/images/` (hero, `cmds-{light,dark}-{preview,split}`,
`demo.gif`) — copied into `cmdmd-web/assets/shots/`. They are genuine `CmdMD.app` window captures,
not mockups. To refresh them, recapture, then copy into **both** `CmdMD/docs/images/` and
`cmdmd-web/assets/shots/`, and redeploy.

## Deploy

```bash
cd /Users/yohankoo/DEV/cmdmd-web
./scripts/build-og.sh          # regenerate the 1200×630 OG image (Chrome headless), if OG changed
vercel deploy --prod --yes     # Vercel project "cmdmd"
```

**DNS:** Cloudflare zone `cmdspace.work` → CNAME `cmdmd → cname.vercel-dns.com` (DNS only).

## Updating content

Edit `cmdmd-web/index.html` directly. Download buttons point at
`https://github.com/johnfkoo951/CmdMD/releases/latest`, so they track new releases automatically —
only the hero eyebrow / OG version pill (`v1.4.6`) is hard-coded and worth bumping on a major release.
