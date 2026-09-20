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
  [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint thread);
  [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] public static extern bool SetThreadDesktop(IntPtr desktop);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder info, int length, out int needed);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public static string DesktopName(IntPtr h) {
    if (h == IntPtr.Zero) return "<none>";
    var sb = new StringBuilder(256); int needed;
    return GetUserObjectInformationW(h, 2, sb, 512, out needed) ? sb.ToString() : "<unreadable>";
  }
  public static string Desktops() {
    var mine = GetThreadDesktop(GetCurrentThreadId());
    var input = OpenInputDesktop(0, false, 0x0100 | 0x0001);   // DESKTOP_READOBJECTS | DESKTOP_SWITCHDESKTOP
    return "this thread's desktop: " + DesktopName(mine) + "; the INPUT desktop: " +
      (input == IntPtr.Zero ? "<OpenInputDesktop failed, error " + Marshal.GetLastWin32Error() + ">" : DesktopName(input));
  }
  public static bool UseInputDesktop() {
    var input = OpenInputDesktop(0, true, 0x01FF);            // DESKTOP_ALL minus nothing that matters
    return input != IntPtr.Zero && SetThreadDesktop(input);
  }
  public static void SendClick(int x, int y) {
    // Absolute SendInput, normalised to the 65535-wide virtual screen, with a move in the same
    // batch as the press: mouse_event's separate SetCursorPos is exactly the shape of injection
    // some input stacks discard.
    int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
    var inputs = new INPUT[3];
    for (int i = 0; i < 3; i++) {
      inputs[i].type = 0;
      inputs[i].mi.dx = (x * 65535) / w;
      inputs[i].mi.dy = (y * 65535) / h;
    }
    inputs[0].mi.dwFlags = 0x8001;   // ABSOLUTE | MOVE
    inputs[1].mi.dwFlags = 0x8003;   // ABSOLUTE | LEFTDOWN
    inputs[2].mi.dwFlags = 0x8005;   // ABSOLUTE | LEFTUP
    SendInput(3, inputs, Marshal.SizeOf(typeof(INPUT)));
  }
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
  [DllImport("user32.dll")] public static extern bool LockSetForegroundWindow(uint action);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint param, IntPtr value, uint winIni);

  // The foreground on this desktop is a hidden window that never changes hands (run 35492353965),
  // so the board opens, finds it is not the active window, and dismisses itself inside 500 ms.
  // Unlocking the foreground and borrowing the current owner's input queue is the documented way
  // to hand it over.
  public static string Describe(IntPtr h) {
    if (h == IntPtr.Zero) return "<none>";
    var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
    var c = new StringBuilder(512); GetClassNameW(h, c, 512);
    uint pid; GetWindowThreadProcessId(h, out pid);
    string name; try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { name = "?"; }
    return string.Format("{0} (pid {1}) [{2}] '{3}'{4}", name, pid, c, t, IsWindowVisible(h) ? "" : " HIDDEN");
  }
  public static void UnlockForeground() {
    LockSetForegroundWindow(2);                       // LSFW_UNLOCK
    SystemParametersInfoW(0x2001, 0, IntPtr.Zero, 3); // SPI_SETFOREGROUNDLOCKTIMEOUT = 0
    AllowSetForegroundWindow(-1);                     // ASFW_ANY
  }
  public static bool ForceForeground(IntPtr h) {
    UnlockForeground();
    uint other; GetWindowThreadProcessId(GetForegroundWindow(), out other);
    uint otherThread = GetWindowThreadProcessId(GetForegroundWindow(), out other);
    uint mine = GetCurrentThreadId();
    AttachThreadInput(mine, otherThread, true);
    ShowWindow(h, 5);                                 // SW_SHOW
    BringWindowToTop(h);
    bool ok = SetForegroundWindow(h);
    SetActiveWindow(h);
    AttachThreadInput(mine, otherThread, false);
    return ok && GetForegroundWindow() == h;
  }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  public class Top { public IntPtr Handle; public uint Pid; public string Class; public string Title; public RECT Rect; public bool Visible; }
  public static System.Collections.Generic.List<Top> Tops() { return Tops(true); }
  public static System.Collections.Generic.List<Top> Tops(bool visibleOnly) {
    var list = new System.Collections.Generic.List<Top>();
    EnumWindows((h, p) => {
      if (visibleOnly && !IsWindowVisible(h)) return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      var c = new StringBuilder(512); GetClassNameW(h, c, 512);
      uint pid; GetWindowThreadProcessId(h, out pid);
      RECT r; GetWindowRect(h, out r);
      list.Add(new Top { Handle = h, Pid = pid, Class = c.ToString(), Title = t.ToString(), Rect = r, Visible = IsWindowVisible(h) });
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

# THE SHELL'S OWN WAY OF STARTING A PACKAGED APP, and not `explorer.exe shell:AppsFolder\...`.
# That route spawns an explorer process which then exits, and the board, which dismisses itself the
# moment it is not the active window, was seen closing under a second later. This is the interface
# the taskbar button itself uses; it returns the process it started and steals no foreground.
Add-Type @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationActivationManager {
  int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
  int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
  int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, IntPtr items, out uint processId);
}
[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class ApplicationActivationManager { }
public static class Activator2 {
  public static string Activate(string aumid) {
    var manager = (IApplicationActivationManager)(new ApplicationActivationManager());
    uint pid;
    int hr = manager.ActivateApplication(aumid, null, 0, out pid);
    return hr == 0 ? "pid " + pid : string.Format("0x{0:X8}", hr);
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
    # Never the widgets picker, which WWAHost also hosts.
    if ($w.Title -like "*Widget*") { continue }
    $isOobe = $w.Title -eq "Microsoft account" -or $name -in @("WWAHost", "FirstLogonAnim", "OOBENetworkCaptivePortal", "CloudExperienceHostBroker", "UserOOBEBroker")
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
  # AND THE ONE THAT DOES NOT HAVE A VISIBLE WINDOW AT ALL.
  # Closing the Shell_OOBEProxy above is not enough: run 35492492126 found the FOREGROUND still held
  # by WWAHost's 'Microsoft account' CoreWindow, which IsWindowVisible does not report, so nothing
  # above ever saw it. The board checks whether it is the active window and dismisses itself when it
  # is not, which is why it kept vanishing inside half a second. The out-of-box host is ended by
  # process, not by window.
  foreach ($p in @(Get-Process WWAHost, CloudExperienceHostBroker, UserOOBEBroker, FirstLogonAnim -ErrorAction SilentlyContinue)) {
    Write-Host "ending the out-of-box host $($p.ProcessName) (pid $($p.Id))"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    $closed++
  }
  Start-Sleep 4
  Write-Host "the foreground is now held by: $([Board]::Describe([Board]::GetForegroundWindow()))"
  if ($closed -eq 0) { Write-Host "nothing was covering the desktop" }
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
  $out.Add("=== top-level windows, hidden ones included ===")
  foreach ($w in [Board]::Tops($false)) {
    if (($w.Rect.Right - $w.Rect.Left) -lt 200) { continue }
    $who = try { (Get-Process -Id $w.Pid -ErrorAction Stop).ProcessName } catch { "gone" }
    $wide = $w.Rect.Right - $w.Rect.Left
    $high = $w.Rect.Bottom - $w.Rect.Top
    $out.Add("  $($w.Handle) $who [$($w.Class)] '$($w.Title)' ${wide}x${high} visible=$($w.Visible)")
  }
  $out.Add("")
  $out.Add("=== UI Automation, from the board's content window ===")
  $root = Get-BoardRoot
  if (-not $root) { $out.Add("no board content window to read") }
  else { foreach ($l in (Get-Tree $root 0 40)) { $out.Add($l) } }
  $out | Out-File $file -Encoding utf8
  Write-Host "tree: $file ($($out.Count) lines)"
  return $file
}

# WHERE THE BOARD IS READ FROM, and why it is not the desktop root.
#
# The board dismisses itself here because it never gets the foreground, and it cannot be given it:
# SetForegroundWindow fails even with the current owner's input queue attached, because this session
# has never received an input event to hand out. Ending the out-of-box host that held it only moved
# the foreground on to the next shell surface.
#
# But a dismissed board is HIDDEN, not destroyed (run 35493065526). Its WebView2 content window
# survives, keeps rendering, and PrintWindow draws it in full. What a hidden window is missing is a
# place in the walk from the desktop root, which is why "Add widgets" could not be found there.
# AutomationElement.FromHandle reaches it anyway, so everything below starts from that handle.
function Get-BoardContentWindow {
  [Board]::Tops($false) | Where-Object {
    $_.Class -eq "Chrome_WidgetWin_1" -and $_.Title -eq "Widgets" -and
    ($_.Rect.Right - $_.Rect.Left) -gt 400 -and ($_.Rect.Bottom - $_.Rect.Top) -gt 400
  } | Select-Object -First 1
}

function Get-BoardRoot {
  $w = Get-BoardContentWindow
  if (-not $w) { return $null }
  try { return [System.Windows.Automation.AutomationElement]::FromHandle($w.Handle) } catch { return $null }
}

# Every element under $Root whose name contains $Text. With no root, the board's content window.
function Find-Elements([string] $Text, $Root = $null) {
  $found = New-Object System.Collections.Generic.List[object]
  if (-not $Root) { $Root = Get-BoardRoot }
  if (-not $Root) { return $found }
  function Walk($e, $depth) {
    if ($depth -gt 40) { return }
    try { $n = $e.Current.Name } catch { $n = "" }
    if ($n -and $n -like "*$Text*") { $found.Add($e) }
    try {
      $c = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($e)
      while ($c) { Walk $c ($depth + 1); $c = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($c) }
    } catch {}
  }
  Walk $Root 0
  return $found
}

# The first element that is named like $Text AND whose control type matches $Type, which matters
# because the board names a card's Group, its Button and its Image all the same thing.
function Find-One([string] $Text, [string] $Type = "") {
  $hits = @(Find-Elements $Text)
  if ($Type) { $hits = @($hits | Where-Object { "$($_.Current.ControlType.ProgrammaticName)" -match $Type }) }
  if ($hits.Count -eq 0) { return $null }
  return $hits[0]
}

function Wait-Element([string] $Text, [int] $Seconds = 30, [string] $Type = "") {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $hit = Find-One $Text $Type
    if ($hit) { return $hit }
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

# HOW A CONTROL IS PRESSED HERE, AND WHY IT IS NOT THE MOUSE
# On this runner injected input is dropped. Measured, not assumed (run 35491583919): the pointer
# arrives at the exact coordinates asked for and over the right window, the thread is already on
# the input desktop, and neither mouse_event nor absolute SendInput closes a plain Win32 dialog's
# Cancel button. The same button, pressed through UI Automation's InvokePattern, closed it at once.
#
# So a press here is the accessibility API: InvokePattern, or LegacyIAccessible's default action
# where a control offers only that. That is the same code path a screen reader user's press takes,
# and it runs the control's own handler inside the board, which is the thing being proved. What it
# does NOT prove is hit-testing: that the rectangle is reachable by a pointer, unobscured, and big
# enough to hit. The screenshots are what stand behind that, and the README says so.
function Press-Element($e) {
  $name = try { $e.Current.Name } catch { "<unnamed>" }
  try {
    $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Write-Host "invoked '$name' through InvokePattern"
    Start-Sleep -Milliseconds 1200
    return "InvokePattern"
  } catch {}
  try {
    $e.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern).DoDefaultAction()
    Write-Host "invoked '$name' through LegacyIAccessible.DoDefaultAction"
    Start-Sleep -Milliseconds 1200
    return "DoDefaultAction"
  } catch {}
  try {
    $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Write-Host "selected '$name' through SelectionItemPattern"
    Start-Sleep -Milliseconds 1200
    return "SelectionItemPattern"
  } catch {}
  throw "'$name' offers no pattern that can press it, and this session drops injected input"
}

$VK_LWIN = 0x5B; $VK_W = 0x57; $VK_ESCAPE = 0x1B; $VK_RETURN = 0x0D; $VK_TAB = 0x09

# ── The board ─────────────────────────────────────────────────────────────────
#
# Win+W is what a person presses, and it does nothing on this runner, because the shell's hotkeys
# are not reachable from a session that drops injected input. The board is started through the same
# app entry the taskbar button starts, and Open-Board says which route worked so that "the board
# opened" is never confused with "the shortcut works".
#
# Open it ONCE and leave it open. There is no way to close it from here (this session drops
# injected input, so there is no Escape to press), and a host that has been ended does not come
# back: run 35491820930 ended Widgets.exe first and then waited 100 seconds across four activations
# for a board that never appeared.
function Open-Board([int] $Tries = 3, [int] $Seconds = 60) {
  if (Get-BoardRoot) { return "already loaded" }
  $pkg = Get-AppxPackage -Name MicrosoftWindows.Client.WebExperience
  $aumid = "$($pkg.PackageFamilyName)!Widgets"
  for ($i = 1; $i -le $Tries; $i++) {
    if (-not (Get-BoardContentWindow)) {
      [Board]::UnlockForeground()
      Write-Host "activating $aumid (attempt $i): $([Activator2]::Activate($aumid))"
    } else {
      Write-Host "the board's content window is already there; not activating it again (attempt $i)"
    }
    if (Wait-BoardOpen $Seconds) { return "ActivateApplication $aumid (attempt $i)" }
  }
  return ""
}

# A single element, cut out of the capture of the window it lives in. This is how one card gets a
# picture of its own without anything being cropped by hand afterwards.
function Save-ElementShot($e, [string] $Name, [int] $Pad = 8) {
  $w = Get-BoardContentWindow
  if (-not $w) { Write-Host "no board content window, so no shot of $Name"; return $null }
  $bmp = Get-BoardImage
  if (-not $bmp) { Write-Host "the board would not draw for $Name"; return $null }
  try {
    $r = $e.Current.BoundingRectangle
    $frame = New-Object Board+RECT
    if ([Board]::DwmGetWindowAttribute($w.Handle, 9, [ref] $frame, 16) -ne 0) { [void][Board]::GetWindowRect($w.Handle, [ref] $frame) }
    $x = [Math]::Max(0, [int]$r.X - $frame.Left - $Pad)
    $y = [Math]::Max(0, [int]$r.Y - $frame.Top - $Pad)
    $wide = [Math]::Min($bmp.Width - $x, [int]$r.Width + 2 * $Pad)
    $high = [Math]::Min($bmp.Height - $y, [int]$r.Height + 2 * $Pad)
    if ($wide -le 0 -or $high -le 0) { Write-Host "'$Name' has no rectangle inside the board"; return $null }
    $crop = $bmp.Clone((New-Object System.Drawing.Rectangle $x, $y, $wide, $high), $bmp.PixelFormat)
    $script:BoardShot++
    $file = Join-Path $script:BoardOut ("{0:d2}-{1}.png" -f $script:BoardShot, $Name)
    $crop.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "shot: $file  $($crop.Width)x$($crop.Height), $(Measure-Colours $crop) colours"
    $crop.Dispose()
    return $file
  } finally { $bmp.Dispose() }
}

function Save-BoardShot([string] $Name, [switch] $Required) {
  $bmp = Get-BoardImage
  if (-not $bmp) {
    if ($Required) { throw "The board would not draw for '$Name'" }
    Write-Host "no image for $Name"
    return $null
  }
  $colours = Measure-Colours $bmp
  $script:BoardShot++
  $file = Join-Path $script:BoardOut ("{0:d2}-{1}.png" -f $script:BoardShot, $Name)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host "shot: $file  $($bmp.Width)x$($bmp.Height), $colours colours"
  $bmp.Dispose()
  if ($Required -and $colours -lt 200) { throw "'$Name' captured as $colours colours, which is a blank rectangle, not a screenshot" }
  return $file
}

function Get-BoardWindow {
  [Board]::Tops() | Where-Object {
    $name = try { (Get-Process -Id $_.Pid -ErrorAction Stop).ProcessName } catch { "" }
    $name -in @("Widgets", "WidgetBoard") -and ($_.Rect.Right - $_.Rect.Left) -gt 200 -and ($_.Rect.Bottom - $_.Rect.Top) -gt 200
  } | Select-Object -First 1
}

# "Open" here means the board's content window exists and UI Automation can read it, which is what
# every step below actually needs. Whether it is on screen is a separate question, and one this
# session cannot answer in the board's favour.
function Test-BoardOpen { return [bool](Get-BoardRoot) }

# HOW THE BOARD IS PHOTOGRAPHED, and why it is a loop
#
# PrintWindow against the board's content window is intermittent on this runner. Two calls a
# fraction of a second apart returned 2109 colours and then 1 colour (run 35493656024), and in
# other runs it returned a fully drawn board on the first try. Nothing on this desktop presents to
# a framebuffer, and the offscreen surface the call reads is not always there to be read.
#
# So a capture is attempted until it produces something, the best frame seen is kept, and a
# capture that never fills in is reported rather than saved as a blank rectangle with a confident
# name. The window is nudged on screen without activation between attempts, because a WebView2 that
# believes it is hidden eventually stops drawing.
function Get-BoardImage([int] $Tries = 25) {
  $best = $null; $bestColours = 0; $used = 0
  for ($i = 1; $i -le $Tries; $i++) {
    $used = $i
    $w = Get-BoardContentWindow
    if (-not $w) { Start-Sleep 2; continue }
    if (-not $w.Visible) { [void][Board]::ShowWindow($w.Handle, 8) }   # SW_SHOWNA
    $bmp = Get-WindowImage $w.Handle
    if ($bmp) {
      $colours = Measure-Colours $bmp
      if ($colours -gt $bestColours) {
        if ($best) { $best.Dispose() }
        $best = $bmp; $bestColours = $colours
      } else { $bmp.Dispose() }
      if ($bestColours -ge 200) { break }
    }
    Start-Sleep 2
  }
  Write-Host "the board drew $bestColours colours, on attempt $used of $Tries"
  return $best
}

function Wait-BoardPainted([int] $Tries = 25) {
  $bmp = Get-BoardImage $Tries
  if (-not $bmp) { return $false }
  $ok = (Measure-Colours $bmp) -ge 200
  $bmp.Dispose()
  return $ok
}

function Wait-BoardOpen([int] $Seconds = 60) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $w = Get-BoardContentWindow
    if ($w) {
      Write-Host "board content: handle $($w.Handle), $($w.Rect.Right - $w.Rect.Left)x$($w.Rect.Bottom - $w.Rect.Top), on screen: $($w.Visible)"
      if (-not (Wait-BoardPainted 25)) { return $false }
      return [bool](Get-BoardRoot)
    }
    Start-Sleep -Milliseconds 400
  }
  return $false
}

function Ensure-Board {
  if (Test-BoardOpen) { return $true }
  return [bool](Open-Board 3 60)
}

function Poke-Board {
  $w = Get-BoardWindow
  if ($w) { [void][Board]::SetForegroundWindow($w.Handle) }
  return [bool]$w
}

# The board caches the set of widget providers it knows about, and a provider registered after it
# started is not in that cache. Ending the host makes the next activation build it again, which is
# how a newly installed app's widgets get into the picker without a sign-out.
#
# It also works around the other thing this runner does: the board opens once per job. Once closed
# it will not come back from shell:AppsFolder, so anything that needs it open again needs this
# first.
function Reset-WidgetsHost {
  foreach ($name in "Widgets", "WidgetBoard", "WidgetService") {
    $procs = @(Get-Process $name -ErrorAction SilentlyContinue)
    if ($procs) { Write-Host "ending $($procs.Count) $name process(es)"; $procs | Stop-Process -Force -ErrorAction SilentlyContinue }
  }
  Start-Sleep 6
}

function Close-Board {
  if (Test-BoardOpen) { Send-Key $VK_ESCAPE; Start-Sleep 3 }
}
