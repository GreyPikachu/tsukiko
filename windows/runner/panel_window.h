#pragma once

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <functional>
#include <chrono>
#include <memory>
#include <string>
#include "hud_placement.h"

/// Плавающая панель записи: та, что приходит сама, пока человек диктует.
///
/// Фокус не забирает ни при каких условиях (`WS_EX_NOACTIVATE`): заберёт —
/// уйдёт из поля ввода, куда мы собираемся вставлять текст, и вставка
/// сломается целиком. По той же причине она поверх всех окон и без кнопки
/// на панели задач.
class HudWindow {
 public:
  explicit HudWindow(bool editor = false);
  ~HudWindow();
  void Configure(const flutter::DartProject& base, const std::function<void(flutter::BinaryMessenger*)>& on_ready);
  void ReleaseEditor();
  std::function<void()> on_editor_closed;
  void SetQueue(bool queued);
  void SetMode(const std::string& mode);
  const std::string& mode() const { return mode_; }
  bool floating() const { return mode_ == "panel" || mode_ == "timer"; }
  void FinishEditing(bool save);
  void ResetPosition();
  void SetScale(double scale);
  void Move(double dx, double dy, bool ended);
  void Nudge(double dx, double dy);
  bool editing() const { return editing_; }
  double scale() const { return placement_.scale; }
  HWND handle() const { return window_; }

  /// Завести окно и поднять на нём движок, но на экран не выводить.
  ///
  /// Отдельно от [Show] затем, что подъём движка — это новый изолят,
  /// загрузка снимка приложения и первый кадр, и делается он на том же
  /// потоке, что и обработка сообщений окна. Сделанный в ответ на нажатие
  /// клавиши, он этим нажатием и оплачивается: первая диктовка после
  /// запуска ждала подъёма панели, и ждала заметно.
  void Prepare(const flutter::DartProject& base,
               const std::function<void(flutter::BinaryMessenger*)>& on_ready);

  void Show(const flutter::DartProject& base,
            const std::function<void(flutter::BinaryMessenger*)>& on_ready);
  void Hide();
  bool IsVisible() const;

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  void ShowReady();
  void ResizeAndPosition();
  void PositionEditor(bool animate);
  void AnimateTo(HudPoint target, bool animate);
  void CaptureCenter();
  void SavePlacement();
  HudArea WorkArea() const;
  double DpiScale() const;
  HudPlacement placement_, saved_;
  bool is_editor_ = false;
  std::string mode_ = "panel", saved_mode_ = "panel";
  std::unique_ptr<HudWindow> editor_;
  int editor_corner_ = 0;
  HudPoint motion_start_{}, motion_target_{};
  std::chrono::steady_clock::time_point motion_started_;
  bool moving_ = false;
  bool editing_ = false;
  bool queued_ = false;
  bool dragging_ = false;
  bool visible_before_editing_ = false;
  HudPoint drag_origin_{};
  POINT drag_pointer_{};
  HWND previous_focus_ = nullptr;
  HWND above_window_ = nullptr;
  std::function<void()> on_close_;
  HMONITOR monitor_ = nullptr;
  HWND guides_ = nullptr;

  HWND window_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  bool first_frame_ready_ = false;
  bool wanted_visible_ = false;
};

/// Окно настроек: обычное окно на своём, третьем движке.
///
/// Отдельным движком, а не вкладкой в главном окне, ровно затем же, зачем
/// на macOS: настройки открываются и из панели у значка, когда главного
/// окна нет на экране вовсе.
class SettingsWindow {
 public:
  ~SettingsWindow();

  /// Показать, подняв движок при первом обращении. [on_ready] зовётся
  /// один раз — мосту, чтобы завести на нём канал.
  void Show(const flutter::DartProject& base,
            const std::function<void(flutter::BinaryMessenger*)>& on_ready);

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  HWND window_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> controller_;
};

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
