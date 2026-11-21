# Sonder

A local desktop app that uses SpotiSaver for individual Spotify track links. Paste a link in Sonder to download a matching MP3 and separate it with Kim Vocal 2. The download runs in the background. You can also choose or drop an audio file directly. Sonder saves `original.mp3`, `vocals.mp3`, and `instrumental.mp3` at 320 kbps under `Music\Sonder\<song name>\` by default.

Use **Settings → Save to → Browse** to change the parent folder for new tracks. Sonder remembers your choice.

## Windows installer

Download **Sonder-Setup.exe** from the repository's **Releases** page for 64-bit Windows 10 and 11. It installs Sonder, Kim Vocal 2, and the audio runtime, with a Start menu entry and an optional desktop shortcut. If Microsoft Edge WebView2 is missing, setup installs it using Microsoft's bundled bootstrapper. Microsoft's Visual C++ installer runs only if a runtime update is needed.

The installer is unsigned. Windows Smart App Control or an organization's Application Control policy may block it.

To build the installer, run **desktop/build-installer.ps1** with the Inno Setup compiler, official Windows x64 embedded Python 3.10.11 ZIP, Microsoft Visual C++ x64 redistributable, and WebView2 Evergreen Bootstrapper. The build uses the workspace's Python 3.10 environment by default and accepts a local wheel directory for an offline build. Set up the UVR source tree with **run.bat** and place **Kim_Vocal_2.onnx** in **vendor/uvr-headless-master/models/MDX_Net_Models**.

## Setup (Windows)

Close any old Sonder window and double-click `outputs\Sonder.exe`. Keep the executable with this workspace. It uses the existing Python environment and model files and opens its own Windows window.

For a fresh setup:

1. Install Python 3.10 and run `run.bat` once to install the Python dependencies and UVR source tree. Stop that server before opening the desktop app.
2. Run `desktop\setup-gpu.ps1` in PowerShell to install and check Sonder's CUDA runtime. The script uses the CUDA and cuDNN DLLs in `D:\Ultimate Vocal Remover\torch\lib`.
3. Open the executable and paste an individual Spotify track link into Studio.
4. Check **Kim Vocal 2** in Settings. Sonder warms the GPU when it opens and shows the active provider. MP3 export uses FFmpeg on PATH or the copy in `D:\Ultimate Vocal Remover`.

The app does not require a Telegram account. Downloads run through SpotiSaver and audio separation runs locally. If this workspace was used with an older build, keep its existing `data/` folder private.

## Notes

- SpotiSaver matches tracks from independent audio sources. If a match is unavailable or interactive verification is required, the app reports it in Studio. You can also use **Choose an audio file** for local audio.
- The GPU runtime and model weights may require an internet connection for setup. After setup, separation runs locally on the GPU.
