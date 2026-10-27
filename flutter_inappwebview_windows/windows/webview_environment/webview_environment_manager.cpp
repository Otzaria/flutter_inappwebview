#include <atomic>
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
    windowClass_.lpfnWndProc = &DefWindowProc;

    RegisterClass(&windowClass_);

    const DWORD windowStyle = WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN;
    hwnd_ = CreateWindowEx(0, windowClass_.lpszClassName, L"", windowStyle, 0,
      0, 0, 0,
      plugin->registrar->GetView()->GetNativeWindow(),
      nullptr,
      windowClass_.hInstance, nullptr);
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
      prewarm(settingsMap.has_value() ? std::make_shared<WebViewEnvironmentSettings>(settingsMap.value()) : nullptr);
      result->Success();
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

  // The first environment in a process loads the runtime DLL synchronously on the
  // calling thread; a throwaway one here moves that load off the UI thread.
  void WebViewEnvironmentManager::prewarm(std::shared_ptr<WebViewEnvironmentSettings> settings)
  {
    try {
      std::thread([settings]()
        {
          if (failedAndLog(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {
            return;
          }
          {
            auto browserExecutableFolder = settings && settings->browserExecutableFolder.has_value()
              ? std::optional<std::wstring>(utf8_to_wide(settings->browserExecutableFolder.value())) : std::nullopt;
            auto userDataFolder = settings && settings->userDataFolder.has_value()
              ? std::optional<std::wstring>(utf8_to_wide(settings->userDataFolder.value())) : std::nullopt;
            auto browserFolder = browserExecutableFolder.has_value() ? browserExecutableFolder->c_str() : nullptr;

            wil::unique_cotaskmem_string version;
            if (succeededOrLog(GetAvailableCoreWebView2BrowserVersionString(browserFolder, &version)) && version) {
              auto done = std::make_shared<std::atomic_bool>(false);
              auto hr = CreateCoreWebView2EnvironmentWithOptions(
                browserFolder,
                userDataFolder.has_value() ? userDataFolder->c_str() : nullptr,
                WebViewEnvironment::createOptions(settings.get()).get(),
                Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                  [done](HRESULT result, ICoreWebView2Environment* environment) -> HRESULT
                  {
                    failedLog(result);
                    *done = true;
                    return S_OK;
                  }).Get());
              if (succeededOrLog(hr)) {
                auto deadline = GetTickCount64() + 30000;
                MSG msg;
                while (!*done && GetTickCount64() < deadline) {
                  if (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
                    TranslateMessage(&msg);
                    DispatchMessage(&msg);
                  }
                  else {
                    MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
                  }
                }
              }
            }
          }
          CoUninitialize();
        }).detach();
    }
    catch (const std::system_error& e) {
      debugLog("WebViewEnvironmentManager: cannot start prewarm thread: " + std::string(e.what()));
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
      DestroyWindow(hwnd_);
    }
  }
}
