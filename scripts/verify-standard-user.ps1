# Proves that a standard, NON-ADMIN user can see and open what was just installed.
#
# WHY THIS EXISTS
# Every other check in this workflow runs as `runneradmin`, and so does every check anybody has
# ever run on this app by hand: the developer's own machine, a local VM, this runner. All of them
# are the administrator. That is the one account for which a per-user install looks perfectly fine.
#
# The failure it is written for is the one the certifier actually performs: install elevated, then
# come back as an ordinary user and try to use the thing. If the payload landed in the installing
# administrator's profile, the ordinary user sees nothing at all, and the report says the app
# cannot be launched. The 10.1.2.10 assertion already catches the common shape of that by looking
# at WHERE the shortcut went. This asks the question the other way round, from the account that
# actually has something to lose, and it catches shapes a path check cannot: a shortcut in the
# right place pointing at a binary the user cannot read, an install directory whose ACL never
# granted Users traverse, a target that does not exist.
#
# WHY IT DOES NOT LAUNCH THE GUI AS THAT USER
# It was the obvious first draft and it is a false-red machine. `Start-Process -Credential` runs
# the new process on its own window station, so a Compose Desktop window has no interactive
# desktop to draw on and dies for reasons that have nothing to do with the installer. A red that
# means "CI could not show a window" teaches nobody anything and gets ignored, which is worse than
# no check. The GUI is already launched and clicked, as admin, by the steps around this one.
#
# So the probe is a CONSOLE script run genuinely as the standard user, writing its findings to a
# file the caller reads back. Headless, deterministic, and it still runs under that user's token
# and that user's ACL evaluation, which is the whole point.
#
# HOW TO SEE IT GO RED
# `-f break_mode=deny_users_read`, and NOT per_user_install, which was the obvious choice and
# proves nothing here: that mutation fails the certification step, which throws, and every step
# after it including this one is skipped. A check that has only ever been skipped is a check
# nobody has seen work.
# deny_users_read leaves the install perfectly certifiable and breaks exactly what this script is
# for: the shortcut is in the right place, points at the right binary, and an ordinary user is not
# allowed to read it. Run it before believing a green from here.

param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [string]$OutDir = "artifacts"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$userName = "tlvstduser"
# C:\Users\Public, not C:\ProgramData. The first draft used ProgramData and the probe never
# produced a file: its root grants Users read and execute, not write, so a standard user cannot
# drop a result there. Public grants Users modify by default, which is exactly the point of it.
$probeScript = "C:\Users\Public\tlv-stduser-probe.ps1"
$probeOutput = "C:\Users\Public\tlv-stduser-probe.json"
$probeStdout = "C:\Users\Public\tlv-stduser-probe.out.txt"
$probeStderr = "C:\Users\Public\tlv-stduser-probe.err.txt"
$created = $false

function Remove-ProbeUser {
    if ($script:created) {
        Write-Host "cleaning up: removing $userName"
        net user $userName /delete 2>&1 | Out-Null
    }
    Remove-Item $probeScript, $probeOutput, $probeStdout, $probeStderr -Force -ErrorAction SilentlyContinue
}

try {
    # A password generated per run rather than a literal. Nothing here is a secret worth keeping,
    # but a fixed password in a public repo is a bad habit that eventually gets copied somewhere
    # it matters.
    $password = "Tlv!" + ([guid]::NewGuid().ToString("N").Substring(0, 12)) + "aA1"

    net user $userName $password /add /y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create the standard user account" }
    $created = $true

    # Users, and ONLY Users. The moment this account is in Administrators the check is testing
    # nothing, because that is the account every other step already runs as.
    net localgroup Users $userName /add 2>&1 | Out-Null
    $admins = (net localgroup Administrators) -join "`n"
    if ($admins -match [regex]::Escape($userName)) {
        throw "$userName ended up in Administrators, so this check would prove nothing"
    }
    Write-Host "created $userName, member of Users and not Administrators"

    # The probe. Deliberately dumb: it looks, it records, it judges nothing. Every decision is
    # made by the caller, where the reasoning is readable.
    $probe = @'
param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][string]$Out)
$result = [ordered]@{}
$exe = $Exe
$result.exePath = $exe
$result.exeExists = Test-Path -LiteralPath $exe
$result.exeReadable = $false
if ($result.exeExists) {
    try {
        $fs = [System.IO.File]::Open($exe, "Open", "Read", "ReadWrite")
        $buffer = New-Object byte[] 2
        $null = $fs.Read($buffer, 0, 2)
        $fs.Close()
        # "MZ". Reading two bytes proves the ACL allows it in a way Test-Path does not.
        $result.exeReadable = ($buffer[0] -eq 0x4D -and $buffer[1] -eq 0x5A)
    } catch {
        $result.exeReadError = $_.Exception.Message
    }
}

$startMenu = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
$shortcuts = @()
if (Test-Path $startMenu) {
    $shortcuts = @(Get-ChildItem $startMenu -Recurse -Filter "*Keep the Diff*.lnk" -ErrorAction SilentlyContinue)
}
$result.shortcutCount = $shortcuts.Count
$result.shortcuts = @()
foreach ($s in $shortcuts) {
    $entry = [ordered]@{ path = $s.FullName; target = $null; targetExists = $false }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $entry.target = $shell.CreateShortcut($s.FullName).TargetPath
        $entry.targetExists = [bool]($entry.target -and (Test-Path -LiteralPath $entry.target))
    } catch {
        $entry.targetError = $_.Exception.Message
    }
    $result.shortcuts += $entry
}

$result.whoami = whoami
$result.isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Out -Encoding UTF8
'@
    Set-Content -LiteralPath $probeScript -Value $probe -Encoding UTF8

    # World-readable, because the point is that a standard user can run it.
    icacls $probeScript /grant "Users:(RX)" 2>&1 | Out-Null
    Remove-Item $probeOutput -Force -ErrorAction SilentlyContinue

    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential("$env:COMPUTERNAME\$userName", $secure)

    # ARGUMENTS, not environment variables. The first draft set them machine-scope and the probe
    # saw nothing: a machine-scope variable does not enter the CURRENT process's environment, and
    # Start-Process hands the child a copy of the current one. Arguments cross the logon boundary
    # with no such subtlety.
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $probeScript + '"' +
                 ' -Exe "' + $ExePath + '"' +
                 ' -Out "' + $probeOutput + '"'

    Write-Host "running the probe as $userName"
    # -NoNewWindow, or Start-Process opens a console on the interactive desktop and whatever was
    # in front stops being in front. That cost a green once already; see the workflow step's
    # comment. This step runs last now, but a check that disturbs the machine it is measuring is
    # worth not writing twice.
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments `
        -Credential $credential -PassThru -NoNewWindow `
        -RedirectStandardOutput $probeStdout -RedirectStandardError $probeStderr
    $process.WaitForExit(120000) | Out-Null
    Write-Host "probe exit code: $($process.ExitCode)"

    # Printed BEFORE the existence check. The first version threw "no output" and said nothing
    # else, which told whoever read it that something went wrong and nothing about what.
    foreach ($pair in @(@("stdout", $probeStdout), @("stderr", $probeStderr))) {
        if (Test-Path $pair[1]) {
            $text = (Get-Content -LiteralPath $pair[1] -Raw)
            if ($text -and $text.Trim()) { Write-Host "--- probe $($pair[0]) ---`n$text" }
        }
    }

    if (-not (Test-Path $probeOutput)) {
        throw "The probe produced no output, so nothing is proven either way. Its exit code and streams are above."
    }

    $probeResult = Get-Content -LiteralPath $probeOutput -Raw | ConvertFrom-Json
    Copy-Item $probeOutput (Join-Path $OutDir "standard-user-probe.json") -Force

    Write-Host "probe ran as:   $($probeResult.whoami)"
    Write-Host "probe is admin: $($probeResult.isAdmin)"
    Write-Host "exe exists:     $($probeResult.exeExists)"
    Write-Host "exe readable:   $($probeResult.exeReadable)"
    Write-Host "shortcuts seen: $($probeResult.shortcutCount)"
    foreach ($s in $probeResult.shortcuts) {
        Write-Host "  $($s.path)"
        Write-Host "    -> $($s.target)  (target exists: $($s.targetExists))"
    }

    $failures = 0

    if ($probeResult.isAdmin) {
        Write-Host "::error::The probe ran with administrator rights, so it was not testing a standard user and its result means nothing."
        $failures++
    }

    if (-not $probeResult.exeExists) {
        Write-Host "::error::A standard user cannot see the installed binary at $($probeResult.exePath). Installed into somewhere only the installing administrator can reach, which is the per-user install that fails certification."
        $failures++
    }
    elseif (-not $probeResult.exeReadable) {
        Write-Host "::error::A standard user can see the installed binary but cannot READ it: $($probeResult.exeReadError). The path is right and the ACL is not, so the app is unlaunchable for everyone except the account that installed it."
        $failures++
    }
    else {
        Write-Host "ok, a standard user can read the installed binary"
    }

    if ($probeResult.shortcutCount -lt 1) {
        Write-Host "::error::A standard user sees no Start Menu shortcut. This is 10.1.2.10 asked from the account that matters: the shortcut check above looks at where the file went, this looks at whether an ordinary user can actually find it."
        $failures++
    }
    else {
        $reachable = @($probeResult.shortcuts | Where-Object { $_.targetExists })
        if ($reachable.Count -lt 1) {
            Write-Host "::error::A standard user sees the shortcut but its target does not resolve for them, so clicking it does nothing."
            $failures++
        }
        else {
            Write-Host "ok, a standard user sees a shortcut whose target resolves"
        }
    }

    if ($failures -gt 0) { throw "$failures standard-user check(s) failed" }
    Write-Host "A standard, non-admin user can find and open this install."
}
finally {
    Remove-ProbeUser
}
