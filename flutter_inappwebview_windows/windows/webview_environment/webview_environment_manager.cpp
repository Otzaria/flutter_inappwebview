#include <atomic>
#include <chrono>
#include <DispatcherQueue.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <thread>
#include <wil/wrl.h>

#include "../in_app_webview/in_app_webview_settings.h"
#include "../utils/flutter.h"
#include "../utils/log.h"
#include "../utils/string.h"
#include "../utils/vector.h"
#include "webview_environment_manager.h"

namespace flutter_inappwebview_plugin
{
  WebViewEnvironmentManager::WebViewEnvironmentManager(const FlutterInappwebviewWindowsPlugin* plugin)
    : plugin(plugin),
    ChannelDelegate(plugin->registrar->messenger(), WebViewEnvironmentManager::METHOD_CHANNEL_NAME)
  {
    windowClass_.lpszClassName = WebViewEnvironmentManager::CLASS_NAME;
    windowClass_.lpfnWndProc = &WebViewEnvironmentManager::WndProc;

    RegisterClass(&windowClass_);

    const DWORD windowStyle = WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN;
    hwnd_ = CreateWindowEx(0, windowClass_.lpszClassName, L"", windowStyle, 0,
      0, 0, 0,
      plugin->registrar->GetView()->GetNativeWindow(),
      nullptr,
      windowClass_.hInstance, nullptr);
    if (hwnd_) {
      SetWindowLongPtr(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    }
  }

  void WebViewEnvironmentManager::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto& methodName = method_call.method_name();

    if (string_equals(methodName, "create")) {
      auto id = get_fl_map_value<std::string>(*arguments, "id");
      auto settingsMap = get_optional_fl_map_value<flutter::EncodableMap>(*arguments, "settings");
      auto settings = settingsMap.has_value() ? std::make_unique<WebViewEnvironmentSettings>(settingsMap.value()) : nullptr;
      createWebViewEnvironment(id, std::move(settings), std::move(result));
    }
    else if (string_equals(methodName, "prewarm")) {
      auto settingsMap = get_optional_fl_map_value<flutter::EncodableMap>(*arguments, "settings");
      prewarm(settingsMap.has_value() ? std::make_shared<WebViewEnvironmentSettings>(settingsMap.value()) : nullptr, std::move(result));
    }
    else if (string_equals(methodName, "getAvailableVersion")) {
      auto browserExecutableFolder = get_optional_fl_map_value<std::string>(*arguments, "browserExecutableFolder");
      result->Success(make_fl_value(getAvailableVersion(browserExecutableFolder)));
    }
    else if (string_equals(methodName, "compareBrowserVersions")) {
      auto version1 = get_fl_map_value<std::string>(*arguments, "version1");
      auto version2 = get_fl_map_value<std::string>(*arguments, "version2");
      result->Success(make_fl_value(compareBrowserVersions(version1, version2)));
    }
    else {
      result->NotImplemented();
    }
  }

  void WebViewEnvironmentManager::createWebViewEnvironment(const std::string& id, std::unique_ptr<WebViewEnvironmentSettings> settings, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto result_ = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));

    auto webViewEnvironment = std::make_unique<WebViewEnvironment>(plugin, id);
    webViewEnvironment->create(std::move(settings),
      [this, id, result_](HRESULT errorCode)
      {
        if (succeededOrLog(errorCode)) {
          result_->Success(true);
        }
        else {
          result_->Error("0", "Cannot create WebViewEnvironment: " + getHRMessage(errorCode));
          if (map_contains(webViewEnvironments, id)) {
            webViewEnvironments.erase(id);
          }
        }
      });
    webViewEnvironments.insert({ id, std::move(webViewEnvironment) });
  }

  namespace
  {
    struct PrewarmOutcome
    {
      int64_t id;
      std::string status;
      HRESULT hr;
      int64_t durationMs;
    };

    // Registered lazily: User32 calls are not allowed during DllMain's CRT init.
    UINT prewarmDoneMessage()
    {
      static const UINT message = RegisterWindowMessage(L"FlutterInappwebviewPrewarmDone");
      return message;
    }
  }

  LRESULT CALLBACK WebViewEnvironmentManager::WndProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
  {
    if (message == prewarmDoneMessage() && prewarmDoneMessage() != 0) {
      std::unique_ptr<PrewarmOutcome> outcome(reinterpret_cast<PrewarmOutcome*>(lParam));
      auto manager = reinterpret_cast<WebViewEnvironmentManager*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
      if (manager) {
        manager->completePrewarm(outcome->id, outcome->status, outcome->hr, outcome->durationMs);
      }
      return 0;
    }
    return DefWindowProc(hwnd, message, wParam, lParam);
  }

  void WebViewEnvironmentManager::completePrewarm(int64_t id, const std::string& status, HRESULT hr, int64_t durationMs)
  {
    auto it = pendingPrewarms_.find(id);
    if (it == pendingPrewarms_.end()) {
      return;
    }
    auto result = std::move(it->second);
    pendingPrewarms_.erase(it);
    result->Success(flutter::EncodableMap{
      {"status", make_fl_value(status)},
      {"errorCode", make_fl_value(static_cast<int64_t>(hr))},
      {"durationMs", make_fl_value(durationMs)}
    });
  }

  // The first environment in a process loads the runtime DLL synchronously on the
  // calling thread; a throwaway one here moves that load off the UI thread.
  void WebViewEnvironmentManager::prewarm(std::shared_ptr<WebViewEnvironmentSettings> settings, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (!hwnd_ || prewarmDoneMessage() == 0) {
      result->Success(flutter::EncodableMap{
        {"status", make_fl_value(std::string("unavailable"))},
        {"errorCode", make_fl_value(static_cast<int64_t>(E_FAIL))},
        {"durationMs", make_fl_value(int64_t{ 0 })}
      });
      return;
    }
    auto id = ++lastPrewarmId_;
    pendingPrewarms_.insert({ id, std::move(result) });
    auto hwnd = hwnd_;
    try {
      std::thread([settings, hwnd, id]()
        {
          auto startedAt = std::chrono::steady_clock::now();
          auto outcome = std::make_unique<PrewarmOutcome>(PrewarmOutcome{ id, "ok", S_OK, 0 });
          outcome->hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
          if (FAILED(outcome->hr)) {
            outcome->status = "com_init_failed";
          }
          else {
            auto browserExecutableFolder = settings && settings->browserExecutableFolder.has_value()
              ? std::optional<std::wstring>(utf8_to_wide(settings->browserExecutableFolder.value())) : std::nullopt;
            auto userDataFolder = settings && settings->userDataFolder.has_value()
              ? std::optional<std::wstring>(utf8_to_wide(settings->userDataFolder.value())) : std::nullopt;
            auto browserFolder = browserExecutableFolder.has_value() ? browserExecutableFolder->c_str() : nullptr;

            wil::unique_cotaskmem_string version;
            outcome->hr = GetAvailableCoreWebView2BrowserVersionString(browserFolder, &version);
            if (FAILED(outcome->hr) || !version) {
              outcome->status = "no_runtime";
            }
            else {
              struct Completion
              {
                std::atomic_bool done = false;
                HRESULT hr = E_PENDING;
              };
              auto completion = std::make_shared<Completion>();
              outcome->hr = CreateCoreWebView2EnvironmentWithOptions(
                browserFolder,
                userDataFolder.has_value() ? userDataFolder->c_str() : nullptr,
                WebViewEnvironment::createOptions(settings.get()).get(),
                Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                  [completion](HRESULT hr, ICoreWebView2Environment* environment) -> HRESULT
                  {
                    completion->hr = hr;
                    completion->done = true;
                    return S_OK;
                  }).Get());
              if (FAILED(outcome->hr)) {
                outcome->status = "create_failed";
              }
              else {
                auto deadline = GetTickCount64() + 30000;
                MSG msg;
                while (!completion->done && GetTickCount64() < deadline) {
                  if (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
                    TranslateMessage(&msg);
                    DispatchMessage(&msg);
                  }
                  else {
                    MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
                  }
                }
                if (!completion->done) {
                  outcome->status = "timeout";
                  outcome->hr = E_PENDING;
                }
                else if (FAILED(completion->hr)) {
                  outcome->status = "create_failed";
                  outcome->hr = completion->hr;
                }
              }
            }
            CoUninitialize();
          }
          failedLog(outcome->hr);
          outcome->durationMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - startedAt).count();
          // Fails once the plugin is torn down; the outcome is then dropped.
          if (PostMessage(hwnd, prewarmDoneMessage(), 0, reinterpret_cast<LPARAM>(outcome.get()))) {
            outcome.release();
          }
        }).detach();
    }
    catch (const std::system_error& e) {
      debugLog("WebViewEnvironmentManager: cannot start prewarm thread: " + std::string(e.what()));
      completePrewarm(id, "thread_failed", E_FAIL, 0);
    }
  }

  void WebViewEnvironmentManager::createOrGetDefaultWebViewEnvironment(const std::function<void(WebViewEnvironment*)> completionHandler)
  {
    if (defaultEnvironment_) {
      if (completionHandler) {
        completionHandler(defaultEnvironment_.get());
      }
      return;
    }

    defaultEnvironment_ = std::make_unique<WebViewEnvironment>(plugin, "-1");
    defaultEnvironment_->create(nullptr, [this, completionHandler](HRESULT errorCode)
      {
        if (succeededOrLog(errorCode)) {
          if (completionHandler) {
            completionHandler(defaultEnvironment_.get());
          }
        }
        else if (completionHandler) {
          defaultEnvironment_ = nullptr;
          completionHandler(nullptr);
        }
      });
  }

  std::optional<std::string> WebViewEnvironmentManager::getAvailableVersion(std::optional<std::string> browserExecutableFolder)
  {
    wil::unique_cotaskmem_string versionInfo;
    if (succeededOrLog(GetAvailableCoreWebView2BrowserVersionString(browserExecutableFolder.has_value() ? utf8_to_wide(browserExecutableFolder.value()).c_str() : nullptr, &versionInfo))) {
      return wide_to_utf8(versionInfo.get());
    }
    return std::nullopt;
  }

  std::optional<int> WebViewEnvironmentManager::compareBrowserVersions(std::string version1, std::string version2)
  {
    int result = 0;
    if (succeededOrLog(CompareBrowserVersions(utf8_to_wide(version1).c_str(), utf8_to_wide(version2).c_str(), &result))) {
      return result;
    }
    return std::nullopt;
  }

  WebViewEnvironmentManager::~WebViewEnvironmentManager()
  {
    debugLog("dealloc WebViewEnvironmentManager");
    webViewEnvironments.clear();
    plugin = nullptr;
    defaultEnvironment_ = nullptr;
    if (hwnd_) {
      SetWindowLongPtr(hwnd_, GWLP_USERDATA, 0);
      DestroyWindow(hwnd_);
    }
  }
}
