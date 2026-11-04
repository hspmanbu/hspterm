#include "secure_unlock.h"
#include <windows.h>
#include <wincrypt.h>
#include <dpapi.h>
#include <bcrypt.h>
#include <shlobj.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr size_t kMaxSecret = 4096;
constexpr size_t kMaxCipher = 65536;
constexpr std::array<uint8_t, 8> kMagic = {'H','S','P','D','P','0','0','1'};
using Bytes = std::vector<uint8_t>;
void Require(bool yes, const char* error) { if (!yes) throw std::runtime_error(error); }
struct Secret {
  Bytes bytes;
  ~Secret() { if (!bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size()); }
};
struct LocalBlob {
  DATA_BLOB data = {};
  ~LocalBlob() { if (data.pbData != nullptr) { SecureZeroMemory(data.pbData, data.cbData); LocalFree(data.pbData); } }
};
struct File {
  HANDLE handle;
  explicit File(HANDLE value) : handle(value) {}
  File(const File&) = delete;
  File& operator=(const File&) = delete;
  void Close() { HANDLE value = handle; handle = INVALID_HANDLE_VALUE; Require(CloseHandle(value) != FALSE, "无法关闭便捷解锁缓存文件"); }
  void Reset() noexcept { if (handle != INVALID_HANDLE_VALUE) { CloseHandle(handle); handle = INVALID_HANDLE_VALUE; } }
  ~File() { Reset(); }
};
struct Temporary {
  std::wstring path;
  File* owner;
  bool published = false;
  ~Temporary() { if (!published) { owner->Reset(); DeleteFileW(path.c_str()); } }
};
bool Missing(DWORD error) { return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND; }
void Directory(const std::wstring& path, bool create) {
  DWORD attrs = GetFileAttributesW(path.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES && Missing(GetLastError())) {
    if (!create) return;
    Require(CreateDirectoryW(path.c_str(), nullptr) != FALSE || GetLastError() == ERROR_ALREADY_EXISTS, "无法创建本机解锁缓存目录");
    attrs = GetFileAttributesW(path.c_str());
  }
  Require(attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0 && (attrs & FILE_ATTRIBUTE_REPARSE_POINT) == 0, "本机解锁缓存目录不可用或包含链接");
}
std::wstring CacheDirectory(bool create) {
  PWSTR raw = nullptr;
  const HRESULT status = SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &raw);
  std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> folder(raw, CoTaskMemFree);
  Require(SUCCEEDED(status) && folder != nullptr, "无法获取 Windows 本机应用目录");
  std::wstring root(folder.get());
  // Extended paths also handle long/Unicode Windows profile directories.
  if (root.rfind(L"\\\\?\\", 0) != 0) {
    if (root.rfind(L"\\\\", 0) == 0) root = L"\\\\?\\UNC\\" + root.substr(2);
    else root = L"\\\\?\\" + root;
  }
  root += L"\\HSPTerm"; Directory(root, create);
  root += L"\\SecureUnlock"; Directory(root, create);
  return root;
}
std::wstring CachePath(const std::string& token, bool create) {
  Require(token.size() == 64 && std::all_of(token.begin(), token.end(), [](unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }), "配置库解锁标识无效");
  return CacheDirectory(create) + L"\\" + std::wstring(token.begin(), token.end()) + L".dpapi";
}
Bytes ReadCache(const std::wstring& path, bool missing_ok) {
  File file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (file.handle == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    if (missing_ok && Missing(error)) return {};
    throw std::runtime_error("当前库没有可用的 Windows 解锁缓存，请手动输入主密码");
  }
  BY_HANDLE_FILE_INFORMATION info = {};
  Require(GetFileInformationByHandle(file.handle, &info) != FALSE && (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0, "解锁缓存不是普通文件");
  LARGE_INTEGER length = {};
  Require(GetFileSizeEx(file.handle, &length) != FALSE && length.QuadPart >= 12 && length.QuadPart <= static_cast<LONGLONG>(kMaxCipher + 12), "解锁缓存损坏，请手动解锁后重新启用");
  Bytes data(static_cast<size_t>(length.QuadPart));
  DWORD count = 0;
  Require(ReadFile(file.handle, data.data(), static_cast<DWORD>(data.size()), &count, nullptr) != FALSE && count == data.size(), "无法完整读取解锁缓存");
  Require(std::equal(kMagic.begin(), kMagic.end(), data.begin()), "解锁缓存版本不支持");
  const uint32_t size = static_cast<uint32_t>(data[8]) | (static_cast<uint32_t>(data[9]) << 8) | (static_cast<uint32_t>(data[10]) << 16) | (static_cast<uint32_t>(data[11]) << 24);
  Require(size > 0 && size <= kMaxCipher && data.size() == static_cast<size_t>(size) + 12, "解锁缓存长度无效");
  return Bytes(data.begin() + 12, data.end());
}
void WriteCache(const std::string& token, const DATA_BLOB& encrypted) {
  Require(encrypted.cbData > 0 && encrypted.cbData <= kMaxCipher, "Windows 保护数据超过缓存容量");
  const auto target = CachePath(token, true);
  const DWORD old = GetFileAttributesW(target.c_str());
  Require(old == INVALID_FILE_ATTRIBUTES || (old & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0, "解锁缓存目标不是普通文件");
  std::array<uint8_t, 16> random = {};
  Require(BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0, "无法生成缓存临时标识");
  std::wstring name = CacheDirectory(true) + L"\\stage-";
  constexpr wchar_t digits[] = L"0123456789abcdef";
  for (uint8_t c : random) { name += digits[c >> 4]; name += digits[c & 15]; }
  name += L".tmp";
  File file(CreateFileW(name.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
  Require(file.handle != INVALID_HANDLE_VALUE, "无法创建私有解锁缓存临时文件");
  Temporary staging{name, &file};
  Bytes data(kMagic.begin(), kMagic.end());
  for (unsigned i = 0; i < 4; ++i) data.push_back(static_cast<uint8_t>((encrypted.cbData >> (i * 8)) & 255));
  data.insert(data.end(), encrypted.pbData, encrypted.pbData + encrypted.cbData);
  DWORD count = 0;
  Require(WriteFile(file.handle, data.data(), static_cast<DWORD>(data.size()), &count, nullptr) != FALSE && count == data.size() && FlushFileBuffers(file.handle) != FALSE, "无法完整保存 Windows 保护后的缓存");
  file.Close();
  Require(MoveFileExW(name.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE, "无法发布解锁缓存；原缓存保留");
  staging.published = true;
}
const flutter::EncodableValue& Field(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  Require(it != map.end(), "缺少便捷解锁参数"); return it->second;
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSecureUnlockChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "hspterm/windows_unlock", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    try {
      const auto* args = call.arguments();
      const auto* map = args == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(args);
      Require(map != nullptr, "便捷解锁参数无效");
      const auto* token = std::get_if<std::string>(&Field(*map, "token"));
      Require(token != nullptr, "解锁标识无效");
      const auto path = CachePath(*token, false);
      Bytes entropy(token->begin(), token->end());
      constexpr char domain[] = "HSPTerm Windows account unlock v1";
      entropy.insert(entropy.end(), domain, domain + sizeof(domain) - 1);
      DATA_BLOB extra = {static_cast<DWORD>(entropy.size()), entropy.data()};
      const auto& method = call.method_name();
      if (method == "available") {
        result->Success(flutter::EncodableValue(!ReadCache(path, true).empty())); return;
      }
      if (method == "remove") {
        const DWORD attrs = GetFileAttributesW(path.c_str());
        if (attrs == INVALID_FILE_ATTRIBUTES && Missing(GetLastError())) { result->Success(); return; }
        Require(attrs != INVALID_FILE_ATTRIBUTES && (attrs & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0 && DeleteFileW(path.c_str()) != FALSE, "无法删除当前库的本机解锁缓存");
        result->Success(); return;
      }
      if (method == "protect") {
        const auto* input = std::get_if<Bytes>(&Field(*map, "password"));
        Require(input != nullptr && !input->empty() && input->size() <= kMaxSecret, "便捷解锁密码须为1至4096个UTF-8字节");
        Secret secret{*input}; DATA_BLOB plain = {static_cast<DWORD>(secret.bytes.size()), secret.bytes.data()}; LocalBlob encrypted;
        Require(CryptProtectData(&plain, L"HSPTerm Windows account unlock", &extra, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &encrypted.data) != FALSE, "Windows 无法保护解锁数据；未保存明文");
        WriteCache(*token, encrypted.data); result->Success(); return;
      }
      if (method == "unprotect") {
        Bytes encrypted = ReadCache(path, false); DATA_BLOB input = {static_cast<DWORD>(encrypted.size()), encrypted.data()}; LocalBlob plain;
        Require(CryptUnprotectData(&input, nullptr, &extra, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &plain.data) != FALSE, "当前 Windows 账户无法解锁此缓存，请手动输入主密码");
        Require(plain.data.cbData > 0 && plain.data.cbData <= kMaxSecret, "解锁缓存正文无效，请手动输入主密码");
        Secret secret{Bytes(plain.data.pbData, plain.data.pbData + plain.data.cbData)};
        result->Success(flutter::EncodableValue(secret.bytes)); return;
      }
      result->NotImplemented();
    } catch (const std::exception& error) { result->Error("windows_unlock", error.what()); }
  });
  return channel;
}
