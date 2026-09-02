#include "dictation_bridge.h"

#include <shlobj.h>
#include <shlwapi.h>
#include <cmath>
#include <chrono>
#include <iostream>

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_FLAC
#define MA_NO_MP3
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"

#define WM_TRAYICON (WM_USER + 101)
#define ID_TRAY_OPEN 1001
#define ID_TRAY_SETTINGS 1002
#define ID_TRAY_QUIT 1003

namespace {

std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), static_cast<int>(str.size()), nullptr, 0);
  std::wstring out(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), static_cast<int>(str.size()), &out[0], size);
  return out;
}

std::string WideToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), static_cast<int>(wstr.size()), nullptr, 0, nullptr, nullptr);
  std::string out(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), static_cast<int>(wstr.size()), &out[0], size, nullptr, nullptr);
  return out;
}

int KeyNameToVk(const std::string& name) {
  if (name == "space") return VK_SPACE;
  if (name == "return" || name == "enter") return VK_RETURN;
  if (name == "tab") return VK_TAB;
  if (name == "escape") return VK_ESCAPE;
  if (name == "delete" || name == "backspace") return VK_BACK;
  if (name == "forwarddelete") return VK_DELETE;
  if (name == "left") return VK_LEFT;
  if (name == "right") return VK_RIGHT;
  if (name == "up") return VK_UP;
  if (name == "down") return VK_DOWN;
  if (name == "home") return VK_HOME;
  if (name == "end") return VK_END;
  if (name == "pageup") return VK_PRIOR;
  if (name == "pagedown") return VK_NEXT;
  if (name.size() == 1) {
    char c = name[0];
    if (c >= 'a' && c <= 'z') return 'A' + (c - 'a');
    if (c >= '0' && c <= '9') return c;
  }
  if (name.size() >= 2 && (name[0] == 'f' || name[0] == 'F')) {
    int fNum = std::atoi(name.c_str() + 1);
    if (fNum >= 1 && fNum <= 24) return VK_F1 + (fNum - 1);
  }
  if (name.size() >= 2 && name[0] == '#') {
    return std::atoi(name.c_str() + 1);
  }
  return 0;
}

std::string VkToKeyName(int vk) {
  switch (vk) {
    case VK_SPACE: return "space";
    case VK_RETURN: return "return";
    case VK_TAB: return "tab";
    case VK_ESCAPE: return "escape";
    case VK_BACK: return "delete";
    case VK_DELETE: return "forwarddelete";
    case VK_LEFT: return "left";
    case VK_RIGHT: return "right";
    case VK_UP: return "up";
    case VK_DOWN: return "down";
    case VK_HOME: return "home";
    case VK_END: return "end";
    case VK_PRIOR: return "pageup";
    case VK_NEXT: return "pagedown";
    default: break;
  }
  if (vk >= 'A' && vk <= 'Z') {
    return std::string(1, static_cast<char>('a' + (vk - 'A')));
  }
  if (vk >= '0' && vk <= '9') {
    return std::string(1, static_cast<char>(vk));
  }
  if (vk >= VK_F1 && vk <= VK_F24) {
    return "f" + std::to_string(vk - VK_F1 + 1);
  }
  return "#" + std::to_string(vk);
}

void AudioCaptureCallback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
  auto* bridge = static_cast<DictationBridge*>(pDevice->pUserData);
  if (!bridge || !pInput) return;

  auto* encoder = static_cast<ma_encoder*>(bridge->GetEncoder());
  if (encoder) {
    ma_encoder_write_pcm_frames(encoder, pInput, frameCount, nullptr);
  }

  const int16_t* samples = static_cast<const int16_t*>(pInput);
  float maxSample = 0.0f;
  for (ma_uint32 i = 0; i < frameCount; ++i) {
    float val = std::abs(static_cast<float>(samples[i])) / 32768.0f;
    if (val > maxSample) maxSample = val;
  }
  bridge->UpdateAudioLevel(maxSample);
}

} // namespace

DictationBridge& DictationBridge::GetInstance() {
  static DictationBridge instance;
  return instance;
}

DictationBridge::DictationBridge() = default;

DictationBridge::~DictationBridge() {
  Shutdown();
}

void DictationBridge::Initialize(flutter::BinaryMessenger* messenger, HWND window_handle) {
  main_window_ = window_handle;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "tsukiko/dictation", &flutter::StandardMethodCodec::GetInstance());

  RegisterMethodChannel();
  SetupTrayIcon();
  InstallKeyboardHook();
}

void DictationBridge::Shutdown() {
  UninstallKeyboardHook();
  RemoveTrayIcon();
  if (is_recording_) {
    StopAudioRecording();
  }
}

void DictationBridge::RegisterMethodChannel() {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();

    if (method == "bind") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto parseSpec = [](const flutter::EncodableMap& map) -> HotkeySpec {
          HotkeySpec spec;
          auto modsIt = map.find(flutter::EncodableValue("mods"));
          if (modsIt != map.end()) {
            if (const auto* list = std::get_if<flutter::EncodableList>(&modsIt->second)) {
              for (const auto& item : *list) {
                if (const auto* s = std::get_if<std::string>(&item)) {
                  spec.mods.insert(*s);
                }
              }
            }
          }
          auto keysIt = map.find(flutter::EncodableValue("keys"));
          if (keysIt != map.end()) {
            if (const auto* list = std::get_if<flutter::EncodableList>(&keysIt->second)) {
              for (const auto& item : *list) {
                if (const auto* s = std::get_if<std::string>(&item)) {
                  int vk = KeyNameToVk(*s);
                  if (vk > 0) spec.keys.insert(vk);
                }
              }
            }
          }
          auto tapsIt = map.find(flutter::EncodableValue("taps"));
          if (tapsIt != map.end()) {
            if (const auto* t = std::get_if<int>(&tapsIt->second)) {
              spec.taps = *t;
            }
          }
          spec.is_empty = spec.mods.empty() && spec.keys.empty();
          return spec;
        };

        auto holdIt = args->find(flutter::EncodableValue("hold"));
        if (holdIt != args->end()) {
          if (const auto* hMap = std::get_if<flutter::EncodableMap>(&holdIt->second)) {
            hold_spec_ = parseSpec(*hMap);
          }
        }
        auto toggleIt = args->find(flutter::EncodableValue("toggle"));
        if (toggleIt != args->end()) {
          if (const auto* tMap = std::get_if<flutter::EncodableMap>(&toggleIt->second)) {
            toggle_spec_ = parseSpec(*tMap);
          }
        }
      }
      result->Success();
    } else if (method == "capture") {
      is_capturing_ = true;
      captured_mods_.clear();
      captured_keys_.clear();
      current_taps_ = 0;
      last_tap_time_ = 0;
      result->Success();
    } else if (method == "cancelCapture") {
      is_capturing_ = false;
      captured_mods_.clear();
      captured_keys_.clear();
      result->Success();
    } else if (method == "settingsChanged") {
      SendReloadSettings();
      result->Success();
    } else if (method == "dictationStatus") {
      result->Success(flutter::EncodableValue(is_recording_ ? "recording" : "idle"));
    } else if (method == "releaseModel") {
      result->Success();
    } else if (method == "openSettings") {
      ShowMainWindow();
      result->Success();
    } else if (method == "initialTab") {
      result->Success(flutter::EncodableValue("dictation"));
    } else if (method == "permissions") {
      result->Success(flutter::EncodableValue(true));
    } else if (method == "requestPermission" || method == "openPermissionSettings") {
      ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-microphone", nullptr, nullptr, SW_SHOWNORMAL);
      result->Success();
    } else if (method == "serverMarks") {
      result->Success();
    } else if (method == "trash") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto pathIt = args->find(flutter::EncodableValue("path"));
        if (pathIt != args->end()) {
          if (const auto* path = std::get_if<std::string>(&pathIt->second)) {
            result->Success(flutter::EncodableValue(MoveToTrash(*path)));
            return;
          }
        }
      }
      result->Success(flutter::EncodableValue(false));
    } else if (method == "quit") {
      PostQuitMessage(0);
      result->Success();
    } else if (method == "record") {
      std::string path = StartAudioRecording();
      result->Success(flutter::EncodableValue(path));
    } else if (method == "stopRecord") {
      std::string path = StopAudioRecording();
      result->Success(flutter::EncodableValue(path));
    } else if (method == "level") {
      result->Success(flutter::EncodableValue(GetAudioLevel()));
    } else if (method == "paste") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto textIt = args->find(flutter::EncodableValue("text"));
        if (textIt != args->end()) {
          if (const auto* text = std::get_if<std::string>(&textIt->second)) {
            result->Success(flutter::EncodableValue(PasteText(*text)));
            return;
          }
        }
      }
      result->Success(flutter::EncodableValue(false));
    } else if (method == "hud") {
      result->Success();
    } else if (method == "openMainWindow") {
      ShowMainWindow();
      result->Success();
    } else if (method == "panelHeight") {
      result->Success();
    } else if (method == "dockIcon") {
      result->Success();
    } else if (method == "loginItem") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args && args->find(flutter::EncodableValue("enabled")) != args->end()) {
        auto enIt = args->find(flutter::EncodableValue("enabled"));
        if (const auto* en = std::get_if<bool>(&enIt->second)) {
          result->Success(flutter::EncodableValue(SetLoginItemEnabled(*en)));
          return;
        }
      }
      result->Success(flutter::EncodableValue(GetLoginItemEnabled()));
    } else {
      result->NotImplemented();
    }
  });
}

void DictationBridge::SetupTrayIcon() {
  if (tray_installed_) return;

  ZeroMemory(&tray_data_, sizeof(tray_data_));
  tray_data_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_data_.hWnd = main_window_;
  tray_data_.uID = 1;
  tray_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_data_.uCallbackMessage = WM_TRAYICON;
  tray_data_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(101));
  if (!tray_data_.hIcon) {
    tray_data_.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  wcscpy_s(tray_data_.szTip, L"tsukiko — диктовка и расшифровка");

  Shell_NotifyIconW(NIM_ADD, &tray_data_);
  tray_installed_ = true;
}

void DictationBridge::RemoveTrayIcon() {
  if (!tray_installed_) return;
  Shell_NotifyIconW(NIM_DELETE, &tray_data_);
  tray_installed_ = false;
}

void DictationBridge::ShowContextMenu() {
  POINT pt;
  GetCursorPos(&pt);
  HMENU hMenu = CreatePopupMenu();
  InsertMenuW(hMenu, 0, MF_BYPOSITION | MF_STRING, ID_TRAY_OPEN, L"Открыть tsukiko");
  InsertMenuW(hMenu, 1, MF_BYPOSITION | MF_STRING, ID_TRAY_SETTINGS, L"Настройки…");
  InsertMenuW(hMenu, 2, MF_BYPOSITION | MF_SEPARATOR, 0, nullptr);
  InsertMenuW(hMenu, 3, MF_BYPOSITION | MF_STRING, ID_TRAY_QUIT, L"Выход");

  SetForegroundWindow(main_window_);
  int cmd = TrackPopupMenu(hMenu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, main_window_, nullptr);
  DestroyMenu(hMenu);

  if (cmd == ID_TRAY_OPEN) {
    ShowMainWindow();
  } else if (cmd == ID_TRAY_SETTINGS) {
    ShowMainWindow();
  } else if (cmd == ID_TRAY_QUIT) {
    PostQuitMessage(0);
  }
}

bool DictationBridge::HandleWindowMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_TRAYICON) {
    if (lparam == WM_LBUTTONUP) {
      ToggleMainWindow();
      return true;
    }
    if (lparam == WM_RBUTTONUP) {
      ShowContextMenu();
      return true;
    }
  } else if (message == WM_CLOSE) {
    // Вместо выхода закрытие окна прячет его в трей
    ShowWindow(main_window_, SW_HIDE);
    return true;
  }
  return false;
}

void DictationBridge::ShowMainWindow() {
  if (!main_window_) return;
  ShowWindow(main_window_, SW_RESTORE);
  SetForegroundWindow(main_window_);
}

void DictationBridge::ToggleMainWindow() {
  if (!main_window_) return;
  if (IsWindowVisible(main_window_)) {
    ShowWindow(main_window_, SW_HIDE);
  } else {
    ShowMainWindow();
  }
}

// ── Клавиатурный хук ────────────────────────────────────────────────────────

void DictationBridge::InstallKeyboardHook() {
  if (keyboard_hook_) return;
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc, GetModuleHandle(nullptr), 0);
}

void DictationBridge::UninstallKeyboardHook() {
  if (keyboard_hook_) {
    UnhookWindowsHookEx(keyboard_hook_);
    keyboard_hook_ = nullptr;
  }
}

LRESULT CALLBACK DictationBridge::LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode == HC_ACTION) {
    auto& bridge = DictationBridge::GetInstance();
    auto* kbd = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    bool isDown = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
    bool isUp = (wParam == WM_KEYUP || wParam == WM_SYSKEYUP);
    int vk = static_cast<int>(kbd->vkCode);

    auto isModifierVk = [](int k) {
      return k == VK_CONTROL || k == VK_LCONTROL || k == VK_RCONTROL ||
             k == VK_MENU || k == VK_LMENU || k == VK_RMENU ||
             k == VK_SHIFT || k == VK_LSHIFT || k == VK_RSHIFT ||
             k == VK_LWIN || k == VK_RWIN;
    };

    std::set<std::string> currentMods;
    if (GetAsyncKeyState(VK_CONTROL) & 0x8000) currentMods.insert("ctrl");
    if (GetAsyncKeyState(VK_MENU) & 0x8000) currentMods.insert("alt");
    if (GetAsyncKeyState(VK_SHIFT) & 0x8000) currentMods.insert("shift");
    if ((GetAsyncKeyState(VK_LWIN) & 0x8000) || (GetAsyncKeyState(VK_RWIN) & 0x8000)) currentMods.insert("cmd");

    if (bridge.is_capturing_) {
      if (isDown) {
        bridge.captured_mods_.insert(currentMods.begin(), currentMods.end());
        if (vk != VK_CONTROL && vk != VK_MENU && vk != VK_SHIFT && vk != VK_LWIN && vk != VK_RWIN) {
          bridge.captured_keys_.insert(vk);
        }
      } else if (isUp) {
        // Когда отпустили клавиши — завершаем захват
        std::vector<std::string> modsList(bridge.captured_mods_.begin(), bridge.captured_mods_.end());
        std::vector<std::string> keysList;
        for (int k : bridge.captured_keys_) {
          keysList.push_back(VkToKeyName(k));
        }
        bridge.is_capturing_ = false;
        bridge.SendCapturedHotkey(modsList, keysList, 1);
      }
      return CallNextHookEx(nullptr, nCode, wParam, lParam);
    }

    // Сопоставление с hold_spec_ и toggle_spec_
    auto keysDown = [&](const HotkeySpec& spec) -> bool {
      for (int k : spec.keys) {
        if (!(GetAsyncKeyState(k) & 0x8000)) return false;
      }
      return true;
    };

    auto matchSpec = [&](const HotkeySpec& spec) -> bool {
      if (spec.is_empty) return false;
      if (spec.mods != currentMods) return false;
      return keysDown(spec);
    };

    // Сочетание зажато целиком, но сверху добавили лишнее.
    //
    // Нажать Ctrl+Alt+Shift разом физически нельзя: по дороге набор
    // проходит через Ctrl+Alt, и запись успевает начаться. Отпустить её
    // как обычное окончание нельзя — человек этого сочетания не назначал
    // и ничего не диктовал. Такое отпускание — отмена: записанное
    // выбрасывается, и панель уходит с экрана сразу.
    auto exceedsSpec = [&](const HotkeySpec& spec) -> bool {
      if (spec.is_empty) return false;
      if (!keysDown(spec)) return false;
      for (const auto& m : spec.mods) {
        if (!currentMods.count(m)) return false;
      }
      // Лишнее — это либо лишний модификатор, либо посторонняя клавиша
      // поверх уже зажатого сочетания.
      if (currentMods.size() > spec.mods.size()) return true;
      return isDown && !spec.keys.count(vk) && !isModifierVk(vk);
    };

    if (isDown) {
      if (!bridge.hold_active_ && matchSpec(bridge.hold_spec_)) {
        bridge.hold_active_ = true;
        bridge.SendHotkeyEvent("hold", true);
      } else if (bridge.hold_active_ && exceedsSpec(bridge.hold_spec_)) {
        bridge.hold_active_ = false;
        bridge.SendHotkeyEvent("hold", false, true);
      } else if (!bridge.toggle_fired_ && matchSpec(bridge.toggle_spec_)) {
        bridge.toggle_fired_ = true;
        bridge.SendHotkeyEvent("toggle", true);
      } else if (bridge.toggle_fired_ && exceedsSpec(bridge.toggle_spec_)) {
        bridge.toggle_fired_ = false;
        bridge.SendHotkeyEvent("toggle", false, true);
      }
    } else if (isUp) {
      if (bridge.hold_active_ && !matchSpec(bridge.hold_spec_)) {
        bridge.hold_active_ = false;
        // Отпустили обычным порядком — это окончание, не отмена.
        bridge.SendHotkeyEvent("hold", false);
      }
      // Отпускание само по себе ничего не переключает — оно лишь
      // разрешает следующему нажатию сработать.
      if (bridge.toggle_fired_ && !matchSpec(bridge.toggle_spec_)) {
        bridge.toggle_fired_ = false;
      }
    }
  }
  return CallNextHookEx(nullptr, nCode, wParam, lParam);
}

void DictationBridge::SendHotkeyEvent(const std::string& id, bool down, bool cancel) {
  if (!channel_) return;
  flutter::EncodableMap map;
  map[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
  map[flutter::EncodableValue("down")] = flutter::EncodableValue(down);
  map[flutter::EncodableValue("cancel")] = flutter::EncodableValue(cancel);
  channel_->InvokeMethod("hotkey", std::make_unique<flutter::EncodableValue>(map));
}

void DictationBridge::SendCapturedHotkey(const std::vector<std::string>& mods,
                                        const std::vector<std::string>& keys,
                                        int taps) {
  if (!channel_) return;
  flutter::EncodableMap map;
  flutter::EncodableList modsList;
  for (const auto& m : mods) modsList.push_back(flutter::EncodableValue(m));
  flutter::EncodableList keysList;
  for (const auto& k : keys) keysList.push_back(flutter::EncodableValue(k));

  map[flutter::EncodableValue("mods")] = modsList;
  map[flutter::EncodableValue("keys")] = keysList;
  map[flutter::EncodableValue("taps")] = flutter::EncodableValue(taps);
  channel_->InvokeMethod("captured", std::make_unique<flutter::EncodableValue>(map));
}

void DictationBridge::SendReloadSettings() {
  if (!channel_) return;
  channel_->InvokeMethod("reload", nullptr);
}

void DictationBridge::SendTab(const std::string& tab) {
  if (!channel_) return;
  channel_->InvokeMethod("tab", std::make_unique<flutter::EncodableValue>(tab));
}

// ── Аудио запись через miniaudio ──────────────────────────────────────────

std::string DictationBridge::StartAudioRecording() {
  if (is_recording_) {
    StopAudioRecording();
  }

  wchar_t tempPath[MAX_PATH];
  GetTempPathW(MAX_PATH, tempPath);
  auto now = std::chrono::system_clock::now().time_since_epoch().count();
  std::wstring fileW = std::wstring(tempPath) + L"tsukiko_record_" + std::to_wstring(now) + L".wav";
  current_record_path_ = WideToUtf8(fileW);

  auto* encoder = new ma_encoder();
  ma_encoder_config encConfig = ma_encoder_config_init(ma_encoding_format_wav, ma_format_s16, 1, 16000);
  if (ma_encoder_init_file(current_record_path_.c_str(), &encConfig, encoder) != MA_SUCCESS) {
    delete encoder;
    return "";
  }
  ma_encoder_ = encoder;

  auto* device = new ma_device();
  ma_device_config devConfig = ma_device_config_init(ma_device_type_capture);
  devConfig.capture.format = ma_format_s16;
  devConfig.capture.channels = 1;
  devConfig.sampleRate = 16000;
  devConfig.dataCallback = AudioCaptureCallback;
  devConfig.pUserData = this;

  if (ma_device_init(nullptr, &devConfig, device) != MA_SUCCESS) {
    ma_encoder_uninit(encoder);
    delete encoder;
    ma_encoder_ = nullptr;
    delete device;
    return "";
  }
  ma_device_ = device;

  if (ma_device_start(device) != MA_SUCCESS) {
    ma_device_uninit(device);
    delete device;
    ma_device_ = nullptr;
    ma_encoder_uninit(encoder);
    delete encoder;
    ma_encoder_ = nullptr;
    return "";
  }

  is_recording_ = true;
  current_level_ = 0.0f;
  return current_record_path_;
}

std::string DictationBridge::StopAudioRecording() {
  if (!is_recording_) return current_record_path_;

  is_recording_ = false;
  if (ma_device_) {
    auto* device = static_cast<ma_device*>(ma_device_);
    ma_device_stop(device);
    ma_device_uninit(device);
    delete device;
    ma_device_ = nullptr;
  }
  if (ma_encoder_) {
    auto* encoder = static_cast<ma_encoder*>(ma_encoder_);
    ma_encoder_uninit(encoder);
    delete encoder;
    ma_encoder_ = nullptr;
  }

  current_level_ = 0.0f;
  return current_record_path_;
}

double DictationBridge::GetAudioLevel() {
  return static_cast<double>(current_level_);
}

// ── Вставка текста ─────────────────────────────────────────────────────────

bool DictationBridge::PasteText(const std::string& text) {
  if (text.empty()) return true;

  if (!OpenClipboard(main_window_)) return false;
  EmptyClipboard();

  std::wstring wtext = Utf8ToWide(text);
  size_t bytes = (wtext.size() + 1) * sizeof(wchar_t);
  HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!hMem) {
    CloseClipboard();
    return false;
  }

  memcpy(GlobalLock(hMem), wtext.c_str(), bytes);
  GlobalUnlock(hMem);
  SetClipboardData(CF_UNICODETEXT, hMem);
  CloseClipboard();

  // Симуляция нажатия Ctrl + V
  INPUT inputs[4] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = VK_CONTROL;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = 'V';
  inputs[2].type = INPUT_KEYBOARD;
  inputs[2].ki.wVk = 'V';
  inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
  inputs[3].type = INPUT_KEYBOARD;
  inputs[3].ki.wVk = VK_CONTROL;
  inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

  SendInput(4, inputs, sizeof(INPUT));
  return true;
}

// ── Корзина и автозапуск ───────────────────────────────────────────────────

bool DictationBridge::MoveToTrash(const std::string& path) {
  std::wstring wpath = Utf8ToWide(path);
  wpath.push_back(L'\0'); // Двойной нулевой терминатор для SHFileOperation

  SHFILEOPSTRUCTW op = {};
  op.hwnd = main_window_;
  op.wFunc = FO_DELETE;
  op.pFrom = wpath.c_str();
  op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT;

  int result = SHFileOperationW(&op);
  return result == 0 && !op.fAnyOperationsAborted;
}

bool DictationBridge::GetLoginItemEnabled() {
  HKEY hKey;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  bool exists = (RegQueryValueExW(hKey, L"tsukiko", nullptr, &type, nullptr, nullptr) == ERROR_SUCCESS);
  RegCloseKey(hKey);
  return exists;
}

bool DictationBridge::SetLoginItemEnabled(bool enabled) {
  HKEY hKey;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, KEY_WRITE, &hKey) != ERROR_SUCCESS) {
    return false;
  }
  bool success = false;
  if (enabled) {
    wchar_t exePath[MAX_PATH];
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(exePath) + L"\" --login-item";
    DWORD bytes = static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t));
    success = (RegSetValueExW(hKey, L"tsukiko", 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()), bytes) == ERROR_SUCCESS);
  } else {
    success = (RegDeleteValueW(hKey, L"tsukiko") == ERROR_SUCCESS);
  }
  RegCloseKey(hKey);
  return success;
}
