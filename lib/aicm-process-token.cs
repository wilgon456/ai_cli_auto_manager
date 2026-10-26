using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace Aicm {
    public static class ProcessToken {
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int kind, out int info, int size, out int length);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public static bool Elevated(int pid) {
            IntPtr token = IntPtr.Zero;
            try {
                using (var p = Process.GetProcessById(pid)) {
                    if (!OpenProcessToken(p.Handle, 8, out token)) return true;
                    int info, length;
                    return !GetTokenInformation(token, 20, out info, 4, out length) || info != 0;
                }
            } catch { return true; }
            finally { if (token != IntPtr.Zero) CloseHandle(token); }
        }
    }
}
