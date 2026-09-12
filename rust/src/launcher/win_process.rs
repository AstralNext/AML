//! Windows helpers for spawning child processes without a console flash.

use tokio::process::Command;

/// Suppress the brief black console window when starting console-subsystem
/// programs (`java.exe`, `cmd.exe`, `powershell.exe`, …) on Windows.
pub fn hide_console_window(cmd: &mut Command) {
    #[cfg(windows)]
    {
        // CREATE_NO_WINDOW
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}
