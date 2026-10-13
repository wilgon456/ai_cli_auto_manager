// All handles stay open until every member has been checked and marked for deletion.
// Zero sharing rejects even readers that originally allowed delete sharing.
using System;
using System.Collections.Generic;
using System.IO;
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

        [StructLayout(LayoutKind.Sequential)]
        struct FileInfo {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);

        public static bool TryDelete(string[] paths, string[] checks) {
            var handles = new List<SafeFileHandle>();
            var byPath = new Dictionary<string, SafeFileHandle>(StringComparer.OrdinalIgnoreCase);
            var marked = new List<SafeFileHandle>();
            var parents = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try {
                foreach (var path in checks) {
                    if (byPath.ContainsKey(path)) continue;
                    // Prevent ancestor rename/junction replacement until all marks are complete.
                    // FILE_READ_ATTRIBUTES, read/write sharing without delete sharing;
                    // BACKUP_SEMANTICS | OPEN_REPARSE_POINT checks the directory itself.
                    for (var parent = Path.GetDirectoryName(Path.GetFullPath(path));
                        parent != null; parent = Path.GetDirectoryName(parent)) {
                        if (!parents.Add(parent)) break;
                        var directory = CreateFile(parent, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                        handles.Add(directory);
                        FileInfo dirInfo;
                        if (directory.IsInvalid || !GetFileInformationByHandle(directory, out dirInfo) ||
                            (dirInfo.Attributes & 0x400) != 0) return false;
                    }
                    // GENERIC_READ | DELETE, no sharing, OPEN_EXISTING.
                    var handle = CreateFile(path, 0x80010000, 0, IntPtr.Zero, 3, 0x00200080, IntPtr.Zero);
                    handles.Add(handle);
                    FileInfo fileInfo;
                    // Reject reparse points, directories and readonly files BEFORE marking any member.
                    if (handle.IsInvalid || !GetFileInformationByHandle(handle, out fileInfo) ||
                        (fileInfo.Attributes & (0x400 | 0x10 | 1)) != 0) return false;
                    byPath.Add(path, handle);
                }
                var info = new Disposition { DeleteFile = true };
                foreach (var path in paths) {
                    SafeFileHandle handle;
                    if (!byPath.TryGetValue(path, out handle) ||
                        !SetFileInformationByHandle(handle, 4, ref info, 1)) {
                        // Undo earlier marks while the exclusive handles still exist.
                        var undo = new Disposition { DeleteFile = false };
                        foreach (var previous in marked) {
                            if (!SetFileInformationByHandle(previous, 4, ref undo, 1))
                                throw new IOException("Could not cancel a pending cleanup deletion.");
                        }
                        return false;
                    }
                    marked.Add(handle);
                }
                return true;
            } finally { foreach (var handle in handles) handle.Dispose(); }
        }
    }
}
