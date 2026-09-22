#include "flutter_window.h"

#include <optional>
#include <cwchar>
#include <commctrl.h>
#include <commdlg.h>
#include <ole2.h>
#include <shellapi.h>

#include "dictation_bridge.h"
#include "panel_window.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

flutter::EncodableList PickAudioFiles(HWND owner, DWORD* error) {
  std::wstring buffer(65536, L'\0');
  // GetOpenFileNameW uses a double-NUL-terminated filter list.
  static constexpr wchar_t filter[] =
      L"Audio and video\0*.ogg;*.oga;*.opus;*.mp3;*.m4a;*.aac;*.wav;*.aiff;*.aif;*.caf;*.flac;*.mp4;*.mov;*.m4b;*.wma\0"
      L"All files\0*.*\0";
  OPENFILENAMEW dialog{};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = owner;
  dialog.lpstrFilter = filter;
  dialog.lpstrFile = buffer.data();
  dialog.nMaxFile = static_cast<DWORD>(buffer.size());
  dialog.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST |
                 OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

  flutter::EncodableList paths;
  if (!GetOpenFileNameW(&dialog)) {
    *error = CommDlgExtendedError();  // 0 means the user cancelled.
    return paths;
  }
  const wchar_t* first = buffer.c_str();
  const wchar_t* next = first + wcslen(first) + 1;
  if (*next == L'\0') {
    paths.emplace_back(Utf8FromUtf16(first));
    return paths;
  }
  for (; *next != L'\0'; next += wcslen(next) + 1) {
    paths.emplace_back(Utf8FromUtf16((std::wstring(first) + L"\\" + next).c_str()));
  }
  return paths;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool show_on_first_frame)
    : project_(project), show_on_first_frame_(show_on_first_frame) {}

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
  file_input_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "tsukiko/file_input",
      &flutter::StandardMethodCodec::GetInstance());
  file_input_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "pickAudioFiles") {
      DWORD error = 0;
      auto paths = PickAudioFiles(GetHandle(), &error);
      if (error != 0) {
        result->Error("file_dialog_failed", "Windows file dialog failed",
                      flutter::EncodableValue(static_cast<int32_t>(error)));
      } else {
        result->Success(flutter::EncodableValue(paths));
      }
    } else {
      result->NotImplemented();
    }
  });
  DictationBridge::GetInstance().Initialize(flutter_controller_->engine()->messenger(), GetHandle());
  // Окно настроек поднимает свой движок само, когда его впервые откроют.
  DictationBridge::GetInstance().SetDartProject(&project_);

  // Второй движок — панель диктовки. Без неё `panelMain` не запускал бы
  // никто, а с ним и диктовку: она живёт там, а не в очереди.
  panel_ = std::make_unique<PanelWindow>();
  if (auto* messenger = panel_->Create(project_)) {
    DictationBridge::GetInstance().AttachPanel(messenger, panel_.get());
  } else {
    panel_ = nullptr;
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Use the shell's WM_DROPFILES path for the main window, independently of
  // desktop_drop's OLE target. Other Flutter engines keep their plugins.
  file_drop_window_ = flutter_controller_->view()->GetNativeWindow();
  RevokeDragDrop(file_drop_window_);
  SetWindowSubclass(file_drop_window_, FileDropProc, 1,
                    reinterpret_cast<DWORD_PTR>(this));
  DragAcceptFiles(file_drop_window_, TRUE);

  // Показать окно на первом кадре — и только на первом.
  //
  // Show() — это ShowWindow(SW_SHOWNORMAL), а он не «показывает», а ещё и
  // выводит окно вперёд, отнимая фокус у того, что сейчас на экране.
  // Второй раз это уже не показ, а выпрыгивание: окно очереди лезло
  // поверх настроек на каждую правку — правка рассылается всем движкам
  // как «перечитать», главное окно перерисовывается, и обратный вызов
  // срабатывал снова.
  //
  // При запуске из автозапуска не показываем вовсе: приложение подняли
  // ради диктовки, а не ради очереди. Окно никуда не делось — оно
  // откроется по значку в трее или из панели. Ровно так же устроено
  // на macOS (MainFlutterWindow.awakeFromNib, --login-item), и Windows
  // отставала: там окно вылезало на весь экран при каждом входе в систему.
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (shown_once_ || !show_on_first_frame_) return;
    shown_once_ = true;
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (file_drop_window_) {
    DragAcceptFiles(file_drop_window_, FALSE);
    RemoveWindowSubclass(file_drop_window_, FileDropProc, 1);
    file_drop_window_ = nullptr;
  }
  file_input_ = nullptr;
  DictationBridge::GetInstance().Shutdown();
  panel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT CALLBACK FlutterWindow::FileDropProc(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam,
                                             UINT_PTR id, DWORD_PTR context) {
  if (message != WM_DROPFILES) {
    return DefSubclassProc(window, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<FlutterWindow*>(context);
  HDROP drop = reinterpret_cast<HDROP>(wparam);
  flutter::EncodableList paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    std::wstring path(length + 1, L'\0');
    DragQueryFileW(drop, i, path.data(), length + 1);
    paths.emplace_back(Utf8FromUtf16(path.c_str()));
  }
  DragFinish(drop);
  if (self->file_input_ && !paths.empty()) {
    self->file_input_->InvokeMethod(
        "filesDropped", std::make_unique<flutter::EncodableValue>(paths));
  }
  return 0;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (DictationBridge::GetInstance().HandleWindowMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

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
