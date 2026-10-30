SpeakerKeeper quick start
=========================

Extract the entire repository, including tools/, into a writable folder.
Download SoundKeeper separately: https://veg.by/projects/soundkeeper
Place SoundKeeper64.exe beside SpeakerKeeper.ps1, or set a custom path in settings.txt.

CLI: 1_test_run.bat; 2_add_to_startup.bat; 3_remove_from_startup.bat.
Optional GUI: Launch-GUI.vbs. Close hides to tray; choose Exit in the tray to stop.
GUI startup: 4_add_gui_to_startup.bat; 5_remove_gui_from_startup.bat.
CLI and GUI startup registrations are separate; explicitly disable one before enabling the other.

settings.txt is optional and personal. Copy settings.example.txt for CLI tuning,
or use Save in the GUI to create it. Defaults: 300 Hz, 0.1% amplitude, 30-second linger.
Existing preferences are preserved. Choose an app/device in the GUI; the chosen device
must be the Windows default output. The selection does not change Windows routing.

See README.md and README_GUI.md for setup, attribution, diagnostics, and validation limitations.
SpeakerKeeper by shiro23437; original MIT license retained. SoundKeeper by Evgeny Vrublevsky.
