#include "explorer_drop.h"
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <ole2.h>
#include <shlobj.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace {
constexpr wchar_t kDropOwnerProperty[] = L"HSPTerm.ExplorerDropOwner.v1";
struct DropReservation {
  HWND view;
  HANDLE owner;
  bool held = false;
  DropReservation(HWND window, void* identity)
      : view(window), owner(reinterpret_cast<HANDLE>(identity)) {
    held = view && GetPropW(view, kDropOwnerProperty) == nullptr &&
        SetPropW(view, kDropOwnerProperty, owner) != FALSE;
  }
  ~DropReservation() {
    if (held && GetPropW(view, kDropOwnerProperty) == owner) {
      RemovePropW(view, kDropOwnerProperty);
    }
  }
  DropReservation(const DropReservation&) = delete;
  DropReservation& operator=(const DropReservation&) = delete;
};
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Channel = flutter::MethodChannel<Value>;
const Value* Field(const Map* map, const char* key) {
  if (!map) return nullptr;
  const auto it = map->find(Value(key));
  return it == map->end() ? nullptr : &it->second;
}
const std::string* Text(const Map* map, const char* key) {
  const auto* value = Field(map, key);
  return value ? std::get_if<std::string>(value) : nullptr;
}
struct Medium {
  STGMEDIUM value = {};
  ~Medium() { if (value.tymed != TYMED_NULL) ReleaseStgMedium(&value); }
};
struct Locked {
  HGLOBAL memory;
  void* data;
  explicit Locked(HGLOBAL h) : memory(h), data(GlobalLock(h)) {}
  ~Locked() { if (data) GlobalUnlock(memory); }
};
// Request only bounded Unicode CF_HDROP names, never FILECONTENTS or filesystem
// traversal. An external IDataObject may itself implement delayed name delivery.
bool Paths(IDataObject* object, List* paths) {
  FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  Medium medium;
  if (!object || FAILED(object->GetData(&format, &medium.value)) ||
      medium.value.tymed != TYMED_HGLOBAL || !medium.value.hGlobal) return false;
  const auto size = GlobalSize(medium.value.hGlobal);
  if (size < sizeof(DROPFILES) + 2 * sizeof(wchar_t) || size > 4 * 1024 * 1024) return false;
  Locked locked(medium.value.hGlobal);
  if (!locked.data) return false;
  DROPFILES header;
  std::memcpy(&header, locked.data, sizeof(header));
  if (!header.fWide || header.pFiles < sizeof(DROPFILES) ||
      header.pFiles % alignof(wchar_t) != 0 || header.pFiles >= size ||
      (size - header.pFiles) % sizeof(wchar_t) != 0) return false;
  const auto* names = reinterpret_cast<const wchar_t*>(
      static_cast<const unsigned char*>(locked.data) + header.pFiles);
  const size_t available = (size - header.pFiles) / sizeof(wchar_t);
  size_t cursor = 0, utf8_bytes = 0;
  while (cursor < available) {
    if (names[cursor] == L'\0') return !paths->empty();
    const auto start = cursor;
    while (cursor < available && names[cursor] != L'\0') ++cursor;
    const auto length = cursor - start;
    if (cursor == available || length == 0 || length > 32767 || paths->size() >= 4096) return false;
    const std::wstring path(names + start, length);
    const bool drive = length >= 3 && ((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) &&
        path[1] == L':' && (path[2] == L'\\' || path[2] == L'/');
    const bool unc = length >= 5 && path[0] == L'\\' && path[1] == L'\\' && path[2] != L'?' && path[2] != L'.';
    if (!drive && !unc) return false;
    const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
        static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0 || utf8_bytes + static_cast<size_t>(bytes) > 4 * 1024 * 1024) return false;
    std::string utf8(static_cast<size_t>(bytes), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(), static_cast<int>(length),
        utf8.data(), bytes, nullptr, nullptr) != bytes) return false;
    paths->emplace_back(std::move(utf8));
    utf8_bytes += static_cast<size_t>(bytes);
    ++cursor;
  }
  return false;  // Missing the second terminating NUL.
}
struct State {
  HWND view = nullptr;
  std::unique_ptr<Channel> channel;
  bool alive = true, registered = false, offered = false;
  RECT bounds = {};
  std::string zone, owner, bound_owner;
  int64_t drag = 0, sequence = 0;
  bool in_flight = false;
  std::unique_ptr<Map> latest;
  Map Event(const char* kind, POINT point) const {
    return {{Value("kind"), Value(kind)}, {Value("zone"), Value(zone)},
        {Value("owner"), Value(owner)}, {Value("drag"), Value(drag)},
        {Value("x"), Value(static_cast<double>(point.x))},
        {Value("y"), Value(static_cast<double>(point.y))}};
  }
  void Emit(Map event) {
    if (alive && channel) channel->InvokeMethod("event", std::make_unique<Value>(std::move(event)));
  }
  void FlushHover() {
    if (!alive || in_flight || !latest || !channel) return;
    if (sequence == std::numeric_limits<int64_t>::max()) { latest.reset(); return; }
    auto event = std::move(*latest); latest.reset();
    event.emplace(Value("sequence"), Value(++sequence));
    in_flight = true;
    try { Emit(std::move(event)); } catch (...) { in_flight = false; throw; }
  }
  void Hover(POINT point, const char* kind = "hover") { latest = std::make_unique<Map>(Event(kind, point)); FlushHover(); }
  DWORD Effect(DWORD offered_effects, POINTL screen, POINT* client) {
    *client = {screen.x, screen.y};
    if (!alive || !registered || !offered || zone.empty() || owner.empty() ||
        !(offered_effects & DROPEFFECT_COPY) || !ScreenToClient(view, client) || !PtInRect(&bounds, *client)) return DROPEFFECT_NONE;
    if (bound_owner.empty()) bound_owner = owner;
    return bound_owner == owner ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  }
};
class Target final : public IDropTarget {
 public:
  explicit Target(std::shared_ptr<State> state) : state_(std::move(state)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IDropTarget)) { *value = static_cast<IDropTarget*>(this); AddRef(); return S_OK; }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override { const ULONG left = --references_; if (!left) delete this; return left; }
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL point, DWORD* effect) override {
    if (!effect) return E_POINTER;
    try {
      auto& s = *state_;
      s.bound_owner.clear(); s.latest.reset();
      if (s.drag == std::numeric_limits<int64_t>::max()) { *effect = DROPEFFECT_NONE; return S_OK; }
      ++s.drag;
      FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
      s.offered = data && data->QueryGetData(&format) == S_OK;
      return DragOver(0, point, effect);
    } catch (...) { *effect = DROPEFFECT_NONE; return E_FAIL; }
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL point, DWORD* effect) override {
    if (!effect) return E_POINTER;
    try {
      POINT client = {};
      *effect = state_->Effect(*effect, point, &client);
      if (*effect == DROPEFFECT_COPY) state_->Hover(client);
      else state_->Hover(client, "outside");
      return S_OK;
    } catch (...) { *effect = DROPEFFECT_NONE; return E_FAIL; }
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    try {
      auto& s = *state_;
      s.latest.reset(); s.Emit(s.Event("leave", POINT{})); s.bound_owner.clear(); s.offered = false;
      return S_OK;
    } catch (...) { return E_FAIL; }
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL point, DWORD* effect) override {
    if (!effect) return E_POINTER;
    const auto allowed = *effect; *effect = DROPEFFECT_NONE;
    try {
      auto& s = *state_;
      POINT client = {};
      if (s.Effect(allowed, point, &client) != DROPEFFECT_COPY) { DragLeave(); return S_OK; }
      const auto owner = s.owner, zone = s.zone;
      const auto drag = s.drag;
      s.offered = false;  // Delivery is single-use even if GetData/encoding fails.
      List paths;
      const bool valid = Paths(data, &paths);
      // GetData may enter a COM message pump. Do not publish onto a new tab or
      // directory after reentrant Flutter routing/bounds updates or shutdown.
      if (!s.alive || s.owner != owner || s.zone != zone || s.drag != drag) return S_OK;
      if (!valid) { s.latest.reset(); s.Emit(s.Event("invalid", client)); return S_OK; }
      auto event = s.Event("drop", client); event.emplace(Value("paths"), Value(std::move(paths)));
      s.latest.reset(); s.Emit(std::move(event)); s.offered = false;
      *effect = DROPEFFECT_COPY;  // Accepted for queuing; never ask Explorer to delete a source.
      return S_OK;
    } catch (...) { return E_FAIL; }
  }
 private:
  std::atomic<ULONG> references_{1};
  std::shared_ptr<State> state_;
};
struct TargetRelease {
  void operator()(Target* target) const { if (target) target->Release(); }
};
}  // namespace

struct ExplorerDropBridge::Impl {
  std::shared_ptr<State> state = std::make_shared<State>();
  std::unique_ptr<Target, TargetRelease> target;
  DropReservation reservation;
  Impl(flutter::BinaryMessenger* messenger, HWND view) : reservation(view, this) {
    state->view = view;
    // The maintained super_native_extensions fork checks this reservation
    // before creating its DropContext. Reserve before RegisterPlugins so that
    // the first outgoing drag cannot revoke this application's inbound target.
    if (!reservation.held) return;
    state->channel = std::make_unique<Channel>(messenger, "hspterm/explorer_drop", &flutter::StandardMethodCodec::GetInstance());
    target.reset(new Target(state));
    auto s = state;
    state->channel->SetMethodCallHandler([this, s](const auto& call, auto result) {
      try {
        const auto* args = call.arguments();
        const auto* map = args ? std::get_if<Map>(args) : nullptr;
        if (call.method_name() == "ackMove") {
          const auto* value = Field(map, "sequence");
          if (value && (std::holds_alternative<int32_t>(*value) || std::holds_alternative<int64_t>(*value)) &&
              value->LongValue() == s->sequence) { s->in_flight = false; s->FlushHover(); }
        } else if (call.method_name() == "clear") {
          s->zone.clear(); s->owner.clear(); s->bounds = {}; s->latest.reset();
        } else if (call.method_name() == "bind") {
          if (GetPropW(s->view, kDropOwnerProperty) != reinterpret_cast<HANDLE>(this)) {
            result->Error("drop_owner", "窗口文件拖放所有权已改变；未替换其他接收器"); return;
          }
          const auto* zone = Text(map, "zone"); const auto* owner = Text(map, "owner");
          const auto* rect_value = Field(map, "rect");
          const auto* rect = rect_value ? std::get_if<List>(rect_value) : nullptr;
          if (!zone || zone->empty() || zone->size() > 128 || !owner || owner->empty() || owner->size() > 256 ||
              !rect || rect->size() != 4) { result->Error("drop_region", "文件拖放区域无效"); return; }
          double edges[4] = {};
          for (size_t i = 0; i < 4; ++i) {
            const auto* edge = std::get_if<double>(&(*rect)[i]);
            if (!edge || !std::isfinite(*edge) || *edge < -100000 || *edge > 100000) {
              result->Error("drop_region", "文件拖放区域无效"); return;
            }
            edges[i] = *edge;
          }
          if (edges[0] >= edges[2] || edges[1] >= edges[3]) { result->Error("drop_region", "文件拖放区域无效"); return; }
          if (!s->registered) {
            if (FAILED(RegisterDragDrop(s->view, target.get()))) { result->Error("drop_register", "无法启用Explorer拖放；仍可使用上传按钮"); return; }
            s->registered = true;
          }
          s->bounds = {static_cast<LONG>(std::floor(edges[0])), static_cast<LONG>(std::floor(edges[1])),
              static_cast<LONG>(std::ceil(edges[2])), static_cast<LONG>(std::ceil(edges[3]))};
          s->zone = *zone; s->owner = *owner;
        } else { result->NotImplemented(); return; }
        result->Success();
      } catch (...) { result->Error("drop_failure", "文件拖放操作未确认；未请求删除本地来源"); }
    });
  }
  ~Impl() {
    state->alive = false;
    state->latest.reset();
    if (state->channel) state->channel->SetMethodCallHandler(nullptr);
    if (reservation.held && GetPropW(state->view, kDropOwnerProperty) == reinterpret_cast<HANDLE>(this)) {
      if (state->registered) RevokeDragDrop(state->view);
    }
    state->registered = false; state->channel.reset();
    // The initial target reference retires after this body; late COM references
    // retain only the inactive shared State, never the window/engine owner.
  }
};
ExplorerDropBridge::ExplorerDropBridge(flutter::BinaryMessenger* messenger, HWND view)
    : impl_(std::make_unique<Impl>(messenger, view)) {}
ExplorerDropBridge::~ExplorerDropBridge() = default;
bool ExplorerDropBridge::IsReady() const { return impl_->reservation.held; }
