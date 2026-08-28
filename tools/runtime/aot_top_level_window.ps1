Set-StrictMode -Version Latest

if (-not ('AotTopLevelWindow' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class AotTopLevelWindow {
  private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

  [DllImport("user32.dll")]
  private static extern IntPtr GetWindow(IntPtr hWnd, uint command);

  public static IntPtr FindForProcess(uint processId) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
      uint candidateProcessId;
      GetWindowThreadProcessId(hWnd, out candidateProcessId);
      // EnumWindows includes hidden top-level windows. Reject owned popups so
      // the process's real application window wins even before it is visible.
      if (candidateProcessId == processId && GetWindow(hWnd, 4) == IntPtr.Zero) {
        found = hWnd;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@
}

function Get-AotTopLevelWindowHandle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$ProcessId)

    return [AotTopLevelWindow]::FindForProcess([uint32]$ProcessId)
}
