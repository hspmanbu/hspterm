# Uses only an isolated runner's locked startup; no Vault or SSH credentials.
param([Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HspGeometry {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
}
'@
function Start-Ready {
 $p = Start-Process -FilePath $Executable -PassThru
 $deadline = [DateTime]::UtcNow.AddSeconds(40)
 do {
  Start-Sleep -Milliseconds 200
  $p.Refresh()
  if ($p.HasExited) { throw "Window exited early: $($p.ExitCode)" }
 } while ($p.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
 if ($p.MainWindowHandle -eq 0) { throw 'No native window' }
 Start-Sleep -Seconds 2
 return $p
}
function Close-Normal($p) {
 if (-not $p.CloseMainWindow() -or -not $p.WaitForExit(30000) -or $p.ExitCode -ne 0) { throw 'Normal close failed' }
 $p.Dispose()
}
$p = $null
try {
 $p = Start-Ready
 if (-not [HspGeometry]::SetWindowPos($p.MainWindowHandle,[IntPtr]::Zero,63,71,980,680,0x14)) { throw 'Native resize/move failed' }
 Start-Sleep -Milliseconds 500
 $before = New-Object HspGeometry+Rect
 if (-not [HspGeometry]::GetWindowRect($p.MainWindowHandle,[ref]$before)) { throw 'Cannot read placement' }
 Close-Normal $p
 $p = $null
 $p = Start-Ready
 $after = New-Object HspGeometry+Rect
 if (-not [HspGeometry]::GetWindowRect($p.MainWindowHandle,[ref]$after)) { throw 'Cannot read restored placement' }
 foreach ($field in @('Left','Top','Right','Bottom')) {
  if ([Math]::Abs($before.$field - $after.$field) -gt 2) { throw "Placement restore mismatch: $field" }
 }
 Close-Normal $p
 $p = $null
 Write-Output 'Native normal-close position and size restoration passed (locked startup). Integrated border dragging needs interactive Windows verification.'
} finally {
 if ($null -ne $p) { $p.Refresh(); if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }; $p.Dispose() }
}
