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
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern int SendInput(uint n, INPUT[] inputs, int size);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; public int pad1, pad2; }
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  // CharSet MUST be Unicode on every one of these. Without it the marshaller hands a W function an
  // ANSI buffer and reads UTF-16 back as ANSI, so every title in the first recon run came back as a
  // single letter and the window list said nothing.
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr rect, IntPtr rgn, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  public class Top { public IntPtr Handle; public uint Pid; public string Class; public string Title; public RECT Rect; }
  public static System.Collections.Generic.List<Top> Tops() {
    var list = new System.Collections.Generic.List<Top>();
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      var c = new StringBuilder(512); GetClassNameW(h, c, 512);
      uint pid; GetWindowThreadProcessId(h, out pid);
      RECT r; GetWindowRect(h, out r);
      list.Add(new Top { Handle = h, Pid = pid, Class = c.ToString(), Title = t.ToString(), Rect = r });
      return true;
    }, IntPtr.Zero);
    return list;
  }
  public static string Windows() {
    var sb = new StringBuilder();
    foreach (var w in Tops())
      sb.AppendLine(string.Format("{0,-10} pid {1,-7} {2,4},{3,-4} {4,4}x{5,-4} [{6}] {7}",
        w.Handle, w.Pid, w.Rect.Left, w.Rect.Top, w.Rect.Right - w.Rect.Left, w.Rect.Bottom - w.Rect.Top, w.Class, w.Title));
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

# WHY WINDOWS ARE CAPTURED ONE AT A TIME AND NOT OFF THE SCREEN
# The second recon run (35490776224) closed the out-of-box page, opened the Widgets Board, and
# proved from the window list that both had happened. Every full-screen grab still showed the
# out-of-box page: this session composes, but nothing presents to the framebuffer that BitBlt
# reads, so CopyFromScreen returns whatever was last pushed to it. A screenshot of the board taken
# that way would be a photograph of a page that had already closed.
#
# PrintWindow with PW_RENDERFULLCONTENT asks DWM for the window's own composed surface instead,
# which is drawn whether or not anything is presenting it. Assert-Fresh checks the result is not
# one flat colour, because a window that declines to render returns exactly that.
function Get-WindowImage([IntPtr] $Handle, [uint32] $Flags = 2) {
  $r = New-Object Board+RECT
  # The DWM extended-frame bounds, not GetWindowRect: the latter includes the invisible resize
  # border, which arrives as a black margin.
  if ([Board]::DwmGetWindowAttribute($Handle, 9, [ref] $r, 16) -ne 0) { [void][Board]::GetWindowRect($Handle, [ref] $r) }
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  if ($w -le 0 -or $h -le 0) { return $null }
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $ok = [Board]::PrintWindow($Handle, $hdc, $Flags)
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  if (-not $ok) { $bmp.Dispose(); return $null }
  return $bmp
}

function Measure-Colours($bmp) {
  $colours = @{}
  for ($y = 0; $y -lt $bmp.Height; $y += 11) {
    for ($x = 0; $x -lt $bmp.Width; $x += 11) { $colours[$bmp.GetPixel($x, $y).ToArgb()] = $true }
  }
  return $colours.Count
}

function Save-WindowShot([IntPtr] $Handle, [string] $Name, [switch] $Required) {
  $script:BoardShot++
  $bmp = Get-WindowImage $Handle
  if (-not $bmp) {
    if ($Required) { throw "PrintWindow refused to draw the window for '$Name'" }
    Write-Host "no image for $Name"
    return $null
  }
  $colours = Measure-Colours $bmp
  $file = Join-Path $script:BoardOut ("{0:d2}-{1}.png" -f $script:BoardShot, $Name)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host "shot: $file  $($bmp.Width)x$($bmp.Height), $colours colours"
  $bmp.Dispose()
  if ($Required -and $colours -lt 8) { throw "$Name captured as $colours colours, which is a blank rectangle, not a screenshot" }
  return $file
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

# WHAT WAS IN FRONT OF EVERYTHING
# The first recon run found this image parked on the Windows out-of-box privacy page ("Choose
# privacy settings for your device"), a full-screen window titled "Microsoft account", with a
# leftover "System Properties" paging-file dialog behind it. The desktop, the taskbar, explorer and
# the Widgets processes were all alive underneath; the OOBE page simply covered them and took the
# input. So the first thing any run does is clear the windows that are not this machine's work.
#
# Nothing here is clicked. Answering the privacy page would mean choosing settings on somebody
# else's behalf, and its buttons are in a XAML island this tree cannot even see. The window's
# process is ended instead, which on an ephemeral runner costs nothing.
function Clear-Intruders {
  $closed = 0
  foreach ($w in [Board]::Tops()) {
    $name = try { (Get-Process -Id $w.Pid -ErrorAction Stop).ProcessName } catch { "<gone>" }
    $isOobe = $w.Class -eq "Windows.UI.Core.CoreWindow" -and $name -in @("WWAHost", "CloudExperienceHostBroker", "SystemSettings", "UserOOBEBroker")
    $isOobe = $isOobe -or $w.Title -eq "Microsoft account" -or $name -in @("WWAHost", "FirstLogonAnim", "OOBENetworkCaptivePortal")
    $isStray = $w.Title -in @("System Properties", "Windows Setup")
    if (-not ($isOobe -or $isStray)) { continue }
    Write-Host "in the way: [$($w.Class)] '$($w.Title)' from $name (pid $($w.Pid)) -- closing it"
    [void][Board]::PostMessageW($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    Start-Sleep 2
    if (-not (Get-Process -Id $w.Pid -ErrorAction SilentlyContinue)) { $closed++; continue }
    if ([Board]::Tops() | Where-Object { $_.Handle -eq $w.Handle }) {
      Stop-Process -Id $w.Pid -Force -ErrorAction SilentlyContinue
      Start-Sleep 2
    }
    $closed++
  }
  if ($closed -eq 0) { Write-Host "nothing was covering the desktop" }
  Start-Sleep 3
  return $closed
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

function Get-Tree([System.Windows.Automation.AutomationElement] $Root, [int] $Depth = 0, [int] $Max = 40) {
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
      foreach ($l in (Get-Tree $child 0 40)) { $out.Add($l) }
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
    if ($depth -gt 40) { return }
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

# A click says where the pointer ENDED UP and what window is under it, because "clicked 256,136"
# was printed by the run that dismissed the board, and the one thing it did not establish was
# whether the pointer was at 256,136 at the time.
function Click-At([int] $X, [int] $Y) {
  [void][Board]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 300
  $p = New-Object Board+POINT
  [void][Board]::GetCursorPos([ref] $p)
  $under = [Board]::WindowFromPoint($p)
  $w = [Board]::Tops() | Where-Object { $_.Handle -eq $under } | Select-Object -First 1
  $what = if ($w) { "[$($w.Class)] '$($w.Title)'" } else { "child window $under" }
  Write-Host "pointer asked for $X,$Y, is at $($p.X),$($p.Y), over $what"
  if ($p.X -ne $X -or $p.Y -ne $Y) { throw "The pointer did not go where it was sent: this session will not take mouse input at coordinates" }
  [Board]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)   # left down
  Start-Sleep -Milliseconds 90
  [Board]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)   # left up
  Start-Sleep -Milliseconds 900
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

# ── The board ─────────────────────────────────────────────────────────────────
#
# Win+W is what a person presses, so it is tried first and it is the one the screenshots are of.
# The board's own app entry is the fallback, and which route opened it is printed, because
# "the board opened" and "the shortcut works" are two different claims.
function Open-Board([int] $Seconds = 40) {
  if (Test-BoardOpen) { return "already open" }
  Send-Key $VK_W @($VK_LWIN)
  if (Wait-BoardOpen ($Seconds / 2)) { return "Win+W" }
  Write-Host "Win+W did not open it; trying the board's own app entry"
  $pkg = Get-AppxPackage -Name MicrosoftWindows.Client.WebExperience
  Start-Process "explorer.exe" "shell:AppsFolder\$($pkg.PackageFamilyName)!Widgets"
  if (Wait-BoardOpen ($Seconds / 2)) { return "shell:AppsFolder" }
  return ""
}

function Get-BoardWindow {
  [Board]::Tops() | Where-Object {
    $name = try { (Get-Process -Id $_.Pid -ErrorAction Stop).ProcessName } catch { "" }
    $name -in @("Widgets", "WidgetBoard") -and ($_.Rect.Right - $_.Rect.Left) -gt 200 -and ($_.Rect.Bottom - $_.Rect.Top) -gt 200
  } | Select-Object -First 1
}

function Test-BoardOpen { return [bool](Get-BoardWindow) }

function Wait-BoardOpen([int] $Seconds = 20) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $w = Get-BoardWindow
    if ($w) {
      Write-Host "board window: [$($w.Class)] '$($w.Title)' at $($w.Rect.Left),$($w.Rect.Top) $($w.Rect.Right - $w.Rect.Left)x$($w.Rect.Bottom - $w.Rect.Top)"
      Start-Sleep 4    # let it finish animating in before anything is looked at or clicked
      return $true
    }
    Start-Sleep 1
  }
  return $false
}

function Close-Board {
  if (Test-BoardOpen) { Send-Key $VK_ESCAPE; Start-Sleep 3 }
}
