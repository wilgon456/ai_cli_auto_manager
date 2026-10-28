// Windows Task Scheduler entry point. Compile with csc /target:winexe /platform:anycpu.
// Run PowerShell with CREATE_NO_WINDOW; keep the task alive until it exits and pass its exit code on.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class WindowlessLauncher {
    // The Windows C runtime argument quoting rules. In particular, trailing backslashes before the
    // closing quote must be doubled and embedded quotes must escape their preceding backslashes.
    private static string Quote(string argument) {
        StringBuilder result = new StringBuilder();
        result.Append('"');
        int slashes = 0;
        foreach (char character in argument) {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
            } else {
                result.Append('\\', slashes);
                result.Append(character);
            }
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static int Main(string[] args) {
        if (args.Length == 0) return 2;
        try {
            string executable = Path.Combine(Environment.SystemDirectory,
                @"WindowsPowerShell\v1.0\powershell.exe");
            StringBuilder arguments = new StringBuilder();
            foreach (string arg in args) {
                if (arguments.Length != 0) arguments.Append(' ');
                arguments.Append(Quote(arg));
            }
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = executable;
            start.Arguments = arguments.ToString();
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            using (Process child = Process.Start(start)) {
                if (child == null) return 127;
                child.WaitForExit();
                return child.ExitCode;
            }
        } catch (Exception) {
            // Task Scheduler will record a failed launch, without opening an error dialog.
            return 127;
        }
    }
}
