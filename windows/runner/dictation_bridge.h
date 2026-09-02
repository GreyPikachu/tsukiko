#pragma once

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <string>
#include <vector>
#include <set>
#include <functional>

/// Мост к родному коду Windows: глобальный перехват клавиш, запись звука,
/// вставка текста, Корзина, автозапуск и значок в системном трее.
///
/// Полный аналог Dictation.swift на macOS, отвечающий на тот же канал
/// 'tsukiko/dictation' и посылающий те же события в Dart.
class DictationBridge {
 public:
  static DictationBridge& GetInstance();

  void Initialize(flutter::BinaryMessenger* messenger, HWND window_handle);
  void Shutdown();

  // Обработка сообщений Win32 для трея и горячих клавиш
  bool HandleWindowMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  // Вызовы из Dart
  void SendHotkeyEvent(const std::string& id, bool down, bool cancel = false);
  void SendCapturedHotkey(const std::vector<std::string>& mods,
                          const std::vector<std::string>& keys,
                          int taps);
  void SendReloadSettings();
  void SendTab(const std::string& tab);

  void* GetEncoder() const { return ma_encoder_; }
  void UpdateAudioLevel(float lvl) { current_level_ = lvl; }

 private:
  DictationBridge();
  ~DictationBridge();

  void RegisterMethodChannel();
  void SetupTrayIcon();
  void RemoveTrayIcon();
  void ShowContextMenu();

  // Клавиатурный хук
  void InstallKeyboardHook();
  void UninstallKeyboardHook();
  static LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam);

  // Запись аудио
  std::string StartAudioRecording();
  std::string StopAudioRecording();
  double GetAudioLevel();

  // Вставка текста и буфер обмена
  bool PasteText(const std::string& text);

  // Корзина и автозапуск
  bool MoveToTrash(const std::string& path);
  bool GetLoginItemEnabled();
  bool SetLoginItemEnabled(bool enabled);

  // Окна
  void ShowMainWindow();
  void ToggleMainWindow();

  HWND main_window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  NOTIFYICONDATAW tray_data_ = {};
  bool tray_installed_ = false;
  HHOOK keyboard_hook_ = nullptr;

  // Состояние хоткеев
  struct HotkeySpec {
    std::set<std::string> mods;
    std::set<int> keys;
    int taps = 1;
    bool is_empty = true;
  };

  HotkeySpec hold_spec_;
  HotkeySpec toggle_spec_;
  bool is_capturing_ = false;
  std::set<std::string> captured_mods_;
  std::set<int> captured_keys_;
  ULONGLONG last_tap_time_ = 0;
  int current_taps_ = 0;
  bool hold_active_ = false;

  /// Переключение сработало и ещё не отпущено. Нужно, чтобы отменить его
  /// ровно один раз, если поверх сочетания набрали лишнее.
  bool toggle_fired_ = false;

  // Аудио запись
  void* ma_device_ = nullptr;
  void* ma_encoder_ = nullptr;
  std::string current_record_path_;
  float current_level_ = 0.0f;
  bool is_recording_ = false;
};
