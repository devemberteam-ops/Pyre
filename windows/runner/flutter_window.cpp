#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Pyre crash-hardening (2026-06-05): decline WM_GETOBJECT BEFORE the engine sees it,
  // so Flutter's reactive accessibility bridge never auto-enables. That bridge has an
  // unguarded weak_ptr deref (present in engine 3.44.0 through master) that null-derefs on
  // ordinary interaction once ANY UIA/MSAA probe (Narrator idle-probe, touch keyboard,
  // TSF/IME, in-box UIA client (not just a screen reader) flips semantics on. It is an
  // ALL-USERS 0xc0000005 crash (flutter_windows.dll +0x1d7b0 / +0x3a9fa). See
  // docs/superpowers/mega-audit-2026-06-05-crash-rootcause.md. TRADEOFF: this turns OFF the
  // Windows accessibility tree (screen readers can't read widgets; the window stays
  // focusable/usable). Accepted to stop the crash; revisit when the engine guards the deref.
  if (message == WM_GETOBJECT) {
    return 0;
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
    case WM_FONTCHANGE:
      // Guard against a teardown race: a stray WM_FONTCHANGE can arrive after
      // OnDestroy() has reset flutter_controller_ to null, in which case the
      // stock `flutter_controller_->engine()` would be a null deref. Cheap
      // defense-in-depth (flutter/flutter#183313 spirit).
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
