// Read-only snapshots of process parent chains and top-level windows on the caller's desktop.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

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

        internal static bool TrySession(uint pid, out uint session) {
            return ProcessIdToSessionId(pid, out session);
        }

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

    public sealed class WindowEvent {
        public long ElapsedMs;
        public WindowEntry Window;
        public bool Related;
    }
    public sealed class SampleResult {
        public long MaxIntervalMs;
        public int SampleCount;
        public uint[] Roots;
        public bool SameSession;
        public WindowEvent[] Events;
        public string Error;
    }

    // Sampling runs on its own native thread. Scheduler status calls in PowerShell can take
    // hundreds of milliseconds and must not pause EnumWindows between observations.
    public sealed class Sampler {
        readonly string executableName;
        readonly uint session;
        readonly HashSet<uint> previousIds = new HashSet<uint>();
        readonly HashSet<uint> roots = new HashSet<uint>();
        HashSet<string> seen = new HashSet<string>();
        readonly List<WindowEvent> events = new List<WindowEvent>();
        readonly ManualResetEvent stop = new ManualResetEvent(false);
        readonly ManualResetEvent ready = new ManualResetEvent(false);
        Thread thread;
        long maximumInterval;
        int sampleCount;
        bool sameSession = true;
        string error;

        static string WindowKey(WindowEntry window) {
            return window.Handle + ":" + window.OwnerPid + ":" + window.ClassName;
        }

        public Sampler(string executableName, uint session) {
            if (String.IsNullOrEmpty(executableName)) throw new ArgumentException("Missing executable name");
            this.executableName = executableName;
            this.session = session;
            var before = Snapshot.Processes();
            foreach (var process in before) {
                if (String.Equals(process.Name, executableName, StringComparison.OrdinalIgnoreCase))
                    previousIds.Add(process.Pid);
            }
            foreach (var window in Snapshot.Windows(before)) seen.Add(WindowKey(window));
        }

        public void Start() {
            if (thread != null) throw new InvalidOperationException("Sampler already started");
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
            if (!ready.WaitOne(5000)) throw new InvalidOperationException("Sampler did not start");
            if (error != null) throw new InvalidOperationException("Sampler could not observe the desktop: " + error);
        }

        void Run() {
            var clock = Stopwatch.StartNew();
            long next = 0, last = -1;
            try {
                while (!stop.WaitOne(0)) {
                    long now = clock.ElapsedMilliseconds;
                    if (last >= 0) maximumInterval = Math.Max(maximumInterval, now - last);
                    last = now;
                    var processes = Snapshot.Processes();
                    foreach (var process in processes) {
                        if (!String.Equals(process.Name, executableName, StringComparison.OrdinalIgnoreCase) || previousIds.Contains(process.Pid)) continue;
                        if (roots.Add(process.Pid)) {
                            uint processSession;
                            if (!Snapshot.TrySession(process.Pid, out processSession) || processSession != session) sameSession = false;
                        }
                    }
                    var current = new HashSet<string>();
                    foreach (var window in Snapshot.Windows(processes)) {
                        string key = WindowKey(window);
                        current.Add(key);
                        if (seen.Contains(key)) continue;
                        bool related = false;
                        foreach (var ancestor in window.ParentChain) if (roots.Contains(ancestor.Pid)) { related = true; break; }
                        if (events.Count >= 10000) throw new InvalidOperationException("Too many window events");
                        events.Add(new WindowEvent { ElapsedMs = now, Window = window, Related = related });
                    }
                    seen = current;
                    sampleCount++;
                    ready.Set();
                    next += 100;
                    long delay = next - clock.ElapsedMilliseconds;
                    if (delay > 0) { if (stop.WaitOne((int)Math.Min(delay, Int32.MaxValue))) break; }
                    else next = clock.ElapsedMilliseconds;
                }
            } catch (Exception ex) { error = ex.GetType().Name; }
            finally { ready.Set(); }
        }

        public SampleResult Stop() {
            if (thread == null) throw new InvalidOperationException("Sampler not started");
            stop.Set();
            if (!thread.Join(5000)) throw new InvalidOperationException("Sampler did not stop");
            var rootArray = new uint[roots.Count];
            roots.CopyTo(rootArray);
            return new SampleResult { MaxIntervalMs = maximumInterval, SampleCount = sampleCount,
                Roots = rootArray, SameSession = sameSession, Events = events.ToArray(), Error = error };
        }
    }
}
