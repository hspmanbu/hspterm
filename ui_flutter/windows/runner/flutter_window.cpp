#include "flutter_window.h"

#include <optional>
#include <set>
#include <algorithm>
#include <cmath>
#include <dwmapi.h>
#include <windowsx.h>
#include <shlobj.h>
#include <flutter/standard_method_codec.h>
#include "utils.h"
#include "secure_unlock.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
struct FontCatalog {
  std::set<std::string> families;
  bool invalid = false;
};

// Reveals |path| in Explorer via the documented shell API: opens the parent
// folder with the item preselected, reusing the shell's own window. This is
// the reliable replacement for `explorer /select,...` whose exit code is
// meaningless (a reused Explorer process exits with 1 even on success).
bool RevealInExplorer(const std::wstring& path) {
  LPITEMIDLIST item = nullptr;
  SFGAOF attributes = 0;
  const HRESULT parsed = SHParseDisplayName(path.c_str(), nullptr, &item, 0, &attributes);
  if (FAILED(parsed) || item == nullptr) return false;
  // The parent folder is derived from the same PIDL so the selection target
  // and the opened window can never disagree.
  LPCITEMIDLIST child = nullptr;
  LPITEMIDLIST parent = ILCloneFull(item);
  if (parent == nullptr) {
    ILFree(item);
    return false;
  }
  // ILRemoveLastID mutates in place, leaving the parent PIDL.
  if (!ILRemoveLastID(parent)) {
    ILFree(parent);
    ILFree(item);
    return false;
  }
  child = ILFindLastID(item);
  const HRESULT revealed = SHOpenFolderAndSelectItems(parent, 1, &child, 0);
  ILFree(parent);
  ILFree(item);
  return SUCCEEDED(revealed);
}

int CALLBACK CollectFont(const LOGFONTW* font, const TEXTMETRICW*, DWORD,
                         LPARAM data) {
  auto* catalog = reinterpret_cast<FontCatalog*>(data);
  // Skip vertical aliases, not the corresponding normal CJK family.
  if (font->lfFaceName[0] == L'@') return 1;
  const auto size = wcsnlen_s(font->lfFaceName, LF_FACESIZE);
  if (size == 0 || size >= LF_FACESIZE) {
    catalog->invalid = true;
    return 0;
  }
  const std::wstring family(font->lfFaceName, size);
  const auto name = Utf8FromUtf16(family.c_str());
  if (name.empty()) { catalog->invalid = true; return 0; }
  catalog->families.insert(name);
  if (catalog->families.size() > 4096) {
    catalog->invalid = true;
    return 0;
  }
  return 1;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

LRESULT FlutterWindow::FrameHitTest(POINT point) const {
  if (!integrated_frame_) return HTCLIENT;
  const HWND window = const_cast<FlutterWindow*>(this)->GetHandle();
  RECT bounds = {};
  if (!GetWindowRect(window, &bounds) || !PtInRect(&bounds, point)) return HTCLIENT;
  if (!IsZoomed(window)) {
    const UINT dpi = GetDpiForWindow(window);
    const int padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const int x = GetSystemMetricsForDpi(SM_CXFRAME, dpi) + padding;
    const int y = GetSystemMetricsForDpi(SM_CYFRAME, dpi) + padding;
    const bool left = point.x < bounds.left + x;
    const bool right = point.x >= bounds.right - x;
    const bool top = point.y < bounds.top + y;
    const bool bottom = point.y >= bounds.bottom - y;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }
  if (ScreenToClient(window, &point) && PtInRect(&maximize_button_, point)) return HTMAXBUTTON;
  return HTCLIENT;
}

LRESULT CALLBACK FlutterWindow::ChildWindowProc(HWND window, UINT message,
    WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  auto* owner = reinterpret_cast<FlutterWindow*>(data);
  if (message == WM_NCHITTEST && owner->integrated_frame_) {
    const POINT screen = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (owner->FrameHitTest(screen) != HTCLIENT) return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) RemoveWindowSubclass(window, ChildWindowProc, id);
  return DefSubclassProc(window, message, wparam, lparam);
}

void FlutterWindow::RestorePlacement() {
  WINDOWPLACEMENT placement = {};
  DWORD bytes = sizeof(placement);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\HSPTerm\\Window", L"PlacementV1",
                  RRF_RT_REG_BINARY, nullptr, &placement, &bytes) != ERROR_SUCCESS ||
      bytes != sizeof(placement) || placement.length != sizeof(placement)) return;
  const RECT rect = placement.rcNormalPosition;
  const auto width = static_cast<long long>(rect.right) - rect.left;
  const auto height = static_cast<long long>(rect.bottom) - rect.top;
  if (width < 320 || width > 32768 || height < 240 || height > 32768 ||
      rect.left < -1000000 || rect.left > 1000000 ||
      rect.top < -1000000 || rect.top > 1000000) return;
  startup_maximized_ = placement.showCmd == SW_SHOWMAXIMIZED;
  placement.flags = 0;
  placement.showCmd = SW_HIDE;
  // Keep Get/SetWindowPlacement's workspace coordinate convention. Windows
  // adjusts wholly off-screen rectangles after monitor configuration changes.
  if (!SetWindowPlacement(GetHandle(), &placement)) startup_maximized_ = false;
}

void FlutterWindow::SavePlacement() {
  WINDOWPLACEMENT placement = {};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(GetHandle(), &placement)) return;
  const bool maximized = placement.showCmd == SW_SHOWMAXIMIZED ||
      (placement.flags & WPF_RESTORETOMAXIMIZED) != 0;
  placement.flags = 0;
  placement.showCmd = maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  // Only native geometry, local to this Windows account; never sync/Vault data.
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\HSPTerm\\Window", 0, nullptr,
                      0, KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(key, L"PlacementV1", 0, REG_BINARY,
                   reinterpret_cast<const BYTE*>(&placement), sizeof(placement));
    RegCloseKey(key);
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  RestorePlacement();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  child_subclassed_ = SetWindowSubclass(
      flutter_controller_->view()->GetNativeWindow(), ChildWindowProc, 1,
      reinterpret_cast<DWORD_PTR>(this)) != FALSE;
  explorer_drop_ = std::make_unique<ExplorerDropBridge>(
      flutter_controller_->engine()->messenger(), flutter_controller_->view()->GetNativeWindow());
  if (!explorer_drop_->IsReady()) return false;
  RegisterPlugins(flutter_controller_->engine());
  secure_unlock_ = CreateSecureUnlockChannel(flutter_controller_->engine()->messenger());
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "hspterm/prototype_window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const HWND window = GetHandle();
    if (window == nullptr) { result->Error("window_closed", "窗口已关闭"); return; }
    const auto& method = call.method_name();
    if (method == "initialize") {
      if (!child_subclassed_) {
        result->Error("window_frame", "无法安装边框命中处理，保留原生窗口边框"); return;
      }
      // Only workbench/mock opt into the custom frame. The Phase 2 runner
      // retains its normal system title bar until this method is called.
      const MARGINS margins = {1, 1, 1, 1};
      if (FAILED(DwmExtendFrameIntoClientArea(window, &margins))) {
        result->Error("window_frame", "无法初始化自定义窗口边框；保留系统标题栏"); return;
      }
      integrated_frame_ = true;
      if (!SetWindowPos(window, nullptr, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
        integrated_frame_ = false;
        result->Error("window_frame", "无法更新窗口边框；保留系统标题栏"); return;
      }
    } else if (method == "minimize") {
      ShowWindow(window, SW_MINIMIZE);
    } else if (method == "maximize") {
      ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
    } else if (method == "activate") {
      // Explicit notification click only. Respect Windows foreground policy;
      // no AttachThreadInput/topmost tricks and no extra window or SSH root.
      if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
      if (GetForegroundWindow() != window && !SetForegroundWindow(window)) {
        result->Error("window_activate", "终端已定位，但Windows未允许激活窗口"); return;
      }
    } else if (method == "drag") {
      ReleaseCapture();
      POINT point = {};
      if (!GetCursorPos(&point)) { result->Error("window_drag", "无法读取鼠标位置"); return; }
      // Use the native move loop (including edge Snap), never move the window
      // by repeated Dart coordinates. Alt+Space and system commands remain.
      if (!PostMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(point.x, point.y))) {
        result->Error("window_drag", "无法开始原生窗口移动"); return;
      }
    } else if (method == "systemMenu") {
      POINT point = {};
      if (!GetCursorPos(&point)) { result->Error("window_menu", "无法读取鼠标位置"); return; }
      const HMENU menu = GetSystemMenu(window, FALSE);
      if (menu == nullptr) { result->Error("window_menu", "无法打开系统菜单"); return; }
      EnableMenuItem(menu, SC_RESTORE, MF_BYCOMMAND | (IsZoomed(window) ? MF_ENABLED : MF_GRAYED));
      EnableMenuItem(menu, SC_MAXIMIZE, MF_BYCOMMAND | (IsZoomed(window) ? MF_GRAYED : MF_ENABLED));
      const auto command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                         point.x, point.y, 0, window, nullptr);
      if (command != 0 && !PostMessage(window, WM_SYSCOMMAND, command, 0)) {
        result->Error("window_menu", "无法提交系统菜单操作"); return;
      }
    } else if (method == "close") {
      // Engine HandleTopLevelWindowProc below handles cancelable WM_CLOSE and
      // calls the framework's existing AppLifecycleListener. No DestroyWindow
      // or process exit here: active edits/transfers must finish saving first.
      if (!PostMessage(window, WM_CLOSE, 0, 0)) {
        result->Error("window_close", "无法提交关闭请求；窗口保持打开"); return;
      }
    } else if (method == "reveal") {
      // Open the parent folder with the file preselected through the shell
      // API (SHOpenFolderAndSelectItems). The Dart side falls back to opening
      // the folder when selection is not possible.
      const auto* args = call.arguments();
      const auto* map = args == nullptr
          ? nullptr : std::get_if<flutter::EncodableMap>(args);
      const auto* path = [&]() -> const std::string* {
        if (map == nullptr) return nullptr;
        const auto it = map->find(flutter::EncodableValue("path"));
        if (it == map->end()) return nullptr;
        return std::get_if<std::string>(&it->second);
      }();
      if (path == nullptr || path->empty()) {
        result->Error("reveal", "未提供要定位的文件路径"); return;
      }
      const int wide_size = MultiByteToWideChar(
          CP_UTF8, MB_ERR_INVALID_CHARS, path->c_str(), -1, nullptr, 0);
      if (wide_size <= 0) {
        result->Error("reveal", "文件路径编码无效"); return;
      }
      std::wstring wide(static_cast<size_t>(wide_size), L'\0');
      if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->c_str(), -1,
                              wide.data(), wide_size) != wide_size) {
        result->Error("reveal", "文件路径编码无效"); return;
      }
      if (!RevealInExplorer(wide)) {
        result->Error("reveal_failed", "Shell未能选中文件；回退打开父目录"); return;
      }
    } else if (method == "ensureDialogVisible") {
      // A Flutter dialog is clipped to this window's client area. When the
      // window hangs off the monitor a centered dialog can end up (partly)
      // outside the visible screen. Slide the window — size unchanged —
      // back into the monitor work area so an upcoming dialog is reachable.
      const auto* args = call.arguments();
      const auto* map = args == nullptr
          ? nullptr : std::get_if<flutter::EncodableMap>(args);
      double min_w = 480, min_h = 400;
      if (map != nullptr) {
        const auto read = [&](const char* key, double& into) {
          const auto it = map->find(flutter::EncodableValue(key));
          if (it != map->end()) {
            if (const auto* v = std::get_if<double>(&it->second)) {
              if (std::isfinite(*v) && *v > 0) into = *v;
            }
          }
        };
        read("minWidth", min_w);
        read("minHeight", min_h);
      }
      const HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
      MONITORINFO info = {};
      info.cbSize = sizeof(info);
      RECT wr = {};
      if (monitor == nullptr || !GetMonitorInfo(monitor, &info) || !GetWindowRect(window, &wr)) {
        result->Error("dialog_bounds", "无法读取窗口或显示器区域"); return;
      }
      const LONG width = wr.right - wr.left, height = wr.bottom - wr.top;
      const LONG overlap_w = std::min(wr.right, info.rcWork.right) - std::max(wr.left, info.rcWork.left);
      const LONG overlap_h = std::min(wr.bottom, info.rcWork.bottom) - std::max(wr.top, info.rcWork.top);
      const bool room_for_dialog =
          overlap_w >= static_cast<LONG>(min_w) && overlap_h >= static_cast<LONG>(min_h);
      if (!room_for_dialog) {
        // Clamp the window origin into the work area, preserving size; DPI
        // virtualization means these are all in the same coordinate space.
        const LONG x = std::clamp(wr.left, info.rcWork.left,
                                  std::max(info.rcWork.left, info.rcWork.right - width));
        const LONG y = std::clamp(wr.top, info.rcWork.top,
                                  std::max(info.rcWork.top, info.rcWork.bottom - height));
        if (!SetWindowPos(window, nullptr, x, y, 0, 0,
                          SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) {
          result->Error("dialog_bounds", "无法将窗口移回可见区域"); return;
        }
      }
      // A large window can have enough overlap while its center is still
      // off-screen. Return the visible CLIENT intersection, rather than
      // letting Flutter center a dialog in the entire oversized window.
      RECT client = {};
      POINT origin = {0, 0};
      if (!GetClientRect(window, &client) || !ClientToScreen(window, &origin)) {
        result->Error("dialog_bounds", "无法读取客户区"); return;
      }
      RECT screen_client = {origin.x, origin.y,
          origin.x + client.right, origin.y + client.bottom};
      RECT visible = {};
      if (!IntersectRect(&visible, &screen_client, &info.rcWork)) {
        result->Error("dialog_bounds", "窗口没有可见客户区"); return;
      }
      result->Success(flutter::EncodableValue(flutter::EncodableList{
          flutter::EncodableValue(static_cast<double>(visible.left - origin.x)),
          flutter::EncodableValue(static_cast<double>(visible.top - origin.y)),
          flutter::EncodableValue(static_cast<double>(visible.right - visible.left)),
          flutter::EncodableValue(static_cast<double>(visible.bottom - visible.top))}));
      return;
    } else if (method == "maximizeRect") {
      const auto* args = call.arguments();
      const auto* list = args == nullptr ? nullptr : std::get_if<flutter::EncodableList>(args);
      if (list == nullptr || (!list->empty() && list->size() != 4)) {
        result->Error("window_geometry", "最大化按钮区域无效"); return;
      }
      RECT rect = {};
      if (!list->empty()) {
        double values[4] = {};
        for (size_t i = 0; i < 4; ++i) {
          const auto* value = std::get_if<double>(&(*list)[i]);
          if (value == nullptr || !std::isfinite(*value) || *value < 0 || *value > 100000) {
            result->Error("window_geometry", "最大化按钮区域无效"); return;
          }
          values[i] = *value;
        }
        if (values[2] <= values[0] || values[3] <= values[1]) {
          result->Error("window_geometry", "最大化按钮区域无效"); return;
        }
        rect = {static_cast<LONG>(std::floor(values[0])), static_cast<LONG>(std::floor(values[1])),
                static_cast<LONG>(std::ceil(values[2])), static_cast<LONG>(std::ceil(values[3]))};
      }
      maximize_button_ = rect;
    } else {
      result->NotImplemented(); return;
    }
    result->Success();
  });
  font_catalog_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "hspterm/font_catalog",
      &flutter::StandardMethodCodec::GetInstance());
  font_catalog_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "families") { result->NotImplemented(); return; }
    HDC dc = GetDC(nullptr);
    if (dc == nullptr) { result->Error("font_catalog", "无法读取系统字体"); return; }
    LOGFONTW request = {};
    request.lfCharSet = DEFAULT_CHARSET;
    FontCatalog catalog;
    EnumFontFamiliesExW(dc, &request, CollectFont,
                       reinterpret_cast<LPARAM>(&catalog), 0);
    ReleaseDC(nullptr, dc);
    if (catalog.invalid || catalog.families.empty()) {
      result->Error("font_catalog", "系统字体列表无效或超过4096项");
      return;
    }
    flutter::EncodableList names;
    names.reserve(catalog.families.size());
    for (const auto& name : catalog.families) names.emplace_back(name);
    result->Success(flutter::EncodableValue(names));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    ShowWindow(GetHandle(), startup_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // WM_DESTROY follows the framework's accepted close, never a cancelled close.
  SavePlacement();
  if (child_subclassed_ && flutter_controller_) {
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(), ChildWindowProc, 1);
    child_subclassed_ = false;
  }
  explorer_drop_.reset();
  if (secure_unlock_) { secure_unlock_->SetMethodCallHandler(nullptr); secure_unlock_ = nullptr; }
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_ = nullptr;
  }
  if (font_catalog_) {
    font_catalog_->SetMethodCallHandler(nullptr);
    font_catalog_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The resize border must precede Flutter's HTCLIENT result. The view child
  // also hands these points through, otherwise the parent never receives them.
  if (message == WM_NCHITTEST && integrated_frame_) {
    return FrameHitTest({GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)});
  }
  // The base WM_DESTROY handler clears its HWND before calling OnDestroy.
  // Capture accepted-close geometry while this handle still exists.
  if (message == WM_DESTROY) SavePlacement();
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
    case WM_NCCALCSIZE:
      if (integrated_frame_ && wparam != FALSE) {
        // Keep the native resize/min/max/system-menu styles, remove only the
        // duplicated caption area. Maximized client geometry stays in rcWork.
        if (IsZoomed(hwnd)) {
          MONITORINFO monitor = {sizeof(MONITORINFO)};
          if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) break;
          reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0] = monitor.rcWork;
        }
        return 0;
      }
      break;
    case WM_GETMINMAXINFO:
      if (integrated_frame_) {
        const UINT dpi = GetDpiForWindow(hwnd);
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        info->ptMinTrackSize.x = MulDiv(720, dpi, 96);
        info->ptMinTrackSize.y = MulDiv(540, dpi, 96);
        return 0;
      }
      break;
    case WM_ACTIVATE:
    case WM_DWMCOMPOSITIONCHANGED:
      if (integrated_frame_) {
        const MARGINS margins = {1, 1, 1, 1};
        DwmExtendFrameIntoClientArea(hwnd, &margins);
      }
      break;
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
