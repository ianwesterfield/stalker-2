using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ZoneXM.Notifications;

// Shell notification-area integration without a WinForms/WPF dependency.
internal sealed class NativeTray : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly nint window;
    private readonly Action open;
    private readonly Action exit;
    private readonly Action minimize;
    private readonly Action<string> log;
    private readonly SubclassProc callback;
    private readonly uint taskbarCreated;
    private NotifyIconData icon;
    private bool disposed;

    internal NativeTray(nint window, Action open, Action exit, Action minimize, Action<string> log)
    {
        this.window = window;
        this.open = open;
        this.exit = exit;
        this.minimize = minimize;
        this.log = log;
        callback = WindowProc;
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        if (taskbarCreated == 0) throw new Win32Exception();
        var image = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "Tray.ico"), 1, 0, 0, 0x10);
        if (image == 0) throw new Win32Exception();
        icon = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            Window = window,
            Id = 1,
            Flags = 1 | 2 | 4 | 0x80,
            Callback = CallbackMessage,
            Icon = image,
            Tip = "ZoneXM",
            Info = "",
            InfoTitle = ""
        };
        if (!SetWindowSubclass(window, callback, 1, 0))
        {
            DestroyIcon(image);
            throw new Win32Exception();
        }
        if (!AddIcon())
        {
            RemoveWindowSubclass(window, callback, 1);
            DestroyIcon(image);
            throw new Win32Exception();
        }
    }

    private bool AddIcon()
    {
        if (!ShellNotifyIcon(0, ref icon)) return false;
        icon.Timeout = 4; // NOTIFYICON_VERSION_4 enables keyboard selection/context menus.
        if (ShellNotifyIcon(4, ref icon)) return true;
        ShellNotifyIcon(2, ref icon);
        return false;
    }

    private nint WindowProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        try
        {
            if (message == taskbarCreated)
            {
                if (!AddIcon())
                {
                    log("Tray could not be restored after Explorer restarted; reopening window.");
                    open();
                    // Do not let the window become inaccessible if re-adding failed.
                    exitOnClose = true;
                }
            }
            else if (message == CallbackMessage)
            {
                var notification = (uint)lParam & 0xFFFF;
                if (notification is 0x203 or 0x202 or 0x400 or 0x401) open();
                else if (notification is 0x205 or 0x7B) ShowMenu();
                return 0;
            }
            else if (message == 0x5 && wParam == 1 && !exitOnClose) minimize();
            else if (message == 0x11) return 1; // Allow Windows shutdown.
            else if (message == 0x16 && wParam != 0) exit();
        }
        catch (Exception error)
        {
            log($"Tray operation failed ({error.GetType().Name}, 0x{error.HResult:X8}"
                + (error is Win32Exception native ? $", Win32={native.NativeErrorCode})." : ")."));
            ShowWindow(window, 9);
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private bool exitOnClose;
    internal bool Available => !disposed && !exitOnClose;

    private void ShowMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == 0) throw new Win32Exception();
        try
        {
            if (!AppendMenu(menu, 0, 1, "Open ZoneXM") || !AppendMenu(menu, 0, 2, "Exit")
                || !GetCursorPos(out var point)) throw new Win32Exception();
            SetForegroundWindow(window);
            Marshal.SetLastPInvokeError(0);
            var choice = TrackPopupMenu(menu, 0x100 | 0x2, point.X, point.Y, 0, window, 0);
            var error = Marshal.GetLastPInvokeError();
            if (choice == 0 && error != 0) throw new Win32Exception(error);
            PostMessage(window, 0, 0, 0);
            if (choice == 1) open();
            else if (choice == 2) exit();
        }
        finally { DestroyMenu(menu); }
    }

    internal static void ShowExisting()
    {
        var hwnd = FindWindow(null, "ZoneXM Companion");
        if (hwnd == 0) { ShowError("ZoneXM is already starting. Open it from the tray."); return; }
        ShowWindow(hwnd, 9);
        SetForegroundWindow(hwnd);
    }

    internal static void ShowError(string message) => MessageBox(0, message, "ZoneXM", 0x10);

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (!ShellNotifyIcon(2, ref icon)) log("Could not remove the ZoneXM tray icon.");
        if (!RemoveWindowSubclass(window, callback, 1)) log("Could not detach ZoneXM tray window callback.");
        DestroyIcon(icon.Icon);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        internal uint Size;
        internal nint Window;
        internal uint Id, Flags, Callback;
        internal nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Tip;
        internal uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Info;
        internal uint Timeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string InfoTitle;
        internal uint InfoFlags;
        internal Guid Guid;
        internal nint BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { internal int X, Y; }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint operation, ref NotifyIconData data);
    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint LoadImage(nint instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hwnd, nint rect);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint hwnd, int command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint FindWindow(string? className, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(nint hwnd, string text, string caption, uint flags);
}
