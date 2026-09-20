// run-hidden.exe - launch a command with NO console window.
// Purpose: replacement for run-hidden-task.vbs (VBScript is being deprecated by Windows).
// Usage:   run-hidden.exe <program> [args...]
// Exits with 0 if the process was created, or the Win32 error code otherwise.
// NOTE: keep this file pure ASCII (compiled by csc.exe, which may read ANSI).
//
// !!! MUST COMPILE WITH /target:winexe !!!
// ---------------------------------------------------------------------------
// 2026-09-18 20:30  REGRESSION FIX - read this before rebuilding.
// The first build used csc's default (/target:exe), which produces a CONSOLE
// subsystem binary. When Task Scheduler (svchost, which has no console) starts
// a console-subsystem exe, Windows allocates a NEW CONSOLE WINDOW for it.
// That window flashed on the primary monitor for ~59 ms and stole focus every
// 5 minutes (DSH_Watchdog), which the user reported as "screen flickers and
// steals my mouse". CREATE_NO_WINDOW below only covers the CHILD process; it
// does nothing for the console of run-hidden.exe itself.
//
// Correct build command (csc ships with Windows, no SDK needed):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe ^
//       /nologo /target:winexe /optimize+ /out:run-hidden.exe run-hidden.cs
//
// Verify after building (2 = GUI/no console, 3 = Console = WILL flash):
//   read the PE header: e_lfanew at 0x3C, Subsystem = WORD at e_lfanew + 0x5C
// ---------------------------------------------------------------------------

using System;
using System.Text;
using System.Runtime.InteropServices;

internal static class RunHidden
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    // The process runs without a console window (no window is ever created).
    private const uint CREATE_NO_WINDOW = 0x08000000;

    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            return 2;
        }

        StringBuilder cmd = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0)
            {
                cmd.Append(' ');
            }
            cmd.Append(Quote(args[i]));
        }

        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));

        PROCESS_INFORMATION pi;
        bool ok = CreateProcessW(
            args[0],
            cmd,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            CREATE_NO_WINDOW,
            IntPtr.Zero,
            null,
            ref si,
            out pi);

        if (!ok)
        {
            return Marshal.GetLastWin32Error();
        }

        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return 0;
    }

    // Inverse of CommandLineToArgvW quoting rules.
    private static string Quote(string s)
    {
        bool needsQuotes = s.Length == 0;
        foreach (char ch in s)
        {
            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\v' || ch == '"')
            {
                needsQuotes = true;
                break;
            }
        }
        if (!needsQuotes)
        {
            return s;
        }

        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        foreach (char ch in s)
        {
            if (ch == '\\')
            {
                backslashes++;
                continue;
            }
            if (ch == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
            }
            else
            {
                sb.Append('\\', backslashes);
                sb.Append(ch);
            }
            backslashes = 0;
        }
        sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }
}
