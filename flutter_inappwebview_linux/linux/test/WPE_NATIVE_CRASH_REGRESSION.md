# Linux WPE WebView crash report

A Linux Flutter application using the packaged native WebView plugin repeatedly aborted with SIGABRT, GLib reference-count assertions, and `free(): invalid pointer`. The same application and runtime stayed open when an earlier, known-working native plugin was used for an A/B comparison.

The included diagnostic runner supports this reversible test without replacing package files. It validates the plugin registration symbol and confirms the resolved library before launching.

This is a **temporary compatibility workaround**, not a proven fix for the native memory bug. Maintainers should compare the two builds and test WPE buffer lifetime, GObject references, creation/destruction, and scaling under sanitizers.

## Exact environment and binary fingerprints

Observed on Ubuntu 26.04, GNOME 50.1, Wayland, fractional scale 125%, application version 0.9.98+99800. The affected native plugin checksum was `e69ddcb6e24c7e2f8dc7a05c169313fbfe95a9c5e5d8951145ccbe2ee6ae0a3c`. The previously working plugin checksum was `438db6e3c2d38d5a07aae79f79793ec5fcdd9407e9658f45109dc4a37694e11f`. These are exact binary fingerprints, not general version claims.

The new native plugin crashed even after the optional display-scale interposer was removed. The pixel fallback option was already enabled. With the earlier native plugin, the same app and bundled WPE libraries produced 40 successful frames at 2922x1776, stayed open for over four minutes, and the user confirmed plugin operation.

## Reversible A/B procedure

Use only a trusted earlier native plugin from your own installation. Run `bash flutter_inappwebview_linux/linux/test/run_with_webview_plugin.sh /path/to/app.bin /trusted/known-good/libflutter_inappwebview_linux_plugin.so`. This does not replace installed files; close the process to revert. Native ABI compatibility is not guaranteed. Never upload raw crash core dumps because they may contain private application data.

## Next steps

Reproduce with the exact failing build, inspect GObject ownership and WPE buffer release with debug symbols and sanitizers, compare compiler flags and runtime libraries, and add repeated create/switch/close regression tests. The A/B result narrows the problem but does not prove a specific faulty line.
