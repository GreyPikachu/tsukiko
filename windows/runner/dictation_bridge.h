#pragma once

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
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
class PanelWindow;

class DictationBridge {
 public:
  static DictationBridge& GetInstance();

  void Initialize(flutter::BinaryMessenger* messenger, HWND window_handle);

  /// Завести канал на движке панели. Именно её сторона ведёт диктовку,
  /// поэтому события клавиш и назначения уходят туда, а не в очередь.
  void AttachPanel(flutter::BinaryMessenger* messenger, PanelWindow* panel);
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
  /// Канал главного окна и канал панели. Обработчик у них один —
  /// спрашивать умеют обе стороны, — а вот события ходят по-разному:
  /// клавиши и панель касаются только диктовки, а «перечитать настройки»
  /// касается всех.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> panel_channel_;
  PanelWindow* panel_ = nullptr;

  /// Куда слать то, что касается диктовки. Панели ещё нет — пусть идёт
  /// в главное окно: молчать хуже, чем сказать не туда.
  flutter::MethodChannel<flutter::EncodableValue>* DictationChannel() const {
    return panel_channel_ ? panel_channel_.get() : channel_.get();
  }

  void RegisterHandler(flutter::MethodChannel<flutter::EncodableValue>* channel);

  void ForwardToPanel(
      const std::string& method,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      flutter::EncodableValue fallback);
  NOTIFYICONDATAW tray_data_ = {};
  bool tray_installed_ = false;
  HHOOK keyboard_hook_ = nullptr;

  // Состояние хоткеев
  struct HotkeySpec {
    std::set<std::string> mods;
    std::set<int> keys;
    int taps = 1;
    bool is_empty = true;

    bool is_double() const { return taps >= 2; }
  };

  /// Что происходит с одним сочетанием.
  ///
  /// Память о нажатии нужна затем же, зачем и на macOS: без неё каждое
  /// событие, где набор снова совпал, считалось бы новым нажатием — и
  /// у переключателя это стоило бы записи.
  ///
  /// Двойное нажатие живёт здесь же: первый короткий стук ничего
  /// не включает, он только взводит; включает второе нажатие, если оно
  /// пришло вовремя. Для «держать и говорить» это привычный жест
  /// «стук, стук-и-держать».
  struct TapState {
    bool active = false;
    ULONGLONG pressed_at = 0;
    ULONGLONG armed_at = 0;

    /// true, когда «сочетание работает» изменилось на этом событии.
    bool Update(bool raw, bool is_double, ULONGLONG now);
  };

  /// За сколько должен уложиться второй стук, и с какого мгновения
  /// нажатие считается удержанием, а не стуком. Числа те же, что
  /// на macOS: короче — не успеть, длиннее — два независимых нажатия
  /// начнут слипаться в одно двойное.
  static constexpr ULONGLONG kDoubleTapWindowMs = 400;
  static constexpr ULONGLONG kTapMaxHoldMs = 250;

  HotkeySpec hold_spec_;
  HotkeySpec toggle_spec_;
  bool is_capturing_ = false;
  std::set<std::string> captured_mods_;
  std::set<int> captured_keys_;
  ULONGLONG capture_started_at_ = 0;

  /// Набор, отпущенный коротким стуком и ждущий второго. Дождались —
  /// это двойное нажатие; не дождались — по таймеру назначаем одиночным.
  bool has_pending_capture_ = false;
  std::set<std::string> pending_mods_;
  std::vector<std::string> pending_keys_;

  void FinishCapture(const std::set<std::string>& mods,
                     const std::vector<std::string>& keys, int taps);
  void OnCaptureTimeout();
  TapState hold_state_;
  TapState toggle_state_;

  // Аудио запись
  void* ma_device_ = nullptr;
  void* ma_encoder_ = nullptr;
  std::string current_record_path_;
  float current_level_ = 0.0f;
  bool is_recording_ = false;
};
