#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <ole2.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  // OLE drag/drop needs OleInitialize, not merely CoInitializeEx. Keep the
  // apartment alive until the Flutter window and all COM drop owners retire.
  if (FAILED(::OleInitialize(nullptr))) {
    MessageBoxW(nullptr, L"无法初始化Windows窗口服务", L"HSPTerm", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  struct OleLifetime { ~OleLifetime() { ::OleUninitialize(); } };
  [[maybe_unused]] OleLifetime ole_lifetime;

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"hspterm", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  BOOL status;
  while ((status = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  return status < 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}
