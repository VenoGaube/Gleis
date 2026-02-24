# Gleis Launch Site

Static landing page + email waitlist form for app pre-launch, with an interactive web demo of the app screens.

## Demo Included

The page now includes an in-browser app preview with:

- `Train` tab: route selection, swap, type filters, pinning, reminder toggle, and delay simulation
- `Repeat` tab: direction toggle, weekday schedules, line/time setup
- `Settings` tab: notification toggles, delay-aware leave time, reminder lead time

To adjust demo routes/connections, edit `BASE_CONNECTIONS` in `launch-site/app.js`.

## 1. Configure Email Signup Endpoint

Open `launch-site/index.html` and replace:

`REPLACE_WITH_YOUR_FORM_ID`

in both places with your real form endpoint id. Example (Formspree):

`https://formspree.io/f/xabc123d`

The page submits `email` plus `source=gleis-launch-site`.

## 2. Run Locally

From repo root:

```bash
cd launch-site
python3 -m http.server 8080
```

Then open `http://localhost:8080`.

## 3. Deploy

Upload the contents of `launch-site/` to any static host (Netlify, Vercel static site, GitHub Pages, Cloudflare Pages, S3, etc.).
