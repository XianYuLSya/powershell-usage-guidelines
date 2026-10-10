#Requires -Version 5.1
<#
.SYNOPSIS
    Run a native Windows command and decode its output with an encoding you
    chose deliberately, instead of one you hoped for.

.DESCRIPTION
    The usual way to capture a native command is to let PowerShell decode it for
    you. That works until it does not, and when it fails it fails quietly: you
    get mojibake, or letters spaced out by NUL characters, or a message that
    looks like a program bug.

    This script reads the child's stdout and stderr as RAW BYTES, then decodes
    them with a named encoding. Nothing is guessed unless you ask for -Encoding
    Auto, and even then the choice is reported back to you so you can check it.

    Both streams are drained asynchronously, so a child that writes a lot to
    stderr cannot deadlock on a full pipe.

.PARAMETER FilePath
    Executable to run, for example 'wsl.exe' or 'docker'.

.PARAMETER ArgumentList
    Arguments, passed as a real array. Structural arguments only (flags, paths,
    numbers). On Windows PowerShell 5.1 there is no argument-list API on
    ProcessStartInfo, so this is assembled into a command line and non-ASCII
    payloads can corrupt - pass those through the environment or a file.

.PARAMETER Encoding
    How to decode the captured bytes:
      Auto     - decide from BOM, strict decoding and NUL density, and report
                 which verdict was used. Read the verdict before trusting it.
      Utf16LE  - UTF-16 little endian. Common for native commands that detect a
                 redirected handle.
      Utf8     - UTF-8.
      Oem      - the OEM code page (console default), from the registry.
      Ansi     - the ANSI code page, from the registry.

.PARAMETER TimeoutSeconds
    Wall-clock budget. On expiry the process is killed and TimedOut is true -
    which is reported as a launch/run outcome, never disguised as latency.

.EXAMPLE
    .\Invoke-NativeCommand.ps1 wsl.exe @('--help')

.EXAMPLE
    $r = .\Invoke-NativeCommand.ps1 docker @('version') -Encoding Utf8
    if ($r.ExitCode -eq 0) { $r.StdOut }

.EXAMPLE
    # Why is this garbled? Ask, and read the verdict.
    (.\Invoke-NativeCommand.ps1 some-tool.exe -Encoding Auto).EncodingUsed
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FilePath,

    [Parameter(Position = 1)]
    [string[]]$ArgumentList = @(),

    [ValidateSet('Auto', 'Utf16LE', 'Utf8', 'Oem', 'Ansi')]
    [string]$Encoding = 'Auto',

    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-CodePageByName {
    param([string]$Name)
    switch ($Name) {
        'Utf16LE' { return 1200 }
        'Utf8'    { return 65001 }
        'Oem'     { return [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').OEMCP }
        'Ansi'    { return [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').ACP }
    }
    return 65001
}

function Get-ZeroByteRatio {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return 0 }
    $zero = 0
    foreach ($b in $Bytes) { if ($b -eq 0) { $zero++ } }
    return [double]$zero / [double]$Bytes.Length
}

function Test-StrictDecode {
    param([byte[]]$Bytes, [int]$CodePage)
    try {
        $enc = [System.Text.Encoding]::GetEncoding(
            $CodePage,
            [System.Text.EncoderFallback]::ExceptionFallback,
            [System.Text.DecoderFallback]::ExceptionFallback)
        return $enc.GetString($Bytes)
    } catch {
        return $null
    }
}

function Resolve-AutoEncoding {
    # Returns the code page and a human-readable verdict. A wrong verdict here is
    # worse than no verdict, so every branch says what it is based on.
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return [pscustomobject]@{ codePage = 65001; verdict = 'empty output; UTF-8 assumed' }
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [pscustomobject]@{ codePage = 65001; verdict = 'UTF-8 (BOM EF BB BF)' }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [pscustomobject]@{ codePage = 1200; verdict = 'UTF-16LE (BOM FF FE)' }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [pscustomobject]@{ codePage = 1201; verdict = 'UTF-16BE (BOM FE FF)' }
    }

    $strictUtf8 = Test-StrictDecode -Bytes $Bytes -CodePage 65001
    $strictUtf16 = Test-StrictDecode -Bytes $Bytes -CodePage 1200
    $zeroRatio = Get-ZeroByteRatio -Bytes $Bytes
    $evenLength = (($Bytes.Length % 2) -eq 0)

    if ($null -eq $strictUtf8 -and $null -ne $strictUtf16 -and $evenLength) {
        return [pscustomobject]@{ codePage = 1200; verdict = ('UTF-16LE (no BOM; strict UTF-8 failed, strict UTF-16LE passed, NUL density {0}%)' -f [Math]::Round($zeroRatio * 100, 1)) }
    }
    if ($evenLength -and $zeroRatio -gt 0.15) {
        return [pscustomobject]@{ codePage = 1200; verdict = ('UTF-16LE by NUL density {0}% (ambiguous bytes; verify before trusting)' -f [Math]::Round($zeroRatio * 100, 1)) }
    }
    return [pscustomobject]@{ codePage = 65001; verdict = ('UTF-8 assumed (no BOM, strict UTF-8 passed, NUL density {0}%)' -f [Math]::Round($zeroRatio * 100, 1)) }
}

# ---------------------------------------------------------------------------
# Launch with raw-byte capture
# ---------------------------------------------------------------------------
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $FilePath
# No ArgumentList property exists on PowerShell 5.1's ProcessStartInfo, so quote
# only the tokens that need it. Keep non-ASCII payloads out of argv (see docs).
$quoted = @()
foreach ($a in $ArgumentList) {
    $s = [string]$a
    if ($s -match '[\s"]') {
        $s = '"' + ($s -replace '(\\*)"', '$1$1\"') + '"'
    }
    $quoted += $s
}
$psi.Arguments = ($quoted -join ' ')
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not $proc.Start()) {
    throw ('Failed to start process: {0}' -f $FilePath)
}

# Drain both pipes on background tasks. CopyToAsync on the BASE STREAM gives raw
# bytes and bypasses the StreamReader decoding entirely.
$outBuffer = New-Object System.IO.MemoryStream
$errBuffer = New-Object System.IO.MemoryStream
$outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outBuffer)
$errTask = $proc.StandardError.BaseStream.CopyToAsync($errBuffer)

$exited = $proc.WaitForExit([int]($TimeoutSeconds * 1000))
$timedOut = -not $exited
if ($timedOut) {
    try { $proc.Kill() } catch { }
    [void]$proc.WaitForExit(5000)
}
$sw.Stop()

# Give the readers a bounded moment to finish flushing.
$drainMs = 5000
try { [void]$outTask.Wait($drainMs) } catch { }
try { [void]$errTask.Wait($drainMs) } catch { }

$outBytes = $outBuffer.ToArray()
$errBytes = $errBuffer.ToArray()

# Read ExitCode before Dispose: the property lives on the process handle, so
# reading it afterwards silently yields $null instead of an error.
$exitCode = $null
if (-not $timedOut) {
    try { $exitCode = $proc.ExitCode } catch { $exitCode = $null }
}
$proc.Dispose()

# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------
# A single encoding choice for both streams keeps the result predictable. If one
# stream is empty its bytes cannot affect the verdict, so it is safe to include
# both only when both carry data.
$verdictText = 'caller-specified'
if ($Encoding -eq 'Auto') {
    $sample = $outBytes
    if ($sample.Length -eq 0) { $sample = $errBytes }
    $auto = Resolve-AutoEncoding -Bytes $sample
    $codePage = $auto.codePage
    $verdictText = $auto.verdict
} else {
    $codePage = Get-CodePageByName -Name $Encoding
    $verdictText = ('{0} (CP{1}), chosen by the caller' -f $Encoding, $codePage)
}

$decoder = [System.Text.Encoding]::GetEncoding($codePage)

[pscustomobject]@{
    FilePath     = $FilePath
    Arguments    = $psi.Arguments
    ExitCode     = $exitCode
    TimedOut     = $timedOut
    ElapsedMs    = [int]$sw.ElapsedMilliseconds
    EncodingUsed = ('CP{0} - {1}' -f $codePage, $verdictText)
    StdOutBytes  = $outBytes.Length
    StdErrBytes  = $errBytes.Length
    StdOut       = $decoder.GetString($outBytes)
    StdErr       = $decoder.GetString($errBytes)
}
