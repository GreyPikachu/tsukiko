#pragma once

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <functional>
#include <memory>

/// Панель диктовки: маленькое окно у значка в области уведомлений.
///
/// Живёт на **втором** движке Flutter — том, что запускает точку входа
/// `panelMain`. Это не прихоть переноса, а условие работы: диктовку ведёт
/// `DictationCubit`, и на macOS он живёт ровно там же. Без второго
/// движка на Windows его не запускал бы никто — ни одно нажатие
/// назначенных клавиш не дошло бы до записи.
///
/// Окно всплывающее (`WS_POPUP`) и без панели задач: оно ведёт себя как
/// поповер — появляется у значка, уходит, когда щёлкнули мимо.
class PanelWindow {
 public:
  PanelWindow();
  ~PanelWindow();

  /// Создать окно и поднять на нём движок. Возвращает мессенджер, чтобы
  /// мост завёл на нём свой канал.
  flutter::BinaryMessenger* Create(const flutter::DartProject& project);

  void Show();
  void Hide();
  void Toggle();
  bool IsVisible() const;

  /// Высоту панель считает сама — по своему содержимому, как поповер
  /// на macOS.
  void SetContentHeight(int height);

  /// Дёргается при появлении и уходе: панель должна знать об этом,
  /// чтобы не считать память, пока её никто не видит.
  std::function<void(bool shown)> on_visibility_changed;

  HWND handle() const { return window_; }

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);
  void PositionNearTray();

  HWND window_ = nullptr;
  int height_ = 420;
  std::unique_ptr<flutter::FlutterViewController> controller_;
};
