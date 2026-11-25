#include "flutter_window.h"

#include <optional>
#include <set>
#include <algorithm>
#include <cmath>
#include <dbt.h>
#include <dwmapi.h>
#include <windowsx.h>
#include <shlobj.h>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include "utils.h"
#include "secure_unlock.h"
#include "process_memory.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
struct FontCatalog {
  std::set<std::string> families;
  bool invalid = false;
};

// WM_TIMER id and timeout for the render-health watchdog armed by
// ArmRenderHealthCheck when the GPU/display environment changes.
constexpr UINT_PTR kRenderHealthTimerId = 0x48535054;  // "HSPT"
constexpr UINT kRenderHealthTimeoutMs = 10000;

// Reveals |path| in Explorer via the documented shell API: opens the parent
// folder with the item preselected, reusing the shell's own window. This is
// the reliable replacement for `explorer /select,...` whose exit code is
// meaningless (a reused Explorer process exits with 1 even on success).
bool RevealInExplorer(const std::wstring& path) {
  // Parse an ordinary filesystem path, never a slash-mixed shell namespace.
  std::wstring native = path;
  std::replace(native.begin(), native.end(), L'/', L'\\');
  PIDLIST_ABSOLUTE item = ILCreateFromPathW(native.c_str());
  if (item == nullptr) return false;
  PIDLIST_ABSOLUTE parent = ILCloneFull(item);
  if (parent == nullptr || !ILRemoveLastID(parent)) {
    if (parent != nullptr) ILFree(parent);
    ILFree(item);
    return false;
  }
  PCUITEMID_CHILD child = ILFindLastID(item);
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

// GPU driver updates while the app runs remove the D3D device the Flutter
// Windows engine renders through; the engine then stops presenting forever
// (Dart logic and timers keep running, but no frame is ever drawn again), so
// the window stays blank. The runner cannot safely rebuild the engine's GPU
// stack from outside, so on the broadcast device/display notifications it
// asks the engine for one fresh frame and watches whether it presents within
// kRenderHealthTimeoutMs. When no frame arrives, the Flutter view cannot
// display anything any more — including any Dart-side dialog — so a NATIVE
// message box is the only visible channel left; it tells the user to restart.
// Healthy systems never see it: the next-frame callback fires promptly and
// disarms the watchdog.
// [UNVERIFIED native/platform] authored and statically checked on Linux;
// needs a real Windows 11 GPU driver update to validate end to end.
void FlutterWindow::ArmRenderHealthCheck() {
  if (render_check_armed_ || !flutter_controller_) return;
  render_check_armed_ = true;
  render_frame_seen_ = false;
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    render_frame_seen_ = true;
    if (render_check_armed_) {
      render_check_armed_ = false;
      KillTimer(GetHandle(), kRenderHealthTimerId);
    }
  });
  // Nudge one raster even when Dart would schedule no frame by itself.
  flutter_controller_->ForceRedraw();
  SetTimer(GetHandle(), kRenderHealthTimerId, kRenderHealthTimeoutMs, nullptr);
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
    } else if (method == "processMemory") {
      ProcessMemorySample memory{};
      if (!ReadProcessMemorySample(&memory)) {
        result->Error("process_memory", "无法读取当前进程内存统计"); return;
      }
      const auto number = [](uint64_t value) {
        return flutter::EncodableValue(static_cast<int64_t>(value));
      };
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("rssKiB"), number(memory.working_set_kib)},
        {flutter::EncodableValue("maxRssKiB"), number(memory.peak_working_set_kib)},
        {flutter::EncodableValue("privateKiB"), number(memory.private_kib)},
        {flutter::EncodableValue("peakPrivateKiB"), number(memory.peak_private_kib)},
        {flutter::EncodableValue("handles"), number(memory.handles)},
        {flutter::EncodableValue("cpuUs"), number(memory.cpu_us)},
        {flutter::EncodableValue("uptimeMs"), number(memory.uptime_ms)},
        {flutter::EncodableValue("impellerOptOut"),
         number(project_.impeller_switch() == flutter::ImpellerSwitch::Disabled)},
      }));
      return;
    } else if (method == "clipboardHasImage") {
      // Check actual Windows formats, before requesting synthesized PNG data.
      // An empty clipboard must not create an upload task or an empty image.
      const UINT png = RegisterClipboardFormatW(L"PNG");
      result->Success(flutter::EncodableValue(
          IsClipboardFormatAvailable(CF_DIB) ||
          IsClipboardFormatAvailable(CF_DIBV5) ||
          (png != 0 && IsClipboardFormatAvailable(png))));
      return;
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
    } else if (method == "reveal" || method == "openLocal") {
      // Keep filesystem paths out of URL routing. Reveal selects one child
      // in its explicit parent PIDL; open uses the Windows file association.
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
      wide.resize(static_cast<size_t>(wide_size - 1));
      std::replace(wide.begin(), wide.end(), L'/', L'\\');
      if (method == "openLocal") {
        SHELLEXECUTEINFOW info = {};
        info.cbSize = sizeof(info);
        info.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
        info.hwnd = window;
        info.lpVerb = L"open";
        info.lpFile = wide.c_str();
        info.nShow = SW_SHOWNORMAL;
        if (!ShellExecuteExW(&info)) {
          result->Error("open_error", "Windows未能打开本地路径，错误码" +
              std::to_string(GetLastError())); return;
        }
      } else if (!RevealInExplorer(wide)) {
        result->Error("reveal_failed", "Windows未能定位并选中文件"); return;
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
  // Disarm the render-health watchdog before the engine (and its pending
  // next-frame callback) goes away.
  render_check_armed_ = false;
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
  if (message == WM_DESTROY) {
    SavePlacement();
    if (render_check_armed_) {
      KillTimer(hwnd, kRenderHealthTimerId);
      render_check_armed_ = false;
    }
  }
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
    case WM_DISPLAYCHANGE:
      // Display-mode changes accompany GPU driver updates; verify the render
      // pipeline still presents (no-op when it does).
      ArmRenderHealthCheck();
      break;
    case WM_DEVICECHANGE:
      // DBT_DEVNODES_CHANGED (device re-enumeration during a driver install)
      // is broadcast to every top-level window; no RegisterDeviceNotification
      // needed. Other device events are ignored.
      if (wparam == DBT_DEVNODES_CHANGED) ArmRenderHealthCheck();
      break;
    case WM_TIMER:
      if (wparam == kRenderHealthTimerId) {
        KillTimer(hwnd, kRenderHealthTimerId);
        render_check_armed_ = false;
        // The engine did not present the requested frame within the timeout:
        // the D3D device was most likely removed by the driver update and the
        // Flutter view will never draw again. Only a native dialog is visible
        // in that state. Skip hidden/minimized windows (nothing blank to see,
        // and minimized views legitimately present no frames).
        if (!render_frame_seen_ && flutter_controller_ &&
            IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
          MessageBoxW(hwnd,
              L"检测到显卡驱动或显示配置已更新，本窗口的画面渲染可能已停止（内容空白）。\n\n"
              L"应用逻辑与后台 SSH 会话仍在运行，但界面需要重启应用才能恢复。\n\n"
              L"请在任务栏正常关闭本应用后重新启动；请先确认没有正在进行且不可中断的传输。",
              L"HSPTerm 显示恢复提示", MB_OK | MB_ICONWARNING);
        }
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
