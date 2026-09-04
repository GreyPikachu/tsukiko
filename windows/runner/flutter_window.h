#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

class PanelWindow;

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  /// Панель диктовки на своём движке. Живёт столько же, сколько окно:
  /// диктовка должна работать и когда окно спрятано в трей.
  std::unique_ptr<PanelWindow> panel_;

  /// Окно уже показывали. Дальше показывать его самим нельзя: это будет
  /// не показ, а выпрыгивание поверх чужой работы.
  bool shown_once_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
