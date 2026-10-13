#!/usr/bin/env bash
# Opt-in A/B diagnostic and temporary compatibility workaround for a Linux Flutter app.
set -euo pipefail
usage() {
  echo "Usage: $0 /path/to/app.bin /path/to/libflutter_inappwebview_linux_plugin.so [app args...]" >&2
  exit 2
}
(( $# >= 2 )) || usage
app="$(realpath -e -- "$1")" || usage
plugin="$(realpath -e -- "$2")" || usage
shift 2
if [[ ! -x "$app" ]] || [[ "$(basename -- "$plugin")" != libflutter_inappwebview_linux_plugin.so ]]; then
  echo "Expected an executable and a libflutter_inappwebview_linux_plugin.so file" >&2
  exit 2
fi
if ! readelf -d "$app" 2>/dev/null | grep -F 'Shared library: [libflutter_inappwebview_linux_plugin.so]' >/dev/null; then
  echo "Application does not link libflutter_inappwebview_linux_plugin.so directly" >&2
  exit 2
fi
if ! readelf -Ws "$plugin" 2>/dev/null | grep -F 'flutter_inappwebview_linux_plugin_register_with_registrar' >/dev/null; then
  echo "Override is missing the WebView plugin registration symbol" >&2
  exit 2
fi
app_lib="$(dirname -- "$app")/lib"
plugin_dir="$(dirname -- "$plugin")"
export LD_LIBRARY_PATH="$plugin_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [[ -d "$app_lib" ]]; then
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$app_lib"
  export WEBKIT_EXEC_PATH="${WEBKIT_EXEC_PATH:-$app_lib}"
  export WEBKIT_INJECTED_BUNDLE_PATH="${WEBKIT_INJECTED_BUNDLE_PATH:-$app_lib}"
fi
resolved="$(ldd "$app" 2>&1)" || { echo "Unable to resolve application dependencies" >&2; exit 2; }
if [[ "$resolved" == *'not found'* ]] || ! grep -F "libflutter_inappwebview_linux_plugin.so => $plugin " <<< "$resolved" >/dev/null; then
  echo "Override or another application dependency could not be resolved:" >&2
  echo "$resolved" >&2
  exit 2
fi
exec "$app" "$@"
