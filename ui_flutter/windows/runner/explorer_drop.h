#ifndef RUNNER_EXPLORER_DROP_H_
#define RUNNER_EXPLORER_DROP_H_

#include <flutter/binary_messenger.h>
#include <windows.h>
#include <memory>

// Inbound Explorer files only. No remote execution, file content, or source
// deletion. The Flutter owner publishes an eligible physical client rectangle.
class ExplorerDropBridge {
 public:
  ExplorerDropBridge(flutter::BinaryMessenger* messenger, HWND view);
  ~ExplorerDropBridge();
  // Reserve HWND ownership before registering plugins that initialize their
  // own drop contexts, including outgoing-only virtual drags.
  bool IsReady() const;
  ExplorerDropBridge(const ExplorerDropBridge&) = delete;
  ExplorerDropBridge& operator=(const ExplorerDropBridge&) = delete;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
