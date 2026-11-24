#ifndef HSPTERM_PROCESS_MEMORY_H_
#define HSPTERM_PROCESS_MEMORY_H_

#include <windows.h>
#include <psapi.h>
#include <stdint.h>

// Current process only. PrivateUsage is committed private memory, not a
// measure of the Dart/Rust heap. No VM walk, handles, paths or user data.
struct ProcessMemorySample {
  uint64_t working_set_kib, peak_working_set_kib;
  uint64_t private_kib, peak_private_kib;
  uint64_t handles, cpu_us, uptime_ms;
};
inline bool ReadProcessMemorySample(ProcessMemorySample* sample) {
  PROCESS_MEMORY_COUNTERS_EX memory{};
  memory.cb = sizeof(memory);
  FILETIME created{}, exited{}, kernel{}, user{};
  DWORD handles = 0;
  const HANDLE process = GetCurrentProcess();
  if (!GetProcessMemoryInfo(process,
          reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory)) ||
      !GetProcessHandleCount(process, &handles) ||
      !GetProcessTimes(process, &created, &exited, &kernel, &user)) return false;
  const auto ticks = [](const FILETIME& value) -> uint64_t {
    return (static_cast<uint64_t>(value.dwHighDateTime) << 32) |
           value.dwLowDateTime;
  };
  *sample = {memory.WorkingSetSize / 1024, memory.PeakWorkingSetSize / 1024,
             memory.PrivateUsage / 1024, memory.PeakPagefileUsage / 1024,
             handles, (ticks(kernel) + ticks(user)) / 10, GetTickCount64()};
  return true;
}
#endif
