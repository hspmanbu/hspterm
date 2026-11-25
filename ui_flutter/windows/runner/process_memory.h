#ifndef HSPTERM_PROCESS_MEMORY_H_
#define HSPTERM_PROCESS_MEMORY_H_

#include <windows.h>
#include <psapi.h>
#include <stdint.h>

#include <array>

// Aggregate counters only. Page addresses are used locally for queries and
// are never returned to Dart or logged.
struct ProcessAddressSpace {
  uint64_t private_kib = 0;
  uint64_t image_kib = 0;
  uint64_t mapped_kib = 0;
  uint64_t write_combined_kib = 0;
  uint64_t write_combined_resident_kib = 0;
  uint64_t write_combined_locked_kib = 0;
  bool complete = false;
  bool residency_complete = false;
};

inline ProcessAddressSpace ReadProcessAddressSpace(HANDLE process) {
  constexpr size_t kMaxRegions = 65536;
  constexpr size_t kMaxWriteCombinedPages = 512 * 1024;
  std::array<PSAPI_WORKING_SET_EX_INFORMATION, 2048> pages{};
  size_t pending = 0;
  size_t sampled = 0;
  SYSTEM_INFO system{};
  GetSystemInfo(&system);
  const uintptr_t page_size = system.dwPageSize;
  const auto end = reinterpret_cast<uintptr_t>(system.lpMaximumApplicationAddress);
  auto address = reinterpret_cast<uintptr_t>(system.lpMinimumApplicationAddress);
  ProcessAddressSpace result;
  if (page_size == 0) return result;
  result.residency_complete = true;

  const auto flush_pages = [&] {
    if (!pending || !result.residency_complete) return;
    if (!QueryWorkingSetEx(process, pages.data(),
                           static_cast<DWORD>(sizeof(pages[0]) * pending))) {
      result.residency_complete = false;
      return;
    }
    for (size_t i = 0; i < pending; ++i) {
      const auto flags = pages[i].VirtualAttributes;
      if (flags.Valid && (flags.Win32Protection & PAGE_WRITECOMBINE)) {
        result.write_combined_resident_kib += page_size / 1024;
        if (flags.Locked) result.write_combined_locked_kib += page_size / 1024;
      }
    }
    pending = 0;
  };

  for (size_t i = 0; i < kMaxRegions && address <= end; ++i) {
    MEMORY_BASIC_INFORMATION region{};
    if (VirtualQuery(reinterpret_cast<LPCVOID>(address), &region,
                     sizeof(region)) != sizeof(region)) break;
    const auto base = reinterpret_cast<uintptr_t>(region.BaseAddress);
    const auto next = base + region.RegionSize;
    if (next <= base || next <= address) break;
    address = next;
    if (region.State != MEM_COMMIT) continue;
    const uint64_t kib = region.RegionSize / 1024;
    switch (region.Type) {
      case MEM_IMAGE: result.image_kib += kib; break;
      case MEM_MAPPED: result.mapped_kib += kib; break;
      case MEM_PRIVATE: result.private_kib += kib; break;
    }
    // The Windows trace showed the renderer's large allocations here.
    // Write-combined memory is still a page classification, not a GPU total.
    if (region.Type != MEM_PRIVATE || !(region.Protect & PAGE_WRITECOMBINE)) {
      continue;
    }
    result.write_combined_kib += kib;
    const auto count = region.RegionSize / page_size;
    if (!result.residency_complete || count > kMaxWriteCombinedPages - sampled) {
      result.residency_complete = false;
      continue;
    }
    sampled += count;
    for (auto page = base; page < next; page += page_size) {
      pages[pending++].VirtualAddress = reinterpret_cast<PVOID>(page);
      if (pending == pages.size()) flush_pages();
      if (!result.residency_complete) break;
    }
  }
  result.complete = address > end;
  if (result.complete) flush_pages();
  result.residency_complete = result.complete && result.residency_complete;
  return result;
}

struct ProcessMemorySample {
  uint64_t working_set_kib = 0, peak_working_set_kib = 0;
  uint64_t private_kib = 0, peak_private_kib = 0;
  uint64_t private_working_set_kib = 0, shared_commit_kib = 0;
  uint64_t handles = 0, cpu_us = 0, uptime_ms = 0, page_faults = 0;
  uint64_t system_commit_kib = 0, system_commit_limit_kib = 0;
  uint64_t system_available_kib = 0, scan_ms = 0;
  bool extended_available = false, system_available = false;
  ProcessAddressSpace address_space;
};
inline bool ReadProcessMemorySample(ProcessMemorySample* sample) {
  // PROCESS_MEMORY_COUNTERS_EX2 extends this prefix on current Windows 11.
  // Older SDKs may lack the declaration and older OS builds reject its size.
  struct {
    PROCESS_MEMORY_COUNTERS_EX prefix;
    SIZE_T private_working_set;
    ULONG64 shared_commit;
  } extended{};
  auto& memory = extended.prefix;
  auto* counters = reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&extended);
  FILETIME created{}, exited{}, kernel{}, user{};
  DWORD handles = 0;
  const HANDLE process = GetCurrentProcess();
  sample->uptime_ms = GetTickCount64();
  memory.cb = static_cast<DWORD>(sizeof(extended));
  sample->extended_available =
      GetProcessMemoryInfo(process, counters, memory.cb) != FALSE;
  if (!sample->extended_available) {
    memory.cb = static_cast<DWORD>(sizeof(memory));
    if (!GetProcessMemoryInfo(process, counters, memory.cb)) return false;
  }
  if (!GetProcessHandleCount(process, &handles) ||
      !GetProcessTimes(process, &created, &exited, &kernel, &user)) return false;
  const auto ticks = [](const FILETIME& value) -> uint64_t {
    return (static_cast<uint64_t>(value.dwHighDateTime) << 32) |
           value.dwLowDateTime;
  };
  sample->working_set_kib = memory.WorkingSetSize / 1024;
  sample->peak_working_set_kib = memory.PeakWorkingSetSize / 1024;
  sample->private_kib = memory.PrivateUsage / 1024;
  sample->peak_private_kib = memory.PeakPagefileUsage / 1024;
  sample->private_working_set_kib = extended.private_working_set / 1024;
  sample->shared_commit_kib = extended.shared_commit / 1024;
  sample->handles = handles;
  sample->cpu_us = (ticks(kernel) + ticks(user)) / 10;
  sample->page_faults = memory.PageFaultCount;
  PERFORMANCE_INFORMATION system{};
  system.cb = static_cast<DWORD>(sizeof(system));
  sample->system_available = GetPerformanceInfo(&system, system.cb) != FALSE;
  if (sample->system_available) {
    sample->system_commit_kib = system.CommitTotal * (system.PageSize / 1024);
    sample->system_commit_limit_kib = system.CommitLimit * (system.PageSize / 1024);
    sample->system_available_kib = system.PhysicalAvailable * (system.PageSize / 1024);
  }
  sample->address_space = ReadProcessAddressSpace(process);
  sample->scan_ms = GetTickCount64() - sample->uptime_ms;
  return true;
}
#endif
