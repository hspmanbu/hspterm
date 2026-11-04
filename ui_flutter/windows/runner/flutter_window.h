#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <commctrl.h>

#include <memory>

#include "win32_window.h"
#include "explorer_drop.h"

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
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> font_catalog_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> secure_unlock_;
  std::unique_ptr<ExplorerDropBridge> explorer_drop_;
  bool integrated_frame_ = false;
  RECT maximize_button_ = {};
  bool child_subclassed_ = false;
  bool startup_maximized_ = false;
  LRESULT FrameHitTest(POINT screen) const;
  void RestorePlacement();
  void SavePlacement();
  static LRESULT CALLBACK ChildWindowProc(HWND, UINT, WPARAM, LPARAM,
                                          UINT_PTR, DWORD_PTR);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
