#include "panel_window.h"

#include <dwmapi.h>
#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

/// Значок приложения для окон, которые заводятся не через Win32Window.
/// Без него Windows рисует в заголовке и в Alt+Tab пустой лист бумаги.
HICON AppIcon() {
  return LoadIconW(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
}

}  // namespace

namespace {

constexpr wchar_t kClassName[] = L"TsukikoPanelWindow";
constexpr int kWidth = 340;

constexpr wchar_t kHudClassName[] = L"TsukikoHudWindow";
// Те же размеры, что у панели на macOS.
constexpr int kHudWidth = 372;
constexpr int kHudHeight = 52;

constexpr wchar_t kSettingsClassName[] = L"TsukikoSettingsWindow";
// Тот же размер, что и на macOS: раскладка настроек сходится именно в нём.
constexpr int kSettingsWidth = 580;
constexpr int kSettingsHeight = 560;

}  // namespace

PanelWindow::PanelWindow() = default;

PanelWindow::~PanelWindow() {
  controller_ = nullptr;
  if (window_) DestroyWindow(window_);
}

flutter::BinaryMessenger* PanelWindow::Create(
    const flutter::DartProject& base) {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = PanelWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);

  // WS_EX_TOOLWINDOW убирает кнопку с панели задач: это поповер, а не
  // ещё одно окно приложения. WS_EX_TOPMOST держит его поверх чужих.
  window_ = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kClassName, L"tsukiko",
      WS_POPUP, 0, 0, kWidth, height_, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  if (!window_) return nullptr;

  // Свой движок со своей точкой входа: диктовка живёт отдельно от очереди
  // и работает, даже когда главное окно спрятано.
  flutter::DartProject project = base;
  project.set_dart_entrypoint("panelMain");
  controller_ = std::make_unique<flutter::FlutterViewController>(
      kWidth, height_, project);
  if (!controller_->engine() || !controller_->view()) {
    controller_ = nullptr;
    return nullptr;
  }
  // Плагины ставятся на каждый движок отдельно: регистратор принадлежит
  // движку, а не процессу. Без этого file_selector и desktop_drop живут
  // только в главном окне, а в остальных любой их вызов кончается
  // MissingPluginException — так и не работала кнопка «выбрать другую
  // папку» в настройках.
  RegisterPlugins(controller_->engine());
  // Как это делает Win32Window для главного окна: вид движка становится
  // содержимым окна и растягивается на всю его клиентскую часть.
  HWND view = controller_->view()->GetNativeWindow();
  SetParent(view, window_);
  MoveWindow(view, 0, 0, kWidth, height_, TRUE);
  ShowWindow(view, SW_SHOW);
  return controller_->engine()->messenger();
}

LRESULT CALLBACK PanelWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<PanelWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));

  if (self) {
    // Щёлкнули мимо — панель уходит. Так ведёт себя всякий поповер,
    // и так же она ведёт себя на macOS.
    if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
      self->Hide();
      return 0;
    }
    if (message == WM_CLOSE) {
      self->Hide();
      return 0;
    }
    if (self->controller_) {
      std::optional<LRESULT> result =
          self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
      if (result) return *result;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

/// У значка в области уведомлений, а не посреди экрана: панель принадлежит
/// значку, и появляться она должна там, куда только что щёлкнули.
void PanelWindow::PositionNearTray() {
  POINT pt;
  GetCursorPos(&pt);
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);

  int x = pt.x - kWidth / 2;
  if (x < work.left) x = work.left;
  if (x + kWidth > work.right) x = work.right - kWidth;
  // Значок обычно внизу справа, и панель встаёт над ним; если полоса
  // задач сверху — под ним.
  int y = (pt.y > (work.top + work.bottom) / 2) ? work.bottom - height_
                                                : work.top;
  SetWindowPos(window_, HWND_TOPMOST, x, y, kWidth, height_, SWP_NOACTIVATE);
}

void PanelWindow::Show() {
  if (!window_ || IsVisible()) return;
  PositionNearTray();
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  SetForegroundWindow(window_);
  if (on_visibility_changed) on_visibility_changed(true);
}

void PanelWindow::Hide() {
  if (!window_ || !IsVisible()) return;
  ShowWindow(window_, SW_HIDE);
  if (on_visibility_changed) on_visibility_changed(false);
}

void PanelWindow::Toggle() {
  IsVisible() ? Hide() : Show();
}

bool PanelWindow::IsVisible() const {
  return window_ && IsWindowVisible(window_);
}

void PanelWindow::SetContentHeight(int height) {
  if (height <= 0 || height == height_) return;
  height_ = height;
  if (controller_ && controller_->view()) {
    MoveWindow(controller_->view()->GetNativeWindow(), 0, 0, kWidth, height_,
               TRUE);
  }
  SetWindowPos(window_, nullptr, 0, 0, kWidth, height_,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  if (IsVisible()) PositionNearTray();
}


// ── окно настроек ───────────────────────────────────────────────────────────

SettingsWindow::~SettingsWindow() {
  controller_ = nullptr;
  if (window_) DestroyWindow(window_);
}

void SettingsWindow::Show(
    const flutter::DartProject& base,
    const std::function<void(flutter::BinaryMessenger*)>& on_ready) {
  if (window_) {
    ShowWindow(window_, SW_RESTORE);
    SetForegroundWindow(window_);
    return;
  }

  WNDCLASSW wc = {};
  wc.lpfnWndProc = SettingsWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kSettingsClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hIcon = AppIcon();
  RegisterClassW(&wc);

  // Ни развернуть, ни растянуть: раскладка настроек рассчитана на один
  // размер, как и на macOS.
  RECT rect = {0, 0, kSettingsWidth, kSettingsHeight};
  AdjustWindowRect(&rect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE);
  window_ = CreateWindowExW(
      0, kSettingsClassName, L"Настройки",
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, CW_USEDEFAULT,
      CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top, nullptr,
      nullptr, GetModuleHandle(nullptr), this);
  if (!window_) return;

  flutter::DartProject project = base;
  project.set_dart_entrypoint("settingsMain");
  controller_ = std::make_unique<flutter::FlutterViewController>(
      kSettingsWidth, kSettingsHeight, project);
  if (!controller_->engine() || !controller_->view()) {
    controller_ = nullptr;
    DestroyWindow(window_);
    window_ = nullptr;
    return;
  }
  RegisterPlugins(controller_->engine());
  HWND view = controller_->view()->GetNativeWindow();
  SetParent(view, window_);
  MoveWindow(view, 0, 0, kSettingsWidth, kSettingsHeight, TRUE);
  ShowWindow(view, SW_SHOW);
  on_ready(controller_->engine()->messenger());

  ShowWindow(window_, SW_SHOW);
  SetForegroundWindow(window_);
}

LRESULT CALLBACK SettingsWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                         LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self =
      reinterpret_cast<SettingsWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self) {
    // Закрытие прячет окно, а движок остаётся жить: он держит около ста
    // мегабайт, зато повторное открытие мгновенное — то же решение,
    // что и на macOS.
    if (message == WM_CLOSE) {
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    }
    // Клавиатура достаётся виду Flutter, а не пустой рамке вокруг него:
    // иначе в полях настроек нельзя набрать ни буквы.
    if (message == WM_ACTIVATE && self->controller_ && self->controller_->view()) {
      SetFocus(self->controller_->view()->GetNativeWindow());
    }
    if (self->controller_) {
      std::optional<LRESULT> result =
          self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                     lparam);
      if (result) return *result;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}


// ── плавающая панель записи ─────────────────────────────────────────────────

HudWindow::~HudWindow() {
  controller_ = nullptr;
  if (window_) DestroyWindow(window_);
}

void HudWindow::Show(
    const flutter::DartProject& base,
    const std::function<void(flutter::BinaryMessenger*)>& on_ready) {
  Prepare(base, on_ready);
  if (!window_) return;

  // Внизу по центру рабочей области — там же, где она стоит на macOS.
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const int x = (work.left + work.right) / 2 - kHudWidth / 2;
  const int y = work.bottom - kHudHeight - 92;
  SetWindowPos(window_, HWND_TOPMOST, x, y, kHudWidth, kHudHeight,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void HudWindow::Prepare(
    const flutter::DartProject& base,
    const std::function<void(flutter::BinaryMessenger*)>& on_ready) {
  if (!window_) {
    WNDCLASSW wc = {};
    wc.lpfnWndProc = HudWindow::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.lpszClassName = kHudClassName;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&wc);

    window_ = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE, kHudClassName,
        L"tsukiko", WS_POPUP, 0, 0, kHudWidth, kHudHeight, nullptr, nullptr,
        GetModuleHandle(nullptr), this);
    if (!window_) return;

    // Скруглённые углы — системные, как у всплывающих окон Windows 11.
    // На Windows 10 вызов просто ничего не делает.
    DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(window_, DWMWA_WINDOW_CORNER_PREFERENCE, &corner,
                          sizeof(corner));

    flutter::DartProject project = base;
    project.set_dart_entrypoint("hudMain");
    controller_ = std::make_unique<flutter::FlutterViewController>(
        kHudWidth, kHudHeight, project);
    if (!controller_->engine() || !controller_->view()) {
      controller_ = nullptr;
      DestroyWindow(window_);
      window_ = nullptr;
      return;
    }
    RegisterPlugins(controller_->engine());
    HWND view = controller_->view()->GetNativeWindow();
    SetParent(view, window_);
    MoveWindow(view, 0, 0, kHudWidth, kHudHeight, TRUE);
    ShowWindow(view, SW_SHOW);
    on_ready(controller_->engine()->messenger());
  }
}

void HudWindow::Hide() {
  if (window_) ShowWindow(window_, SW_HIDE);
}

bool HudWindow::IsVisible() const {
  return window_ && IsWindowVisible(window_);
}

LRESULT CALLBACK HudWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self =
      reinterpret_cast<HudWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  // Ни щелчком, ни клавишей фокус этой панели не достаётся: она нужна
  // поверх чужого окна, в которое сейчас диктуют.
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (message == WM_ERASEBKGND) {
    HDC hdc = reinterpret_cast<HDC>(wparam);
    RECT rect;
    GetClientRect(hwnd, &rect);
    HBRUSH brush = CreateSolidBrush(RGB(32, 32, 32));
    FillRect(hdc, &rect, brush);
    DeleteObject(brush);
    return 1;
  }
  if (self && self->controller_) {
    std::optional<LRESULT> result =
        self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                   lparam);
    if (result) return *result;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
