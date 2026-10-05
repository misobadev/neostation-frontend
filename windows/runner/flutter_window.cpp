#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  flutter::MethodChannel<flutter::EncodableValue> shortcuts(
      flutter_controller_->engine()->messenger(),
      "com.neogamelab.neostation/shortcuts",
      &flutter::StandardMethodCodec::GetInstance());
  shortcuts.SetMethodCallHandler([](const auto& call, auto result) {
    const auto* value = call.arguments();
    const auto* file = value ? std::get_if<std::string>(value) : nullptr;
    if (call.method_name() != "launch") {
      result->NotImplemented();
      return;
    }
    if (!file || file->empty()) {
      result->Error("invalid_path", "Missing shortcut path");
      return;
    }
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         file->data(), static_cast<int>(file->size()), nullptr, 0);
    if (!count) {
      result->Error("invalid_path", "Invalid UTF-8 path");
      return;
    }
    std::wstring wide(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, file->data(),
                        static_cast<int>(file->size()), wide.data(), count);
    SHELLEXECUTEINFOW info = {};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_FLAG_NO_UI;
    info.lpVerb = L"open";
    info.lpFile = wide.c_str();
    info.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&info)) {
      result->Error("launch_failed", "Windows rejected shortcut: " + std::to_string(GetLastError()));
      return;
    }
    result->Success();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
