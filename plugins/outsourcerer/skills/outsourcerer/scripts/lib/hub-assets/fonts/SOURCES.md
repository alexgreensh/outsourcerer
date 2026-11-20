# Vendored fonts — provenance

Every file here is an official, pre-subset woff2 as served by Google Fonts
(`fonts.gstatic.com`, resolved through the `fonts.googleapis.com/css2` API with
a Chrome user agent). No local subsetting or conversion was done. Licences are
copied verbatim from the upstream repos. SHA-256 values below are of the exact
bytes on disk; verify with `shasum -a 256 <file>`.

## Poppins (latin subset)

Upstream: Indian Type Foundry / Poppins, mirrored at
`github.com/google/fonts/tree/main/ofl/poppins` — SIL OFL 1.1
(`Poppins-OFL.txt`, sha256
`6be04893d770899a015649c7aa3b582f871b272f8747a92b78b17c3e5c8b2573`).
Retrieved via
`https://fonts.googleapis.com/css2?family=Poppins:wght@400;500;600;700&display=swap`
(latin unicode-range block).

| File | Weight | Download URL | SHA-256 |
|---|---|---|---|
| `poppins-400.woff2` | 400 | `https://fonts.gstatic.com/s/poppins/v24/pxiEyp8kv8JHgFVrJJfecnFHGPc.woff2` | `3dc5d0c52428fe1696264907a1054ebbaac07f8cbe45832c105f819c2ae397c0` |
| `poppins-500.woff2` | 500 | `https://fonts.gstatic.com/s/poppins/v24/pxiByp8kv8JHgFVrLGT9Z1xlFd2JQEk.woff2` | `289e0afc8be731a86822349e54557296f145926496bd2138db1bac0db77f77a2` |
| `poppins-600.woff2` | 600 | `https://fonts.gstatic.com/s/poppins/v24/pxiByp8kv8JHgFVrLEj6Z1xlFd2JQEk.woff2` | `872e862918591a9e824dc03ed92f05729435ffbb8ebbb10eff7eda26592b1798` |
| `poppins-700.woff2` | 700 | `https://fonts.gstatic.com/s/poppins/v24/pxiByp8kv8JHgFVrLCz7Z1xlFd2JQEk.woff2` | `197a3cbd7290c242c5c765268cdd69a9a39867fdc80cd13071f243a81c56fb76` |

## Noto Sans Hebrew (hebrew subset)

Upstream: The Noto Project, `github.com/notofonts/hebrew`, mirrored at
`github.com/google/fonts/tree/main/ofl/notosanshebrew` — SIL OFL 1.1
(`NotoSansHebrew-OFL.txt`, sha256
`9b9fe028b5ba74d231659a1bbaf0ed09b11e759d1ca6a070999e16d151616b47`).
Retrieved via
`https://fonts.googleapis.com/css2?family=Noto+Sans+Hebrew:wght@400;500;600;700&display=swap`
(hebrew unicode-range block). Google serves one shared file for weights
400–700; it is stored once.

| File | Weights | Download URL | SHA-256 |
|---|---|---|---|
| `noto-sans-hebrew.woff2` | 400–700 | `https://fonts.gstatic.com/s/notosanshebrew/v50/or30Q7v33eiDljA1IufXTtVf7V6RvEEdhQlk0LlGxCyaePiWTNzWNf72cWk.woff2` | `30420f52f9569d1a89d5ee276a40e9d984808ae794eb91570b2a74e3d2275f09` |

## Icons

Not vendored files: the icons the page uses are inlined in `lib/hub.html`
(`ICONS` map), copied from `lucide-static@0.469.0`
(`https://unpkg.com/lucide-static@0.469.0/icons/<name>.svg`, ISC licence):
check, wrench, octagon-x, pause, user-check, eye, git-merge, hammer, chevron-right,
terminal, rotate-ccw, clock, rocket, snowflake, hand, send, and for Home (paths
re-fetched from that URL on 2026-11-14): layout-grid, arrow-right, circle-check, refresh-cw.
`lib/hub-assets/hub-home.js` is first-party page code, not a vendored file.
