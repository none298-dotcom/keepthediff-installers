# Pins Keep the Diff's three widgets on the real Windows 11 Widgets Board and photographs the
# result. Run it on the `windows-11-arm` runner, with the app already installed and its widget
# package registered. scripts/board.ps1 holds every fact about what this runner will and will not
# do, and why each step is shaped the way it is; the short version:
#
#   * Injected input is dropped here, so every press is UI Automation's InvokePattern, the same
#     path a screen reader user's press takes. What that does NOT prove is hit-testing, and the
#     screenshots are what stand behind that.
#   * Nothing presents to the framebuffer, so screenshots are PrintWindow against named windows and
#     are retried until they draw.
#   * The board dismisses itself because it cannot get the foreground. It hides rather than closing,
#     and everything here reads it by window handle, hidden or not.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $OutDir,
  [string] $AppExe = "",
  [string[]] $Widgets = @("This Week", "Goal", "Log a Diff"),
  [string] $Provider = "Keep the Diff"
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\board.ps1"
Start-Board $OutDir

$failures = New-Object System.Collections.Generic.List[string]
function Fail([string] $why) { Write-Host "::error::$why"; $failures.Add($why) }

# ── The board ────────────────────────────────────────────────────────────────
[void](Clear-Intruders)
if (-not (Ensure-Board)) { throw "The Widgets Board never opened on this runner" }
Save-BoardShot "board-before-anything-is-pinned" -Required | Out-Null
Save-Tree "board-before" | Out-Null

# ── Is Keep the Diff in the picker at all ────────────────────────────────────
[void](Wake-Accessibility)
$add = Wait-Element "Add widgets" 240 "Button"
if (-not $add) {
  Save-Tree "board-with-no-add-button" | Out-Null
  throw "The board drew, but four minutes of asking never produced an 'Add widgets' button in its accessibility tree"
}
Write-Host "the add button: $(Show-Element $add)"
[void](Press-Element $add)
if (-not (Wait-Picker 150)) { throw "The widget picker never finished loading" }
Save-Tree "picker" | Out-Null

$bmp = Get-PickerImage
if ($bmp) {
  $file = Join-Path $OutDir "10-picker.png"
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host "shot: $file  $($bmp.Width)x$($bmp.Height), $(Measure-Colours $bmp) colours"
  $bmp.Dispose()
} else { Fail "The picker would not draw, so there is no picture of Keep the Diff in it" }

$listed = @(Find-Elements "" (Get-PickerRoot) | Where-Object { "$($_.Current.ControlType.ProgrammaticName)" -match 'ListItem' } |
  ForEach-Object { $_.Current.Name })
Write-Host "the picker lists: $($listed -join ' | ')"
($listed -join "`n") | Out-File (Join-Path $OutDir "what-the-picker-lists.txt")
if (-not ($listed | Where-Object { $Widgets -contains $_ })) {
  Fail "The widget picker does not list any of $($Widgets -join ', '): the board is not offering this provider"
}

# ── Pin each one ─────────────────────────────────────────────────────────────
$pinned = New-Object System.Collections.Generic.List[string]
foreach ($widget in $Widgets) {
  Write-Host "=== pinning '$widget' ==="
  $root = Get-PickerRoot
  if (-not $root) { Fail "The picker closed before '$widget' could be pinned"; break }
  $item = Find-Elements $widget $root | Where-Object { "$($_.Current.ControlType.ProgrammaticName)" -match 'ListItem' } | Select-Object -First 1
  if (-not $item) { Fail "'$widget' is not listed in the widget picker"; continue }
  Write-Host "  picker entry: $(Show-Element $item)"
  try { $item.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView() } catch {}
  try { [void](Press-Element $item) } catch { Fail "'$widget' could not be selected in the picker: $($_.Exception.Message)"; continue }
  Start-Sleep 4

  $bmp = Get-PickerImage 10
  if ($bmp) {
    $file = Join-Path $OutDir ("11-picker-{0}.png" -f ($widget -replace '[^A-Za-z0-9]', ''))
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "  shot: $file  $(Measure-Colours $bmp) colours"
    $bmp.Dispose()
  }

  $pin = Find-Elements "Pin" (Get-PickerRoot) | Where-Object { "$($_.Current.ControlType.ProgrammaticName)" -match 'Button' } | Select-Object -First 1
  if (-not $pin) { Fail "The picker offers no Pin button for '$widget'"; continue }
  try { [void](Press-Element $pin) } catch { Fail "Pin would not press for '$widget': $($_.Exception.Message)"; continue }
  Start-Sleep 6
  $pinned.Add($widget)
  Write-Host "  pinned '$widget'"
}

# ── The board with the cards on it ───────────────────────────────────────────
$close = Find-Elements "Close" (Get-PickerRoot) | Where-Object { "$($_.Current.ControlType.ProgrammaticName)" -match 'Button' } | Select-Object -First 1
if ($close) { try { [void](Press-Element $close) } catch {} }
Start-Sleep 8

if (-not (Ensure-Board)) { Fail "The board could not be read again after pinning" }
Save-BoardShot "board-with-the-widgets-pinned" | Out-Null
Save-Tree "board-after" | Out-Null

foreach ($widget in $pinned) {
  $card = Find-Elements $widget (Get-BoardRoot) | Where-Object {
    "$($_.Current.ControlType.ProgrammaticName)" -match 'Group' -and $_.Current.BoundingRectangle.Height -gt 60
  } | Select-Object -First 1
  if (-not $card) { Fail "'$widget' was pinned but no card of that name is on the board"; continue }
  Write-Host "card: $(Show-Element $card)"
  if (-not (Save-ElementShot $card ("card-" + ($widget -replace '[^A-Za-z0-9]', '')))) {
    Fail "'$widget' is on the board but would not photograph"
  }
}

# ── Does a click on Log a Diff open the app ──────────────────────────────────
if ($AppExe -and $pinned -contains "Log a Diff") {
  Write-Host "=== clicking Log a Diff ==="
  Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($AppExe)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 5
  function AppProcesses { @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $AppExe }) }
  if ((AppProcesses).Count -ne 0) { Fail "Keep the Diff was already running, so a launch would prove nothing" }
  else {
    $card = Find-Elements "Log a Diff" (Get-BoardRoot) | Select-Object -First 1
    if (-not $card) { Fail "No Log a Diff card to click" }
    else {
      try { [void](Press-Element $card) } catch { Fail "The Log a Diff card would not press: $($_.Exception.Message)" }
      $deadline = (Get-Date).AddSeconds(120)
      while ((AppProcesses).Count -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
      Start-Sleep 10
      $procs = AppProcesses
      if ($procs.Count -eq 0) { Fail "Clicking Log a Diff on the board did not start Keep the Diff" }
      else {
        $procs | ForEach-Object { Write-Host "  app pid $($_.ProcessId): $($_.CommandLine)" }
        ($procs | ForEach-Object { "$($_.ProcessId)  $($_.CommandLine)" }) | Out-File (Join-Path $OutDir "log-a-diff-started-the-app.txt")
        if (-not ($procs | Where-Object { $_.CommandLine -like '*--screen=add*' })) {
          Fail "The app started, but not on Log a Diff: no process carries --screen=add"
        }
      }
    }
  }
}

"pinned: $($pinned -join ', ')" | Out-File (Join-Path $OutDir "what-was-pinned.txt")
if ($failures.Count -gt 0) { throw "$($failures.Count) thing(s) the board did not do: $($failures -join '; ')" }
Write-Host "ok: the picker listed $Provider, the widgets pinned, the board drew them, and Log a Diff opened the app"
