// All handles stay open until every member has been checked and marked for deletion.
// Zero sharing rejects even readers that originally allowed delete sharing.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Aicm {
    public static class FileGuard {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [StructLayout(LayoutKind.Sequential)]
        struct Disposition { [MarshalAs(UnmanagedType.U1)] public bool DeleteFile; }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind,
            ref Disposition info, uint size);

        public static bool TryDelete(string[] paths, string[] checks) {
            var handles = new List<SafeFileHandle>();
            var byPath = new Dictionary<string, SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
            var marked = new List<SafeFileHandle>();
            try {
                foreach (var path in checks) {
                    if (byPath.ContainsKey(path)) continue;
                    // GENERIC_READ | DELETE, no sharing, OPEN_EXISTING.
                    var handle = CreateFile(path, 0x80010000, 0, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
                    handles.Add(handle);
                    if (handle.IsInvalid) return false;
                    byPath.Add(path, handle);
                }
                var info = new Disposition { DeleteFile = true };
                foreach (var path in paths) {
                    SafeFileHandle handle;
                    if (!byPath.TryGetValue(path, out handle) ||
                        !SetFileInformationByHandle(handle, 4, ref info, 1)) {
                        // Undo earlier marks while the exclusive handles still exist.
                        var undo = new Disposition { DeleteFile = false };
                        foreach (var previous in marked)
                            SetFileInformationByHandle(previous, 4, ref undo, 1);
                        return false;
                    }
                    marked.Add(handle);
                }
                return true;
            } finally { foreach (var handle in handles) handle.Dispose(); }
        }
    }
}
