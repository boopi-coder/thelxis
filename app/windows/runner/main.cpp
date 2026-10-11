#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Window class registered by win32_window.cpp.
constexpr wchar_t kRunnerWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// One instance per Windows session ("Local\\"): a second launch must not start
// another listener on the same ports, it just surfaces the running window.
// The installer's AppMutex may use either form: "Local\\io.thelxis.app.single-instance"
// or the bare "io.thelxis.app.single-instance" name the system resolves to the
// same session-local object.
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\io.thelxis.app.single-instance";

bool HasArgument(const std::vector<std::string>& arguments,
                 const std::string& wanted) {
  for (const std::string& argument : arguments) {
    if (argument == wanted) {
      return true;
    }
  }
  return false;
}

void ActivateExistingWindow() {
  // Matched by class only: the title can change at runtime, and FindWindow
  // also finds a window that is hidden to the tray.
  HWND existing = ::FindWindowW(kRunnerWindowClassName, nullptr);
  if (existing == nullptr) {
    return;
  }
  ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // A launch with --minimized (start at login) must stay invisible; any
    // other second launch brings the running window to the front.
    if (!HasArgument(GetCommandLineArguments(), "--minimized")) {
      ActivateExistingWindow();
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool start_hidden = HasArgument(command_line_arguments, "--minimized");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetStartHidden(start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1200, 800);
  if (!window.Create(L"Thelxis", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance != nullptr) {
    ::CloseHandle(single_instance);
  }
  return EXIT_SUCCESS;
}
