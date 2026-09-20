# Drives the Windows 11 Widgets Board the way a person does, and writes down what it saw.
#
# Dot-source it; every function below writes into $script:BoardOut, which Start-Board sets.
#
# WHY REAL INPUT AND NOT AN API
# There is no supported way to ask the Widgets Board to pin a widget. The board is the customer's
# side of this feature, so the only honest proof is the shell opening it, the picker listing the
# provider, and a pointer landing on the card. That means SendInput, screenshots and UI Automation.
#
# WHAT WOULD FAKE A PASS, and what is done about it
#  1. A black screenshot. A session with no composed desktop returns one, and a black PNG named
#     "the board" proves nothing. Assert-Screen refuses to start unless a capture of the bare
#     desktop has more than one colour in it.
#  2. A screenshot taken before the board finished animating in. Every shot here is taken after the
#     UI Automation tree says the thing being waited for exists, not after a fixed sleep.
#  3. "I clicked at the coordinates the card should be at." Coordinates come from the UI Automation
#     bounding rectangle of a named element, never from a guess, and a click is followed by a
#     re-read of the tree.

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Board {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  public static string Windows() {
    var sb = new StringBuilder();
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      var c = new StringBuilder(512); GetClassNameW(h, c, 512);
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (t.Length > 0 || c.Length > 0) sb.AppendLine(string.Format("{0,-12} pid {1,-8} [{2}] {3}", h.ToString(), pid, c, t));
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }
}
"@

$script:BoardOut = "board-proof"
$script:BoardShot = 0

function Start-Board([string] $OutDir) {
  $script:BoardOut = $OutDir
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

# ── Looking ───────────────────────────────────────────────────────────────────

function Get-Screen {
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $g.Dispose()
  return $bmp
}

function Save-Shot([string] $Name) {
  $script:BoardShot++
  $file = Join-Path $script:BoardOut ("{0:d2}-{1}.png" -f $script:BoardShot, $Name)
  $bmp = Get-Screen
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "shot: $file"
  return $file
}

# A screen with one colour in it is a screen that is not being composed. Everything after this
# would be a black rectangle with a confident filename, so the run stops here instead.
function Assert-Screen {
  $bmp = Get-Screen
  $colours = @{}
  for ($y = 0; $y -lt $bmp.Height; $y += 17) {
    for ($x = 0; $x -lt $bmp.Width; $x += 17) { $colours[$bmp.GetPixel($x, $y).ToArgb()] = $true }
  }
  $n = $colours.Count
  $bmp.Dispose()
  Write-Host "the desktop has $n distinct colours in it"
  if ($n -lt 2) { throw "The screen captures as a single flat colour: this session composes nothing, so no screenshot here can prove anything" }
}

# ── The UI Automation tree ────────────────────────────────────────────────────

function Get-Tree([System.Windows.Automation.AutomationElement] $Root, [int] $Depth = 0, [int] $Max = 14) {
  $lines = New-Object System.Collections.Generic.List[string]
  if ($Depth -gt $Max) { return $lines }
  try { $name = $Root.Current.Name } catch { $name = "<?>" }
  try { $type = $Root.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { $type = "?" }
  try { $id = $Root.Current.AutomationId } catch { $id = "" }
  try { $r = $Root.Current.BoundingRectangle; $rect = "{0},{1} {2}x{3}" -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height } catch { $rect = "" }
  $lines.Add(("  " * $Depth) + "$type '$name'" + $(if ($id) { " #$id" }) + $(if ($rect) { "  [$rect]" }))
  try {
    $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($Root)
    while ($child) {
      foreach ($l in (Get-Tree $child ($Depth + 1) $Max)) { $lines.Add($l) }
      $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($child)
    }
  } catch {}
  return $lines
}

function Save-Tree([string] $Name) {
  $file = Join-Path $script:BoardOut "tree-$Name.txt"
  $out = New-Object System.Collections.Generic.List[string]
  $out.Add("=== top-level windows ===")
  $out.Add([Board]::Windows())
  $out.Add("=== UI Automation, desktop down ===")
  try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($root)
    while ($child) {
      foreach ($l in (Get-Tree $child 0 14)) { $out.Add($l) }
      $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($child)
    }
  } catch { $out.Add("UI Automation failed: $($_.Exception.Message)") }
  $out | Out-File $file -Encoding utf8
  Write-Host "tree: $file ($($out.Count) lines)"
  return $file
}

# Every element anywhere on the desktop whose name contains $Text.
function Find-Elements([string] $Text) {
  $found = New-Object System.Collections.Generic.List[object]
  function Walk($e, $depth) {
    if ($depth -gt 14) { return }
    try { $n = $e.Current.Name } catch { $n = "" }
    if ($n -and $n -like "*$Text*") { $found.Add($e) }
    try {
      $c = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($e)
      while ($c) { Walk $c ($depth + 1); $c = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($c) }
    } catch {}
  }
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($root)
  while ($child) { Walk $child 0; $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($child) }
  return $found
}

function Wait-Element([string] $Text, [int] $Seconds = 30) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $hits = @(Find-Elements $Text)
    if ($hits.Count -gt 0) { return $hits[0] }
    Start-Sleep -Milliseconds 700
  }
  return $null
}

function Show-Element($e) {
  try { $r = $e.Current.BoundingRectangle } catch { return "<no rectangle>" }
  $t = try { $e.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { "?" }
  return "$t '$($e.Current.Name)' at $([int]$r.X),$([int]$r.Y) $([int]$r.Width)x$([int]$r.Height)"
}

# ── Doing ─────────────────────────────────────────────────────────────────────

function Send-Key([byte] $Vk, [byte[]] $Modifiers = @()) {
  foreach ($m in $Modifiers) { [Board]::keybd_event($m, 0, 0, [IntPtr]::Zero) }
  [Board]::keybd_event($Vk, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [Board]::keybd_event($Vk, 0, 2, [IntPtr]::Zero)
  foreach ($m in $Modifiers) { [Board]::keybd_event($m, 0, 2, [IntPtr]::Zero) }
}

function Click-At([int] $X, [int] $Y) {
  [void][Board]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 250
  [Board]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)   # left down
  Start-Sleep -Milliseconds 90
  [Board]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)   # left up
  Start-Sleep -Milliseconds 900
  Write-Host "clicked $X,$Y"
}

function Click-Element($e) {
  $r = $e.Current.BoundingRectangle
  if ($r.Width -le 0 -or $r.Height -le 0) { throw "Refusing to click '$($e.Current.Name)': it has no on-screen rectangle" }
  Click-At ([int]($r.X + $r.Width / 2)) ([int]($r.Y + $r.Height / 2))
}

# Invoke through the pattern when the element offers one, because a flyout can move between the
# read and the click. The pointer is the fallback, and which one was used is printed.
function Press-Element($e) {
  try {
    $p = $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $p.Invoke()
    Write-Host "invoked '$($e.Current.Name)' through InvokePattern"
    Start-Sleep -Milliseconds 900
    return "InvokePattern"
  } catch {
    Click-Element $e
    return "pointer"
  }
}

$VK_LWIN = 0x5B; $VK_W = 0x57; $VK_ESCAPE = 0x1B; $VK_RETURN = 0x0D; $VK_TAB = 0x09
