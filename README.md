# ClipQueue (Standalone Windows `.exe`)

A floating, always-on-top sequential clipboard manager (FIFO queue) for Windows 10 and 11, compiled automatically by GitHub Actions into a **single standalone `ClipQueue.exe`**—no browser tabs, no ZIP extraction, no PowerShell scripts.

## Direct Download
Download **`ClipQueue.exe`** directly from **Releases** (right sidebar) and double-click to run.

## Key Features
- **Works with BOTH `Ctrl+V` AND Right-Click → Paste:** Uses native Windows Delayed Clipboard Rendering (`WM_RENDERFORMAT`) + a low-level keyboard hook (`WH_KEYBOARD_LL`) so pasting via keyboard *or* right-click automatically erases the pasted item and loads the next item in order.
- **Standalone Native App:** Single `.exe` with embedded Fluent Glass app icon and System Tray support.
- **Borderless & Resizable:** Drag any of the 4 edges or 4 corners to resize, or double-click the header bar to collapse into a Mini Pill showing only the next item to paste.
