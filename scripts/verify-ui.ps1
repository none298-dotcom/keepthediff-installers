# Clicks the installed app's primary button and proves the click did something.
#
# WHY NOT UI AUTOMATION
# UIA was asked what it could see inside the window. The answer was the window and one nameless
# Pane: Compose Desktop draws through Skia and, without the Java Access Bridge, publishes no
# semantics tree, so there is no element to find by name and no InvokePattern to call. (That is
# an accessibility defect in its own right, recorded separately. It is not this script's job.)
#
# What is left is what a person does: move the real mouse, press, and look at the screen.
#
# HOW A DEAD BUTTON IS CAUGHT
# By comparing pixels before and after. A button whose handler never runs leaves the screen
# identical. That comparison only means something if "identical" is achievable, so a NEGATIVE
# CONTROL runs first: a click on empty background, which must produce NO change. If it does
# produce one, the screen is repainting on its own, a later "it changed" would prove nothing,
# and the script fails rather than reporting a green it has not earned.
#
# TWO MISTAKES THIS SCRIPT ALREADY MADE, both of which reported a dead button that was not dead
#  1. It measured GetWindowRect. On Windows 10 and later that includes the invisible DWM resize
#     border, so the grab had a strip of DESKTOP WALLPAPER along the bottom: a full width band of
#     non background colour, which the button finder happily selected and clicked. Everything is
#     measured from the CLIENT rect now, which is the app and nothing else.
#  2. It assumed the primary button spans the window. It does not. The onboarding content sits in
#     a readable measure about 465px wide inside an 1100px window, and the button matches it, so
#     a "must be wider than half the window" rule excluded the real button and preferred the
#     window-wide artefact above.
# The lesson in both: a button finder that can latch onto scenery will, and it fails in the
# direction that looks like a product defect. Hence the vertical thickness requirement below,
# which scenery does not have.

param(
  [int]$SettleMs = 1500,
  [string]$OutDir = "artifacts"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

function Grab($rect) {
  $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  # The cursor is deliberately not drawn, so moving the mouse cannot itself register as a change.
  $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
  $g.Dispose()
  return $bmp
}

# Fraction of sampled pixels differing beyond a small per channel tolerance. The tolerance
# absorbs subpixel text antialiasing. It does not absorb a screen that actually changed.
#
# ExcludeTop/ExcludeBottom skip a band of rows. That exists because of a false pass: a build
# with the Begin handler stubbed to {} was measured as 2.874% changed and reported as alive.
# The button block is 464x52 in a 1084x741 client area, which is 3.0% of it. The entire
# "change" was the button drawing its own hover state, because the mouse was parked on it.
# Nothing had happened; the app had merely noticed the pointer. So the button's own rows are
# excluded and the question becomes the right one: did anything change ELSEWHERE.
function DiffFraction($a, $b, $ExcludeTop = -1, $ExcludeBottom = -1) {
  if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) { return 1.0 }
  $differing = 0; $total = 0
  for ($y = 0; $y -lt $a.Height; $y += 3) {
    if ($ExcludeTop -ge 0 -and $y -ge $ExcludeTop -and $y -le $ExcludeBottom) { continue }
    for ($x = 0; $x -lt $a.Width; $x += 3) {
      $total++
      $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
      if ([Math]::Abs($p.R-$q.R) -gt 8 -or [Math]::Abs($p.G-$q.G) -gt 8 -or [Math]::Abs($p.B-$q.B) -gt 8) { $differing++ }
    }
  }
  return $differing / [double]$total
}

function Click($x, $y) {
  [Win32]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 250
  [Win32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # left down
  Start-Sleep -Milliseconds 60
  [Win32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # left up
  # Park the pointer away from everything before anything is measured, so a lingering hover or
  # pressed style is not mistaken for the app having done something. See DiffFraction.
  [Win32]::SetCursorPos(2, 2) | Out-Null
  Start-Sleep -Milliseconds $SettleMs
}

# ── Locate the window's CLIENT area ──────────────────────────────────────────
$proc = Get-Process -Name "Keep the Diff" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw "No process named 'Keep the Diff' with a visible window" }
$h = $proc.MainWindowHandle
[Win32]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 900

$wr = New-Object Win32+RECT; [Win32]::GetWindowRect($h, [ref]$wr) | Out-Null
$cr = New-Object Win32+RECT; [Win32]::GetClientRect($h, [ref]$cr) | Out-Null
$origin = New-Object Win32+POINT; $origin.X = 0; $origin.Y = 0
[Win32]::ClientToScreen($h, [ref]$origin) | Out-Null

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
Write-Host "screen: $($screen.Width)x$($screen.Height)"
Write-Host "window frame: $($wr.Right-$wr.Left)x$($wr.Bottom-$wr.Top) at ($($wr.Left),$($wr.Top))"
Write-Host "client area:  ${cw}x${ch} at ($($origin.X),$($origin.Y))"

# A window taller or wider than the display means the parts of the UI nearest the edges, which
# is exactly where primary actions live, were never on screen to be clicked. Say that, rather
# than hunting for a button in the visible remainder and reporting whatever turns up.
if (($origin.Y + $ch) -gt $screen.Bottom -or ($origin.X + $cw) -gt $screen.Right) {
  Write-Host "::error::The window opens larger than the display. Its bottom or right edge, and the footer button with it, is off screen."
  exit 1
}

$rect = New-Object System.Drawing.Rectangle $origin.X, $origin.Y, $cw, $ch
$before = Grab $rect
$before.Save("$OutDir/01-before-click.png")

# ── Find the primary button by appearance ────────────────────────────────────
# A button is a BLOCK: a run of non background pixels that repeats over many consecutive rows.
# Scenery that previously fooled this (a window border, a sliver of wallpaper) is one or two
# rows tall, so requiring thickness is what separates the two. Finding it by appearance rather
# than by computed coordinates also means a button that renders invisibly fails here, which a
# coordinate guess would have clicked and called alive.
$MIN_RUN = 100      # px wide; the real button is ~465 in an 1100 window
$MIN_ROWS = 20      # px tall; borders and wallpaper slivers are 1 to 3
$bg = $before.GetPixel([int]($cw * 0.5), [int]($ch * 0.45))
Write-Host "background sample: R$($bg.R) G$($bg.G) B$($bg.B)"

function LongestRun($bmp, $y, $bg) {
  $run = 0; $start = 0; $bestRun = 0; $bestStart = 0
  for ($x = 0; $x -lt $bmp.Width; $x++) {
    $p = $bmp.GetPixel($x, $y)
    $isBg = ([Math]::Abs($p.R-$bg.R) -le 12 -and [Math]::Abs($p.G-$bg.G) -le 12 -and [Math]::Abs($p.B-$bg.B) -le 12)
    if (-not $isBg) { if ($run -eq 0) { $start = $x }; $run++ }
    else { if ($run -gt $bestRun) { $bestRun = $run; $bestStart = $start }; $run = 0 }
  }
  if ($run -gt $bestRun) { $bestRun = $run; $bestStart = $start }
  return @($bestRun, $bestStart)
}

$blocks = @(); $curTop = -1; $curRuns = @(); $curStarts = @()
for ($y = [int]($ch * 0.5); $y -lt $ch; $y++) {
  $r = LongestRun $before $y $bg
  if ($r[0] -ge $MIN_RUN) {
    if ($curTop -lt 0) { $curTop = $y; $curRuns = @(); $curStarts = @() }
    $curRuns += $r[0]; $curStarts += $r[1]
  } elseif ($curTop -ge 0) {
    if (($y - $curTop) -ge $MIN_ROWS) {
      $blocks += [pscustomobject]@{ Top=$curTop; Bottom=$y; Width=($curRuns | Measure-Object -Maximum).Maximum; Start=($curStarts | Measure-Object -Minimum).Minimum }
    }
    $curTop = -1
  }
}
if ($curTop -ge 0 -and ($ch - $curTop) -ge $MIN_ROWS) {
  $blocks += [pscustomobject]@{ Top=$curTop; Bottom=$ch; Width=($curRuns | Measure-Object -Maximum).Maximum; Start=($curStarts | Measure-Object -Minimum).Minimum }
}
$blocks | ForEach-Object { Write-Host "  candidate block: rows $($_.Top)..$($_.Bottom) ($($_.Bottom-$_.Top)px tall), $($_.Width)px wide, starting x=$($_.Start)" }

# The primary action is the lowest such block: onboarding puts it in the footer.
$btn = $blocks | Sort-Object Top -Descending | Select-Object -First 1
if (-not $btn) {
  Write-Host "::error::No primary button found. Nothing in the lower half of the window is a block of colour at least ${MIN_RUN}px wide and ${MIN_ROWS}px tall, so there is nothing a user could press."
  exit 1
}
$btnX = $origin.X + $btn.Start + [int]($btn.Width / 2)
$btnY = $origin.Y + [int](($btn.Top + $btn.Bottom) / 2)
Write-Host "primary button: rows $($btn.Top)..$($btn.Bottom), $($btn.Width)px wide. Clicking screen ($btnX,$btnY)"

# ── Negative control ─────────────────────────────────────────────────────────
# Empty background, well clear of the button block found above.
$controlX = $origin.X + [int]($cw * 0.06)
$controlY = $origin.Y + [int](($btn.Top) * 0.6)
Write-Host "negative control: clicking empty background at ($controlX,$controlY)"
Click $controlX $controlY
$afterControl = Grab $rect
$afterControl.Save("$OutDir/02-after-control-click.png")
$controlDiff = DiffFraction $before $afterControl
Write-Host ("control diff: {0:P3}" -f $controlDiff)
if ($controlDiff -gt 0.002) {
  Write-Host "::error::Clicking empty background changed the screen. Something is animating or repainting, so a pixel comparison cannot tell a live button from a dead one here. Not reporting a result from a measurement that cannot support it."
  exit 1
}

# ── The real click ───────────────────────────────────────────────────────────
Click $btnX $btnY
$after = Grab $rect
$after.Save("$OutDir/03-after-primary-click.png")

# Measured with the button's own rows excluded, so the answer is about the REST of the screen.
# A live primary button navigates: the heading, the body copy and the controls all change. A
# dead one leaves everything outside itself exactly as it was.
$diff = DiffFraction $afterControl $after $btn.Top $btn.Bottom
$withButton = DiffFraction $afterControl $after
Write-Host ("primary click diff, excluding the button's own rows: {0:P3}" -f $diff)
Write-Host ("  for reference, including them: {0:P3}" -f $withButton)

if ($diff -lt 0.01) {
  Write-Host "::error::The primary button did nothing. Outside the button itself, the screen is unchanged after a real mouse press on it, so nothing was navigated to and no state changed. Compare 02-after-control-click.png with 03-after-primary-click.png."
  exit 1
}
Write-Host "The primary button is live: a real click changed the screen beyond the button itself."
