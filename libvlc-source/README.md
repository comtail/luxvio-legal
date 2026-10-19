# LibVLC source for LUXVIO (LGPL-2.1-or-later)

LUXVIO Media Player and LUXVIO TV Media Player ship a self-built LibVLC 3.x for Android
(`libvlc.so`, `libvlcjni.so`, `libc++_shared` linked statically), licensed under the
GNU Lesser General Public License 2.1 or later. This folder and the release
[`libvlc-lgpl-2026-10-18`](https://github.com/comtail/luxvio-legal/releases/tag/libvlc-lgpl-2026-10-18)
contain the complete corresponding source.

| File | Content |
|---|---|
| `vlc-5abc418c98df.tar.gz` (release) | VLC source, commit `5abc418c98df26a5ab085f89e01909686ad85831` |
| `libvlcjni-0b8dc65efb20.tar.gz` (release) | libvlcjni source, commit `0b8dc65efb203c86a0476bc337ddd99ecf1c0ef6` (branch libvlcjni-3.x) |
| `vlc-contrib-tarballs.tar` (release) | All third-party contrib source archives used by the build |
| `compile-libvlc.lgpl.patch` | Changes to libvlcjni's build script (LGPL-only configuration) |
| `build_libvlc_lgpl.sh` | Script that reproduces the build |
| `BUILDINFO.txt` | Toolchains (Android NDK r27c / r21e) and configure options |
| `SHA256SUMS.txt` | Checksums of the release archives |

Configuration: `compile-libvlc.sh --license a` (contribs `--disable-gpl --disable-gnuv3`),
`--disable-zvbi --disable-lua --disable-sout --disable-realrtsp`; GPL-only modules are blacklisted.
No libdvdcss, libdvdread or libdvdnav.

You may modify LibVLC and relink it: the libraries are separate `.so` files inside the app.
Upstream projects: https://code.videolan.org/videolan/vlc and https://code.videolan.org/videolan/libvlcjni

Questions: info@comtail.de – ComTail Computer, Bahnhofstraße 35, 86381 Krumbach, Germany.
This offer is valid for at least three years after the last distribution of the app.
