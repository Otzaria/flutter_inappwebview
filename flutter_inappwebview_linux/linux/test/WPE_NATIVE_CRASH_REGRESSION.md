# Linux WPE WebView crash report

A Linux Flutter application using the packaged native WebView plugin repeatedly aborted with SIGABRT, GLib reference-count assertions, and `free(): invalid pointer`. The same application and runtime stayed open when an earlier, known-working native plugin was used for an A/B comparison.

The included diagnostic runner supports this reversible test without replacing package files. It validates the plugin registration symbol and confirms the resolved library before launching.

This is a **temporary compatibility workaround**, not a proven fix for the native memory bug. Maintainers should compare the two builds and test WPE buffer lifetime, GObject references, creation/destruction, and scaling under sanitizers.
