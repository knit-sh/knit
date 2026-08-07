# knit.sh website

This directory holds the source of the Knit landing page served at the root of
**https://knit.sh**. The Sphinx documentation is served under
**https://knit.sh/docs**.

## Layout

```
web/
  index.html            landing page (hero + scroll narrative); the
                        data-snippet="FILE:MARKER" placeholders are filled at
                        build time from the doc-tested code samples
  styles.css            landing-page styles (single source of the brand palette)
  main.js               IntersectionObserver scroll-reveal (reduced-motion aware)
  knit-logo-dark.svg    symlink -> ../docs/source/_static/knit-logo-dark.svg
  knit-arrow-dark.svg   symlink -> ../docs/source/_static/knit-arrow-dark.svg
  knit-logo-simple.svg  symlink -> ../docs/source/_static/knit-logo-simple.svg
                        (favicon)
  CNAME                 "knit.sh" (keeps the custom domain across deploys)
  README.md             this file
```

## Building locally

```
make web
```

This rebuilds the Sphinx docs, then assembles the full deployable tree into
`web/build/site/` (git-ignored):

- copies `web/`'s static assets (dereferencing the logo/arrow symlinks),
- runs `maint/build-landing.py` (via the docs virtualenv, which ships Pygments)
  to fill each snippet placeholder in `index.html` with the matching
  `# START/# END` region extracted from `docs/source/_code/*.sh`, highlighted
  with a brand-colored Pygments theme whose colors are read from `styles.css`,
- copies the Sphinx build into `web/build/site/docs/`.

Open `web/build/site/index.html` to preview the site exactly as it is served.

## Deployment

`.github/workflows/docs.yml` runs `make web` and uploads `web/build/site` as the
GitHub Pages artifact. Because a `CNAME` file is present, the project-pages site
is served at the apex domain, so `knit.sh/` (landing) and `knit.sh/docs/` (Sphinx)
resolve without the `/knit/` project path prefix — no separate
`knit-sh.github.io` repository is needed.

## DNS setup (one-time, at the registrar)

GitHub Pages cannot set these records; the domain owner configures them at the
registrar that hosts `knit.sh`.

1. **Apex `knit.sh`** — point it at GitHub Pages, either:
   - four `A` records to GitHub's Pages IPv4 addresses:
     `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`,
     and (recommended) the four `AAAA` records:
     `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`,
     `2606:50c0:8003::153`; **or**
   - a single `ALIAS`/`ANAME` record to `knit-sh.github.io` if the registrar
     supports apex flattening.
2. **Optional `www.knit.sh`** — a `CNAME` to `knit-sh.github.io`.
3. In the repository **Settings → Pages**, set the custom domain to `knit.sh`
   and, once the certificate is issued, enable **Enforce HTTPS**.

Verify GitHub's current Pages IPs against
<https://docs.github.com/pages/configuring-a-custom-domain-for-your-github-pages-site>
before entering them, in case they change.
