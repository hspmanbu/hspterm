#ifndef HSPTERM_PROCESS_MEMORY_H_
#define HSPTERM_PROCESS_MEMORY_H_

#include <windows.h>
#include <dxgi1_4.h>
#include <psapi.h>
#include <stdint.h>
#include <wrl/client.h>

#include <array>
#include <cstring>

struct PrivateAllocationSizes {
  uint64_t small_kib = 0;
  uint64_t medium_kib = 0;
  uint64_t large_kib = 0;
  uint64_t largest_kib = 0;
  uint64_t large_count = 0;

  // Group by the initial allocation. A reserve or protection change can split
  // one allocation into several VirtualQuery regions.
  void Add(uint64_t committed_kib) {
    if (committed_kib > largest_kib) largest_kib = committed_kib;
    if (committed_kib >= 16 * 1024) {
      large_kib += committed_kib;
      ++large_count;
    } else if (committed_kib >= 1024) {
      medium_kib += committed_kib;
    } else {
      small_kib += committed_kib;
    }
  }
};

// Aggregate counters only. Page addresses are used locally for queries and
// are never returned to Dart or logged.
struct ProcessAddressSpace {
  uint64_t private_kib = 0;
  uint64_t image_kib = 0;
  uint64_t mapped_kib = 0;
  uint64_t write_combined_kib = 0;
  uint64_t write_combined_resident_kib = 0;
  uint64_t write_combined_locked_kib = 0;
  uint64_t private_reserved_kib = 0;
  uint64_t private_executable_kib = 0;
  PrivateAllocationSizes private_normal_allocations;
  bool complete = false;
  bool residency_complete = false;
};

inline ProcessAddressSpace ReadProcessAddressSpace(HANDLE process) {
  constexpr size_t kMaxRegions = 65536;
  constexpr size_t kMaxWriteCombinedPages = 512 * 1024;
  std::array<PSAPI_WORKING_SET_EX_INFORMATION, 2048> pages{};
  size_t pending = 0;
  size_t sampled = 0;
  const void* normal_allocation = nullptr;
  uint64_t normal_kib = 0;
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
    const uint64_t kib = region.RegionSize / 1024;
    if (region.State != MEM_COMMIT) {
      if (region.State == MEM_RESERVE && region.Type == MEM_PRIVATE) {
        result.private_reserved_kib += kib;
      }
      continue;
    }
    switch (region.Type) {
      case MEM_IMAGE: result.image_kib += kib; break;
      case MEM_MAPPED: result.mapped_kib += kib; break;
      case MEM_PRIVATE: result.private_kib += kib; break;
    }
    // The Windows trace showed the renderer's large allocations here.
    // Write-combined memory is still a page classification, not a GPU total.
    if (region.Type != MEM_PRIVATE) continue;
    if (!(region.Protect & PAGE_WRITECOMBINE)) {
      if (normal_allocation != region.AllocationBase) {
        result.private_normal_allocations.Add(normal_kib);
        normal_allocation = region.AllocationBase;
        normal_kib = 0;
      }
      normal_kib += kib;
      constexpr DWORD kExecutable = PAGE_EXECUTE | PAGE_EXECUTE_READ |
          PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
      if (region.Protect & kExecutable) result.private_executable_kib += kib;
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
  result.private_normal_allocations.Add(normal_kib);
  result.complete = address > end;
  if (result.complete) flush_pages();
  result.residency_complete = result.complete && result.residency_complete;
  return result;
}

template <class Function>
Function ResolveMemoryQuery(HMODULE module, const char* name) {
  const auto address = module != nullptr ? GetProcAddress(module, name) : nullptr;
  Function function = nullptr;
  // Function pointers and FARPROC have the same representation in Win32.
  static_assert(sizeof(function) == sizeof(address));
  std::memcpy(&function, &address, sizeof(function));
  return function;
}

struct ProcessHeapMemory {
  uint64_t allocated_kib = 0;
  uint64_t committed_kib = 0;
  uint64_t reserved_kib = 0;
  bool available = false;
};

inline ProcessHeapMemory ReadDefaultHeapMemory() {
  ProcessHeapMemory result;
  const auto summarize = ResolveMemoryQuery<decltype(&HeapSummary)>(
      GetModuleHandleW(L"kernel32.dll"), "HeapSummary");
  if (!summarize) return result;
  HEAP_SUMMARY heap{};
  heap.cb = static_cast<DWORD>(sizeof(heap));
  // Private heaps owned by other DLLs can be destroyed during sampling. The
  // default process heap has a stable lifetime and is safe to summarize.
  if (summarize(GetProcessHeap(), 0, &heap)) {
    result = {heap.cbAllocated / 1024, heap.cbCommitted / 1024,
              heap.cbReserved / 1024, true};
  }
  return result;
}

struct ProcessGpuMemory {
  uint64_t local_kib = 0;
  uint64_t nonlocal_kib = 0;
  unsigned sampled_adapters = 0;
  bool complete = false;
};

inline ProcessGpuMemory QueryDxgiMemory(HMODULE module) {
  using Microsoft::WRL::ComPtr;
  constexpr UINT kMaxAdapters = 16;
  ProcessGpuMemory result;
  const auto create = ResolveMemoryQuery<decltype(&CreateDXGIFactory1)>(
      module, "CreateDXGIFactory1");
  ComPtr<IDXGIFactory1> factory;
  if (!create || FAILED(create(IID_PPV_ARGS(factory.GetAddressOf())))) {
    return result;
  }
  bool failed = false;
  for (UINT index = 0; index < kMaxAdapters; ++index) {
    ComPtr<IDXGIAdapter1> adapter;
    const HRESULT status = factory->EnumAdapters1(index, adapter.GetAddressOf());
    if (status == DXGI_ERROR_NOT_FOUND) {
      result.complete = !failed && result.sampled_adapters > 0;
      break;
    }
    if (FAILED(status)) break;
    DXGI_ADAPTER_DESC1 description{};
    if (FAILED(adapter->GetDesc1(&description))) {
      failed = true;
      continue;
    }
    if (description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
    ComPtr<IDXGIAdapter3> current;
    DXGI_QUERY_VIDEO_MEMORY_INFO local{}, nonlocal{};
    if (FAILED(adapter.As(&current)) ||
        FAILED(current->QueryVideoMemoryInfo(
            0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local)) ||
        FAILED(current->QueryVideoMemoryInfo(
            0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &nonlocal))) {
      failed = true;
      continue;
    }
    ++result.sampled_adapters;
    result.local_kib += local.CurrentUsage / 1024;
    result.nonlocal_kib += nonlocal.CurrentUsage / 1024;
  }
  return result;
}

inline ProcessGpuMemory ReadProcessGpuMemory() {
  HMODULE module = nullptr;
  // Diagnose an existing graphics stack without loading DXGI or creating a
  // device. Retain the loaded DLL until all the short-lived COM objects retire.
  if (!GetModuleHandleExW(0, L"dxgi.dll", &module)) return {};
  const auto result = QueryDxgiMemory(module);
  FreeLibrary(module);
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
  ProcessHeapMemory default_heap;
  ProcessGpuMemory gpu;
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
  sample->default_heap = ReadDefaultHeapMemory();
  sample->gpu = ReadProcessGpuMemory();
  sample->scan_ms = GetTickCount64() - sample->uptime_ms;
  return true;
}
#endif
