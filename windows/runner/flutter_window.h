#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <ole2.h>

class PanelWindow;

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  //
  // |show_on_first_frame| — показывать ли окно, когда движок нарисует
  // первый кадр. При запуске из автозапуска — нет: см. main.cpp.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool show_on_first_frame = true);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

  static LRESULT CALLBACK FileDropProc(HWND window, UINT message, WPARAM wparam,
                                       LPARAM lparam, UINT_PTR id,
                                       DWORD_PTR context);

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> file_input_;
  HWND file_drop_window_ = nullptr;
  IDropTarget* file_drop_target_ = nullptr;

  /// Панель диктовки на своём движке. Живёт столько же, сколько окно:
  /// диктовка должна работать и когда окно спрятано в трей.
  std::unique_ptr<PanelWindow> panel_;

  /// Окно уже показывали. Дальше показывать его самим нельзя: это будет
  /// не показ, а выпрыгивание поверх чужой работы.
  bool shown_once_ = false;

  /// Показывать ли окно вообще. Вход в систему поднимает приложение ради
  /// диктовки, и окно очереди при этом не нужно.
  bool show_on_first_frame_ = true;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
