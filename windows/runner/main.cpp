#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <strsafe.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Pyre native crash capture.
//
// The Dart-side crash reporter (Analytics) cannot observe access violations
// that fault inside native code -- in particular inside flutter_windows.dll
// itself. We have confirmed (via minidump analysis) a recurring engine-internal
// access violation (0xc0000005) in the Windows window-message -> ANGLE/D3D11
// present / accessibility path. Every captured crash had the NVIDIA GeForce
// overlay (nvspcap64.dll, which hooks the DXGI present chain) and the reactive
// UI-Automation accessibility bridge loaded in-process.
//
// This last-chance filter records the faulting module+offset and a few
// "is a known interferer loaded?" flags to a plaintext log, so these otherwise
// invisible native crashes leave a trace we (and users) can read. It returns
// EXCEPTION_CONTINUE_SEARCH, so the OS still produces its normal WER minidump --
// the log is purely additive and changes no runtime behaviour.
//
// Log location: %LOCALAPPDATA%\Pyre\native_crash.log
LONG WINAPI PyreCrashFilter(EXCEPTION_POINTERS* info) {
  wchar_t dir[MAX_PATH];
  DWORD n = ::GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  wchar_t path[MAX_PATH];
  if (FAILED(::StringCchPrintfW(path, MAX_PATH, L"%s\\Pyre", dir))) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  ::CreateDirectoryW(path, nullptr);  // succeeds-or-already-exists; ignore error
  if (FAILED(::StringCchCatW(path, MAX_PATH, L"\\native_crash.log"))) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  HANDLE file = ::CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  ::SetFilePointer(file, 0, nullptr, FILE_END);

  char modpath[MAX_PATH] = "<unknown>";
  unsigned long long offset = 0;
  unsigned long long addr = 0;
  unsigned long code = 0;
  if (info != nullptr && info->ExceptionRecord != nullptr) {
    code = info->ExceptionRecord->ExceptionCode;
    addr = static_cast<unsigned long long>(
        reinterpret_cast<ULONG_PTR>(info->ExceptionRecord->ExceptionAddress));
    HMODULE mod = nullptr;
    if (::GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(info->ExceptionRecord->ExceptionAddress),
            &mod) &&
        mod != nullptr) {
      ::GetModuleFileNameA(mod, modpath, MAX_PATH);
      offset = addr - static_cast<unsigned long long>(
                          reinterpret_cast<ULONG_PTR>(mod));
    }
  }

  SYSTEMTIME st;
  ::GetLocalTime(&st);
  const char* nv = ::GetModuleHandleW(L"nvspcap64.dll") ? "yes" : "no";
  const char* nvd3d = ::GetModuleHandleW(L"nvwgf2umx.dll") ? "yes" : "no";
  const char* uia = ::GetModuleHandleW(L"UIAutomationCore.dll") ? "yes" : "no";

  char line[1200];
  if (SUCCEEDED(::StringCchPrintfA(
          line, ARRAYSIZE(line),
          "%04d-%02d-%02d %02d:%02d:%02d  code=0x%08lx  addr=0x%llx  "
          "module=%s+0x%llx  nvidia_overlay=%s  nvidia_d3d=%s  "
          "uia_accessibility=%s\r\n",
          st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, code,
          addr, modpath, offset, nv, nvd3d, uia))) {
    DWORD written = 0;
    ::WriteFile(file, line, static_cast<DWORD>(::lstrlenA(line)), &written,
                nullptr);
  }
  ::CloseHandle(file);
  return EXCEPTION_CONTINUE_SEARCH;
}

// Pyre "Stability mode" (Windows graphics crash-hardening).
//
// Some machines crash with an access violation inside flutter_windows.dll on
// the window-message -> ANGLE/D3D11 present / accessibility path. Every captured
// crash had BOTH the NVIDIA GeForce overlay (nvspcap64.dll, which hooks the
// shared DXGI Present chain) AND the reactive UI-Automation accessibility bridge
// loaded in-process. The D3D11 swapchain itself is owned inside the engine and
// is not reachable from this stock runner, but the embedder DOES expose a few
// pre-init knobs. When the user enables Stability mode (More -> About Pyre), the
// Dart side drops a marker file and we steer the engine, on the NEXT launch,
// onto the lower-risk paths:
//   * IAccessible (MSAA) instead of the reactive UIA fragment tree the overlay
//     pokes through its own UIA hooks (the hook present in every crash);
//   * the low-power GPU when one exists (an integrated GPU), which moves
//     rendering off the NVIDIA user-mode D3D driver whose Present chain the
//     overlay hooks. This is a no-op on single-GPU desktops (the engine falls
//     back to the only adapter), where the IAccessible change carries the fix.
//
// Default OFF: with no marker file the engine is configured exactly as a stock
// Flutter app, so non-affected users are completely unchanged.
//
// Marker: %LOCALAPPDATA%\Pyre\stability_mode.flag (created/removed by the app).
// It deliberately lives in the same fixed location as native_crash.log so the
// runner can read it before the Dart VM (and thus app settings) exist.
bool PyreStabilityModeEnabled() {
  wchar_t dir[MAX_PATH];
  DWORD n = ::GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return false;
  }
  wchar_t path[MAX_PATH];
  if (FAILED(::StringCchPrintfW(path, MAX_PATH,
                                L"%s\\Pyre\\stability_mode.flag", dir))) {
    return false;
  }
  return ::GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Install the native last-chance crash logger before anything else, so even a
  // crash during engine/plugin startup is recorded. See PyreCrashFilter above.
  ::SetUnhandledExceptionFilter(PyreCrashFilter);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Pyre Stability mode: opt-in, marker-file driven. See
  // PyreStabilityModeEnabled above. Steers the engine onto the lower-risk
  // accessibility + GPU paths to dodge the NVIDIA-overlay / UIA present-path
  // crash. No-op (stock engine config) when the marker file is absent.
  if (PyreStabilityModeEnabled()) {
    project.set_accessibility_mode(flutter::AccessibilityMode::IAccessible);
    project.set_gpu_preference(flutter::GpuPreference::LowPowerPreference);
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // Wave CY.18.47: window class name. The visible title comes from
  // window_manager in main.dart (we set it to "Pyre" there); this is
  // the Win32 internal class name used by Windows for taskbar
  // grouping etc. Match the brand.
  if (!window.Create(L"Pyre", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
