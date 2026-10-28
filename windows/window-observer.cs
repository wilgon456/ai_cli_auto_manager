// Read-only snapshots of process parent chains and top-level windows on the caller's desktop.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace AicmWindowObserver {
    public sealed class ProcessEntry {
        public uint Pid, Parent;
        public string Name;
    }
    public sealed class WindowEntry {
        public string Handle, ClassName;
        public uint OwnerPid, SessionId;
        public ProcessEntry[] ParentChain;
    }
    public static class Snapshot {
        const uint TH32CS_SNAPPROCESS = 2;
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct ProcessEntry32 {
            public uint Size, Usage, Pid;
            public UIntPtr DefaultHeap;
            public uint ModuleId, Threads, ParentPid;
            public int Priority;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Exe;
        }
        delegate bool EnumCallback(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback callback, IntPtr parameter);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32First(IntPtr snapshot, ref ProcessEntry32 entry);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry32 entry);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);

        public static ProcessEntry[] Processes() {
            IntPtr handle = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (handle == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
            var entries = new List<ProcessEntry>();
            try {
                var entry = new ProcessEntry32();
                entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry32));
                if (!Process32First(handle, ref entry)) throw new System.ComponentModel.Win32Exception();
                do { entries.Add(new ProcessEntry { Pid = entry.Pid, Parent = entry.ParentPid, Name = entry.Exe }); }
                while (Process32Next(handle, ref entry));
            } finally { CloseHandle(handle); }
            return entries.ToArray();
        }

        public static WindowEntry[] Windows(ProcessEntry[] processes) {
            var byPid = new Dictionary<uint, ProcessEntry>();
            foreach (var process in processes) byPid[process.Pid] = process;
            var windows = new List<WindowEntry>();
            EnumCallback callback = delegate(IntPtr hwnd, IntPtr ignored) {
                var name = new StringBuilder(256);
                if (GetClassName(hwnd, name, name.Capacity) == 0) return true;
                string kind = name.ToString();
                if (kind != "ConsoleWindowClass" && kind != "CASCADIA_HOSTING_WINDOW_CLASS" &&
                    kind != "PseudoConsoleWindow") return true;
                uint owner, session;
                GetWindowThreadProcessId(hwnd, out owner);
                if (!ProcessIdToSessionId(owner, out session)) session = UInt32.MaxValue;
                var chain = new List<ProcessEntry>();
                var seen = new HashSet<uint>();
                uint id = owner;
                ProcessEntry item;
                while (id != 0 && seen.Add(id) && chain.Count < 32 && byPid.TryGetValue(id, out item)) {
                    chain.Add(item);
                    id = item.Parent;
                }
                windows.Add(new WindowEntry { Handle = hwnd.ToInt64().ToString("X"), ClassName = kind,
                    OwnerPid = owner, SessionId = session, ParentChain = chain.ToArray() });
                return true;
            };
            if (!EnumWindows(callback, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
            GC.KeepAlive(callback);
            return windows.ToArray();
        }
    }
}
