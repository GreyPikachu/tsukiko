#include "panel_window.h"

#include <shellapi.h>

#include <optional>

namespace {

constexpr wchar_t kClassName[] = L"TsukikoPanelWindow";
constexpr int kWidth = 340;

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
