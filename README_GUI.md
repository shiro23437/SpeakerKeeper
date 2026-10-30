# SpeakerKeeper — Optional desktop GUI

A Windows-only WPF front end for [SpeakerKeeper by shiro23437](https://github.com/shiro23437/SpeakerKeeper), using the same PowerShell audio-monitoring engine. The existing CLI workflow remains available. Original MIT licensing and attribution are retained.

## Install and launch

1. Extract the entire repository, including `tools/`, to a writable folder. Windows 10/11 with Windows PowerShell 5.1 and WPF is required. No PowerShell module installation is needed.
2. Download a trusted SoundKeeper executable separately from [the author's website](https://veg.by/projects/soundkeeper). Put `SoundKeeper64.exe` alongside the scripts, or set `SoundKeeper=` to a matching executable name/path for your architecture. No third-party binaries are included in the contribution.
3. Double-click `Launch-GUI.vbs`. It launches Windows PowerShell with `-NoProfile -STA` and hides the console. If Windows has disabled VBScript/Windows Script Host, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\SpeakerKeeper-GUI.ps1` from this folder instead.
4. Choose the application and output device, adjust settings, and click **設定を保存** (Save).

`settings.txt` is optional. GUI Save creates it; CLI users can copy `settings.example.txt`. Missing files use the upstream defaults: 300 Hz, 0.1% amplitude, 30-second linger, and a 0.001 threshold. Both modes share a parser with invariant-culture numbers and finite-value/range validation. Existing values, unknown keys, comments, and custom SoundKeeper paths are retained when saving. Settings writes use a temporary file and atomic replacement; the running engine reloads changes. Deleting the file restores defaults. Personal settings and temporary settings files are excluded from Git.

## Upgrading an older checkout

Older versions tracked `settings.txt`; this contribution removes it from version control. Before updating/replacing an old checkout, keep a copy of your personal file outside the checkout and restore it afterward. Git may refuse the update when that tracked file has local changes; preserve those changes rather than discarding them. Restored `settings.txt` is ignored by Git. The app does not overwrite an existing personal file on startup, and GUI Save retains existing/custom values.

## Controls and behavior

- **監視を開始 / 監視を停止** starts/stops the GUI-owned worker. Both CLI and GUI use the same engine mutex. If another engine is already running, the new worker exits and the GUI returns to Stopped; inspect the console, stop the CLI, then start GUI monitoring. The GUI never claims ownership of the existing CLI worker.
- The application selector lists visible desktop processes by process name. Empty `AppName` means all apps. Lists are loaded on first opening and can be refreshed after launching an app or connecting a device. Remembered values remain available when absent from a list.
- The device selector uses active Windows playback endpoints. **すべての出力デバイス** means any default output. A selected device is a name filter on the **current default playback device**, not a Windows routing change. Existing partial-name filters remain valid. Identically named devices are grouped by name.
- Themes: **ライト / ダーク / システム** (Light/Dark/System). System follows the Windows app color setting while running. Preferences are stored in `%LOCALAPPDATA%\NZXT-Relay-Keeper\gui.json` for compatibility with earlier GUI versions. The dropdowns deliberately retain light surfaces with dark text for native Windows-template contrast.
- **Console / 動作履歴** shows the last 120 messages. Logs refresh only while expanded and visible. `%LOCALAPPDATA%\NZXT-Relay-Keeper\SpeakerKeeper.log` rotates at 1 MiB, retaining one `.old` file. A missing/inaccessible SoundKeeper executable produces actionable diagnostics, suppresses repeated identical errors, and retries at most once every 30 seconds while audio is active. Recovery is automatic after the dependency becomes available; saving settings resets the retry delay.
- Closing the window hides it to the notification area. The tray menu can show the window, toggle monitoring, or **終了** (Exit). Normal exit signals and waits for its worker; forced cleanup is restricted to that worker and its SoundKeeper children.

## CLI and GUI startup

The original `1_test_run.bat`, `2_add_to_startup.bat`, and `3_remove_from_startup.bat` continue to run/register/remove the CLI. CLI removal also stops this installation's CLI engine and its children, never unrelated SoundKeeper processes or GUI workers.

GUI startup uses its checkbox or **`4_add_gui_to_startup.bat`** (register and launch in the tray). **`5_remove_gui_from_startup.bat`** unregisters GUI startup; it does not stop a running GUI. Exit through the tray menu. `tools/gui-startup.ps1 -Mode add -Launch` and `-Mode remove` are the equivalent script entry points.

The normal GUI shortcut is `SpeakerKeeper GUI.lnk`; an owned legacy `NZXT Relay Keeper.lnk` is reused. `SpeakerKeeper.lnk` remains the CLI shortcut. Enabling either mode refuses to replace the other mode's shortcut. Disable the old registration explicitly before enabling the other mode. Same-name shortcuts for another installation are not overwritten or deleted. Existing settings and shortcuts are not silently migrated. Stop the currently running engine when switching modes; the shared mutex prevents duplicate monitoring.

## Validation and known limitations

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Validate.ps1` for isolated regression checks. These parse the scripts and check defaults, first save/reload, preservation of configuration, locale handling, missing/failed dependency retry and recovery, log rotation, startup ownership using fake shortcuts, and scoped CLI process cleanup using fake processes. Both embedded C# interop declarations are also compiled without calling Windows APIs. They do not operate Windows Startup, WPF, or audio devices.

Preparation checks passed locally on Linux with a temporary PowerShell 7.4.6 runtime: all PowerShell files parsed, both C# interop blocks compiled, and the isolated regression checks passed. XAML XML parsing/named-control checks and the scoped Git whitespace check also passed. No Windows GUI/audio execution was performed.

Before marking the upstream PR ready, validate on Windows PowerShell 5.1:

- Launch normally and with `--minimized`, show/hide from the tray, stop/start monitoring, duplicate launch, and Exit. Check the selected colors and layout in all themes.
- First run with no personal settings, Save, reload, edit the CLI file, remove it, and preserve existing/custom values.
- Register/remove CLI and GUI startup separately, verify sign-in launch, conflict diagnostics, and protection of unrelated/legacy shortcuts.
- Verify active-device listing, default-device switching, selected-app/system audio, and SoundKeeper exclusion. Verify linger timing, graceful and forced child cleanup, missing/inaccessible dependency diagnostics, bounded logs, and recovery.

Windows GUI execution, Windows Script Host/shortcut integration, real child-process handling, sign-in behavior, and audio/hardware behavior are unverified in the Linux preparation environment. PowerShell 7 syntax/logic checks on Linux do not establish Windows PowerShell 5.1 runtime compatibility. The first wake-up fade-in after complete silence is still possible; SoundKeeper can affect automatic system sleep while active. A crash or external forced termination cannot guarantee cleanup. Windows installation/policies must permit scripts and, for the VBS launcher, Windows Script Host.
