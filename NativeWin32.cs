using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace ClipQueue
{
    public static class NativeWin32
    {
        public const int WH_KEYBOARD_LL      = 13;
        public const int WM_KEYDOWN          = 0x0100;
        public const int WM_SYSKEYDOWN       = 0x0104;
        public const int VK_CONTROL          = 0x11;
        public const int VK_C                = 0x43;
        public const int VK_V                = 0x56;
        public const int VK_X                = 0x58;

        public const int WM_RENDERFORMAT     = 0x0305;
        public const int WM_RENDERALLFORMATS = 0x0306;
        public const int WM_DESTROYCLIPBOARD = 0x0307;
        public const int WM_CLIPBOARDUPDATE  = 0x031D;

        public const uint CF_UNICODETEXT     = 13;
        public const uint GMEM_MOVEABLE      = 0x0002;

        private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        private const uint SWP_NOMOVE     = 0x0002;
        private const uint SWP_NOSIZE     = 0x0001;
        private const uint SWP_NOACTIVATE = 0x0010;

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
        private static readonly LowLevelKeyboardProc _proc = HookCallback;
        private static IntPtr _hookId = IntPtr.Zero;

        private static int _pasteCount = 0;
        private static long _lastCopyTick = 0;
        private static long _lastPasteTick = 0;

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AddClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OpenClipboard(IntPtr hWndNewOwner);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseClipboard();

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EmptyClipboard();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalLock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalUnlock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalFree(IntPtr hMem);

        public static void EnforceTopMostNoActivate(IntPtr hwnd)
        {
            if (hwnd != IntPtr.Zero)
            {
                SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            }
        }

        public static bool SetDelayedClipboard(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return false;
            if (!OpenClipboard(hwnd)) return false;
            try
            {
                EmptyClipboard();
                SetClipboardData(CF_UNICODETEXT, IntPtr.Zero);
                return true;
            }
            finally
            {
                CloseClipboard();
            }
        }

        public static bool RenderUnicodeTextToClipboard(string text)
        {
            string val = text ?? string.Empty;
            int byteCount = (val.Length + 1) * 2;
            IntPtr hGlobal = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)byteCount);
            if (hGlobal == IntPtr.Zero) return false;

            IntPtr ptr = GlobalLock(hGlobal);
            if (ptr == IntPtr.Zero)
            {
                GlobalFree(hGlobal);
                return false;
            }

            try
            {
                if (val.Length > 0)
                {
                    Marshal.Copy(val.ToCharArray(), 0, ptr, val.Length);
                }
                Marshal.WriteInt16(ptr, val.Length * 2, 0);
            }
            finally
            {
                GlobalUnlock(hGlobal);
            }

            IntPtr res = SetClipboardData(CF_UNICODETEXT, hGlobal);
            if (res == IntPtr.Zero)
            {
                GlobalFree(hGlobal);
                return false;
            }
            return true;
        }

        public static bool InstallKeyboardHook()
        {
            if (_hookId != IntPtr.Zero) return true;
            using (Process curProcess = Process.GetCurrentProcess())
            using (ProcessModule curModule = curProcess.MainModule)
            {
                IntPtr hMod = curModule != null ? GetModuleHandle(curModule.ModuleName) : IntPtr.Zero;
                _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, hMod, 0);
            }
            return _hookId != IntPtr.Zero;
        }

        public static void UninstallKeyboardHook()
        {
            if (_hookId != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hookId);
                _hookId = IntPtr.Zero;
            }
        }

        public static int ConsumePasteCount()
        {
            return Interlocked.Exchange(ref _pasteCount, 0);
        }

        public static bool WasCopyKeyPressedRecently(int withinMs)
        {
            long last = Interlocked.Read(ref _lastCopyTick);
            if (last == 0) return false;
            int diff = unchecked(Environment.TickCount - (int)last);
            return diff >= 0 && diff <= withinMs;
        }

        private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN))
            {
                int vkCode = Marshal.ReadInt32(lParam);
                bool ctrlDown = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
                if (ctrlDown)
                {
                    if (vkCode == VK_V)
                    {
                        int now = Environment.TickCount;
                        long prev = Interlocked.Read(ref _lastPasteTick);
                        if (prev == 0 || unchecked(now - (int)prev) > 60)
                        {
                            Interlocked.Exchange(ref _lastPasteTick, now);
                            Interlocked.Increment(ref _pasteCount);
                        }
                    }
                    else if (vkCode == VK_C || vkCode == VK_X)
                    {
                        Interlocked.Exchange(ref _lastCopyTick, Environment.TickCount);
                    }
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }
    }
}
