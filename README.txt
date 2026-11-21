ClipQueue Final v4 for Windows (Stability & Clipboard Engine Overhaul)
======================================================================

WHAT'S FIXED IN FINAL V4:
1. No more ghost re-adding of old excerpts:
   - Uses native Windows WM_CLIPBOARDUPDATE + sequence tracking + self-write guards.
   - Keeps the last pasted text locked out when the queue empties so it can never
     re-appear on its own.
2. Reliable auto-remove on Ctrl+V (even fast taps):
   - Upgraded from polling to a native Win32 Low-Level Keyboard Hook (WH_KEYBOARD_LL)
     that catches every Ctrl+V press without lagging or missing rapid pastes.
3. Reliable priming after idle or busy apps:
   - Automatic background retry if another app momentarily locks the clipboard.
4. No more silent shutdowns or disappearing windows:
   - Fixed the WPF VisualTree crash when clicking text inside cards.
   - Added global crash protection, a non-focus-stealing Always-on-Top watchdog,
     and a Windows System Tray icon (click the tray icon anytime to bring ClipQueue
     to the front or reset its position).

HOW TO UPDATE:
1. Close any running ClipQueue window.
2. Extract "ClipQueue_Windows-Final-v4.zip" and replace ClipQueue.ps1 in your
   existing ClipQueue folder.
3. Launch ClipQueue from your Desktop shortcut (or run "Create_Desktop_Shortcut.bat").
