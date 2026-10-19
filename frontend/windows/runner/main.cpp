#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <atomic>
#include <string>
#include <thread>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr char kSmokeShutdownEventPrefix[] =
    "--leadpilot-test-shutdown-event=";

std::string GetSmokeShutdownEventName(
    const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (argument.rfind(kSmokeShutdownEventPrefix, 0) == 0) {
      return argument.substr(sizeof(kSmokeShutdownEventPrefix) - 1);
    }
  }
  return std::string();
}

std::vector<std::string> GetDartArguments(
    const std::vector<std::string>& arguments) {
  std::vector<std::string> dart_arguments;
  for (const auto& argument : arguments) {
    if (argument.rfind(kSmokeShutdownEventPrefix, 0) != 0) {
      dart_arguments.push_back(argument);
    }
  }
  return dart_arguments;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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

  const std::string smoke_shutdown_event_name =
      GetSmokeShutdownEventName(command_line_arguments);
  project.set_dart_entrypoint_arguments(GetDartArguments(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"leadpilot_frontend", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // The normal production lifecycle is still driven by WM_CLOSE. The named
  // event is an explicit smoke-test-only control path for service sessions
  // where PowerShell cannot address the window through CloseMainWindow().
  // The runner converts the signal into the same WM_CLOSE message used by a
  // real user closing the window, so the Flutter and native teardown paths are
  // exercised without changing the production launcher behavior.
  HANDLE smoke_shutdown_event = nullptr;
  std::atomic<bool> message_loop_running{true};
  std::thread smoke_shutdown_thread;
  if (!smoke_shutdown_event_name.empty()) {
    smoke_shutdown_event = OpenEventA(SYNCHRONIZE, FALSE,
                                      smoke_shutdown_event_name.c_str());
    if (smoke_shutdown_event == nullptr) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    smoke_shutdown_thread = std::thread([&window, smoke_shutdown_event,
                                         &message_loop_running]() {
      while (message_loop_running.load()) {
        const DWORD result = WaitForSingleObject(smoke_shutdown_event, 100);
        if (result == WAIT_OBJECT_0) {
          HWND window_handle = window.GetHandle();
          if (window_handle != nullptr) {
            PostMessage(window_handle, WM_CLOSE, 0, 0);
          }
          return;
        }
        if (result == WAIT_FAILED) {
          return;
        }
      }
    });
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  message_loop_running.store(false);
  if (smoke_shutdown_thread.joinable()) {
    smoke_shutdown_thread.join();
  }
  if (smoke_shutdown_event != nullptr) {
    CloseHandle(smoke_shutdown_event);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
