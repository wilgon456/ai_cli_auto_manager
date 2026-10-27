// Each launched CLI has a non-inheritable Job handle owned by the manager. Closing the handle
// on command completion, manager exit or crash also terminates surviving grandchildren.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;
namespace Aicm {
    public sealed class ContainedProcess : IDisposable {
        internal IntPtr Job;
        public Process Process { get; internal set; }
        public void Dispose() {
            if (Job != IntPtr.Zero) { ProcessJob.Release(Job); Job = IntPtr.Zero; }
            GC.SuppressFinalize(this);
        }
        ~ContainedProcess() { Dispose(); }
    }
    public static class ProcessJob {
        static IntPtr job;
        [StructLayout(LayoutKind.Sequential)] struct Basic {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct Io {
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)] struct Extended {
            public Basic Basic;
            public Io Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref Extended info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [StructLayout(LayoutKind.Sequential)] struct Security {
            public int Length;
            public IntPtr Descriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup {
            public int Size;
            public string Reserved, Desktop, Title;
            public uint X, Y, Width, Height, CharsX, CharsY, Fill, Flags;
            public ushort Show, ReservedSize;
            public IntPtr ReservedData, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
            public IntPtr Process, Thread;
            public uint Id, ThreadId;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFile(string file, uint access, uint share, ref Security security,
            uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string app, StringBuilder line, IntPtr processAttributes,
            IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
            ref Startup startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint code);
        internal static void Release(IntPtr handle) { CloseHandle(handle); }
        static IntPtr NewJob() {
            IntPtr handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new Win32Exception();
            var info = new Extended(); info.Basic.Flags = 0x2000;
            if (!SetInformationJobObject(handle, 9, ref info, (uint)Marshal.SizeOf(info))) {
                int error = Marshal.GetLastWin32Error(); CloseHandle(handle); throw new Win32Exception(error);
            }
            return handle;
        }
        // Suspend BEFORE any user code executes, assign to its non-inheritable Job, then resume.
        // A failed assignment terminates the suspended child; an uncontained command never runs.
        public static ContainedProcess Start(string exe, string arguments, string stdout, string stderr) {
            IntPtr handle = NewJob(), output = IntPtr.Zero, error = IntPtr.Zero, input = IntPtr.Zero;
            var info = new ProcessInfo();
            bool success = false;
            try {
                var security = new Security { Length = Marshal.SizeOf(typeof(Security)), Inherit = true };
                output = CreateFile(stdout, 0x40000000, 3, ref security, 2, 0x80, IntPtr.Zero);
                error = CreateFile(stderr, 0x40000000, 3, ref security, 2, 0x80, IntPtr.Zero);
                input = CreateFile("NUL", 0x80000000, 3, ref security, 3, 0x80, IntPtr.Zero);
                if (output == new IntPtr(-1) || error == new IntPtr(-1) || input == new IntPtr(-1)) throw new Win32Exception();
                var startup = new Startup { Size = Marshal.SizeOf(typeof(Startup)), Flags = 0x100,
                    Input = input, Output = output, Error = error };
                string app = exe, line = "\"" + exe + "\" " + arguments;
                if (String.Equals(Path.GetExtension(exe), ".cmd", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(Path.GetExtension(exe), ".bat", StringComparison.OrdinalIgnoreCase)) {
                    app = Environment.GetEnvironmentVariable("ComSpec") ?? Path.Combine(Environment.SystemDirectory, "cmd.exe");
                    line = "\"" + app + "\" /d /s /c \"\"" + exe + "\" " + arguments + "\"";
                }
                if (!CreateProcess(app, new StringBuilder(line), IntPtr.Zero, IntPtr.Zero, true,
                    0x08000004, IntPtr.Zero, null, ref startup, out info)) throw new Win32Exception();
                if (!AssignProcessToJobObject(handle, info.Process)) throw new Win32Exception();
                var process = Process.GetProcessById((int)info.Id);
                // Capture the process handle before a fast command can exit.
                var ignored = process.Handle;
                if (ResumeThread(info.Thread) == UInt32.MaxValue) { process.Dispose(); throw new Win32Exception(); }
                success = true;
                return new ContainedProcess { Job = handle, Process = process };
            } finally {
                if (!success && info.Process != IntPtr.Zero) TerminateProcess(info.Process, 125);
                if (!success) CloseHandle(handle);
                foreach (var h in new [] { output, error, input, info.Thread, info.Process })
                    if (h != IntPtr.Zero && h != new IntPtr(-1)) CloseHandle(h);
            }
        }

        public static void Initialize() {
            if (job != IntPtr.Zero) return;
            IntPtr handle = NewJob();
            if (!AssignProcessToJobObject(handle, Process.GetCurrentProcess().Handle)) {
                int error = Marshal.GetLastWin32Error(); CloseHandle(handle);
                throw new Win32Exception(error, "Cannot contain manager process; refusing uncontained CLI launch");
            }
            job = handle; // deliberately kept for the complete process lifetime
        }
    }
}
