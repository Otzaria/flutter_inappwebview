## Unreleased

- Keep the shared console bootstrap neutral for related views and apply policy only to the owning document on load, so parent/popup callbacks and allowlists stay independent across navigation.
- Filter console before JavaScript string conversion once the document policy arrives and before native Flutter IPC, retain bounded batches through Dart, and synchronize console listeners across rebuilds and keep-alive reuse. Inline native subscriptions stay disabled until a live Dart controller attaches, including delayed keep-alive creation.

## 0.1.0-beta.1

- Resolved current Linux host handles after pending creation and queued rehosts, avoiding destroyed or replaced native windows.

- Attached popups and dialogs to each WebView's Flutter window, including keep-alive reuse, host destruction, and fractional-scale moves between windows.
- Reported native WebView initialization failures with their stage and original diagnostics, and released Dart creation waiters after failures.
- Coalesced surface size reports to one update per frame and kept texture offsets current before pointer input.
- Batched console notifications while preserving message order and immediate warning/error delivery.
- Released oversized fallback pixel buffers after substantial viewport reductions while reusing capacity for modest resizes.
- Deferred inline DMA-BUF imports to Flutter and coordinated EGL failures with the pixel fallback.
- Converted fallback pixel frames directly into packed RGBA buffers without an intermediate full-frame copy.
- Coalesced cursor hit testing to one update per animation frame.
- Enforced `disableHorizontalScroll` and `disableVerticalScroll` for wheel and
  trackpad input.
- Initial release.
