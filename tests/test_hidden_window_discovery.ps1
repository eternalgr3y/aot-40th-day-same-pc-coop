$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools\runtime\aot_top_level_window.ps1')

if (-not ('AotHiddenWindowFixture' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class AotHiddenWindowFixture {
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern IntPtr CreateWindowEx(uint exStyle, string className,
      string windowName, uint style, int x, int y, int width, int height,
      IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
}
'@
}

$fixture = [AotHiddenWindowFixture]::CreateWindowEx(
    0, 'STATIC', 'AotHiddenWindowProbe', 0x00CF0000,
    0, 0, 320, 200, [IntPtr]::Zero, [IntPtr]::Zero,
    [IntPtr]::Zero, [IntPtr]::Zero)
if ($fixture -eq [IntPtr]::Zero) {
    throw "Could not create hidden window fixture (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
}
try {
    if ([AotHiddenWindowFixture]::IsWindowVisible($fixture)) {
        throw 'Hidden window fixture unexpectedly became visible.'
    }
    $found = Get-AotTopLevelWindowHandle -ProcessId ([Diagnostics.Process]::GetCurrentProcess().Id)
    if ($found -eq [IntPtr]::Zero) {
        throw 'Top-level window discovery missed a hidden window.'
    }
    $title = [Text.StringBuilder]::new(128)
    [void][AotHiddenWindowFixture]::GetWindowText($found, $title, $title.Capacity)
    if ($title.ToString() -cne 'AotHiddenWindowProbe') {
        throw "Top-level window discovery returned an unexpected window '$title'."
    }
} finally {
    [void][AotHiddenWindowFixture]::DestroyWindow($fixture)
}

Write-Host 'PASS: hidden top-level Xenia-style windows are discoverable without activation'
