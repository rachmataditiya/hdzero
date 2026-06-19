# HDZero Tools

Open-source tools for working with **[HDZero](https://www.hd-zero.com/) digital FPV** video — the
goggle recordings, the footage, the workflow around it. Built by [Arkana](https://arkana.co.id) for
our own FPV work and shared freely.

> Not affiliated with or endorsed by HDZero / Divimath. Trademarks belong to their owners.

## Tools

| Tool | Platform | What it does |
|---|---|---|
| **[HDZero Converter](HDZeroConverter/)** | macOS 13+ | Native SwiftUI app (bundled ffmpeg) that fixes HDZero recordings so Apple decoders play them correctly — converts full-range `yuvj420p` H.264 → limited-range BT.709 and re-wraps for broad compatibility (QuickTime/iPhone stop showing black / washed-out). Fully portable, no Homebrew needed on the target Mac. |

More tools will land here over time.

## HDZero Converter — download

Grab the signed + notarized `.dmg` from the [**Releases**](../../releases) page, drag the app to
`/Applications`, and double-click. No Terminal/`xattr` workaround needed (Apple-notarized).

To build it yourself, see [`HDZeroConverter/README.md`](HDZeroConverter/README.md).

## License

[MIT](LICENSE) © Arkana Solusi Digital, PT.

The macOS app **bundles** `ffmpeg`/`ffprobe` at build time (copied from your local Homebrew install,
not redistributed in this repo). ffmpeg is licensed under the LGPL/GPL by its own authors — see
[ffmpeg.org/legal.html](https://ffmpeg.org/legal.html). This repository's own source code is MIT.
