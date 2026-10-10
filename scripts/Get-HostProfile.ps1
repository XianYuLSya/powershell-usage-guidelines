#Requires -Version 5.1
<#
.SYNOPSIS
    Establish ground truth about the current Windows host before trusting any
    assumption about PowerShell, console encoding, or native command output.

.DESCRIPTION
    This script assumes NOTHING. It measures. Every line it prints is backed by
    bytes it actually read on this machine, and every verdict carries its
    evidence.

    Run it on a new machine, read the output, and write the observed facts into
    the "Host profile" section of SKILL.md. Until you do that, that section says
    [UNVERIFIED] - and [UNVERIFIED] means "nobody has checked this here yet".

    Probes performed:
      1. Shell identity  - Windows PowerShell version, current shell, code pages.
      2. Native capture  - redirect a native command to a file, inspect the raw
                           bytes, and decide the encoding from evidence rather
                           than from a guess. Includes a length self-check.
      3. Script reading  - write a .ps1 containing non-ASCII twice (no BOM and
                           with BOM), run both under Windows PowerShell 5.1, and
                           compare reported code points. The with-BOM run is a
                           control: if both disagree with the expectation, the
                           probe itself is broken and the result must be ignored.
      4. Path hazards    - whether the user profile path is pure ASCII, because
                           non-ASCII paths break some tools in ways that look
                           like network or TLS failures.
      5. Optional scan   - find .ps1/.psm1 files under -ScanPath that contain
                           non-ASCII bytes but no BOM (a latent hazard on hosts
                           where 5.1 reads them as ANSI).

.PARAMETER ProbeCommand
    Native command to redirect and inspect. Defaults to 'wsl.exe --help' because
    wsl.exe is a well-known UTF-16LE emitter; use any command you care about.

.PARAMETER ScanPath
    Optional directory to scan for non-ASCII/no-BOM PowerShell files.

.PARAMETER Json
    Emit a single JSON object instead of text. Useful for automation.

.EXAMPLE
    .\Get-HostProfile.ps1

.EXAMPLE
    .\Get-HostProfile.ps1 -ProbeCommand 'docker version' -Json

.NOTES
    Windows PowerShell 5.1 compatible on purpose: no ternary operator, no null
    coalescing, no Format-Hex -Count. This script must run on the older shell,
    because that is exactly where the encoding traps live.
#>
[CmdletBinding()]
param(
    [string]$ProbeCommand = 'wsl.exe --help',
    [string]$ScanPath = '',
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$facts = [ordered]@{}

function Get-ZeroByteRatio {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return 0 }
    $zero = 0
    foreach ($b in $Bytes) { if ($b -eq 0) { $zero++ } }
    return [double]$zero / [double]$Bytes.Length
}

function Test-StrictDecode {
    # A decoder that throws on the first illegal byte sequence. If an encoding
    # can decode the buffer strictly, that encoding is a real candidate. If it
    # cannot, that encoding is ruled out. This is much stronger than "it looked
    # like mojibake to me".
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

function Get-EncodingVerdict {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return [pscustomobject]@{ name = 'empty'; evidence = 'zero bytes were produced' }
    }

    # A BOM is proof, so check it first.
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [pscustomobject]@{ name = 'UTF-8 (BOM)'; evidence = 'first three bytes EF BB BF' }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [pscustomobject]@{ name = 'UTF-16LE (BOM)'; evidence = 'first two bytes FF FE' }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [pscustomobject]@{ name = 'UTF-16BE (BOM)'; evidence = 'first two bytes FE FF' }
    }

    # No BOM: fall back to strict decoding plus the zero-byte density, which is
    # high for UTF-16 text that is mostly ASCII and ~0 for single-byte encodings.
    $strictUtf8 = Test-StrictDecode -Bytes $Bytes -CodePage 65001
    $strictUtf16 = Test-StrictDecode -Bytes $Bytes -CodePage 1200
    $zeroRatio = Get-ZeroByteRatio -Bytes $Bytes
    $evenLength = (($Bytes.Length % 2) -eq 0)

    $utf8Text = 'failed'
    if ($null -ne $strictUtf8) { $utf8Text = 'succeeded' }
    $utf16Text = 'failed'
    if ($null -ne $strictUtf16) { $utf16Text = 'succeeded' }

    $evidence = 'no BOM; zero-byte ratio {0}%; strict UTF-8 decode {1}; strict UTF-16LE decode {2}' -f `
        [Math]::Round($zeroRatio * 100, 1), $utf8Text, $utf16Text

    if ($null -ne $strictUtf8 -and $null -eq $strictUtf16) {
        return [pscustomobject]@{ name = 'UTF-8 / single-byte (no BOM)'; evidence = $evidence }
    }
    if ($null -eq $strictUtf8 -and $null -ne $strictUtf16 -and $evenLength) {
        return [pscustomobject]@{ name = 'UTF-16LE (no BOM)'; evidence = $evidence }
    }
    if ($null -ne $strictUtf8 -and $null -ne $strictUtf16) {
        # Pure ASCII decodes cleanly either way, so decide on zero density.
        if ($evenLength -and $zeroRatio -gt 0.15) {
            return [pscustomobject]@{ name = 'UTF-16LE (no BOM, by zero-byte density)'; evidence = $evidence }
        }
        return [pscustomobject]@{ name = 'UTF-8 or ANSI/OEM (indistinguishable for pure ASCII)'; evidence = $evidence }
    }
    return [pscustomobject]@{ name = 'undetermined'; evidence = $evidence }
}

# ---------------------------------------------------------------------------
# 1. Shell identity
# ---------------------------------------------------------------------------
Write-Verbose 'Probing shell identity...'

$nls = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'
$ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ps51Version = 'not installed'
if (Test-Path -LiteralPath $ps51Path) {
    $ps51Version = (& $ps51Path -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1)
}

$facts.machineName = $env:COMPUTERNAME
$facts.collectedAt = (Get-Date).ToString('o')
$facts.currentShell = ('{0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
$facts.windowsPowerShell51 = $ps51Version
$facts.acp = [string]$nls.ACP
$facts.oemcp = [string]$nls.OEMCP
$facts.consoleOutputEncoding = ('{0} / CP{1}' -f [Console]::OutputEncoding.WebName, [Console]::OutputEncoding.CodePage)
$facts.consoleInputEncoding = ('{0} / CP{1}' -f [Console]::InputEncoding.WebName, [Console]::InputEncoding.CodePage)

# ---------------------------------------------------------------------------
# 2. Native command capture encoding
# ---------------------------------------------------------------------------
Write-Verbose ('Probing native capture for: {0}' -f $ProbeCommand)

$captureFile = Join-Path $env:TEMP ('host-profile-' + [guid]::NewGuid().ToString('N') + '.bin')
$capture = [ordered]@{
    command       = $ProbeCommand
    exitCode      = $null
    byteCount     = 0
    verdict       = 'not run'
    evidence      = ''
    lengthCheck   = ''
    firstBytesHex = ''
}
try {
    cmd /c "$ProbeCommand > `"$captureFile`" 2>&1" | Out-Null
    $capture.exitCode = $LASTEXITCODE

    if (Test-Path -LiteralPath $captureFile) {
        $captureBytes = [System.IO.File]::ReadAllBytes($captureFile)
        $capture.byteCount = $captureBytes.Length

        $verdict = Get-EncodingVerdict -Bytes $captureBytes
        $capture.verdict = $verdict.name
        $capture.evidence = $verdict.evidence

        if ($captureBytes.Length -gt 0) {
            # For UTF-16 the character count must be exactly half the byte count.
            # When it is not, the file is not UTF-16 and the verdict above was a
            # false positive - report that instead of a confident wrong answer.
            $codePage = 65001
            if ($verdict.name -like 'UTF-16*') { $codePage = 1200 }
            $decodedCharCount = ([System.Text.Encoding]::GetEncoding($codePage)).GetString($captureBytes).Length

            if ($verdict.name -like 'UTF-16*') {
                $half = [int]($captureBytes.Length / 2)
                if ($half -eq $decodedCharCount) {
                    $capture.lengthCheck = ('byteCount/2 = {0} equals decoded char count -> consistent' -f $half)
                } else {
                    $capture.lengthCheck = ('byteCount/2 = {0} but decoded char count = {1} -> INCONSISTENT, treat the verdict as unreliable' -f $half, $decodedCharCount)
                }
            } else {
                $capture.lengthCheck = 'not applicable (not a UTF-16 verdict)'
            }

            $head = $captureBytes
            if ($captureBytes.Length -gt 16) { $head = $captureBytes[0..15] }
            $capture.firstBytesHex = (($head | ForEach-Object { $_.ToString('X2') }) -join ' ')
        }
    } else {
        $capture.verdict = 'no output file produced (command could not run)'
    }
} finally {
    if (Test-Path -LiteralPath $captureFile) { Remove-Item -LiteralPath $captureFile -Force }
}
$facts.nativeCapture = $capture

# ---------------------------------------------------------------------------
# 3. How the old shell reads a .ps1 file (the reverse direction)
# ---------------------------------------------------------------------------
# The probe prints CODE POINTS, never the characters themselves. Printing the
# characters would route them through the very capture path under test and
# confound the result. Code points are pure ASCII digits, so they survive any
# console encoding.
Write-Verbose 'Probing no-BOM .ps1 reading behaviour under PowerShell 5.1...'

$scriptReading = [ordered]@{
    expected    = '20013,25991,25506,38024,65,66,67'
    noBom       = 'not run'
    withBom     = 'not run'
    verdict     = ''
    controlOk   = $false
}
$scriptReading.expected = '20013,25991,25506,38024,65,66,67'   # code points of the non-ASCII probe string

if (-not (Test-Path -LiteralPath $ps51Path)) {
    $scriptReading.verdict = 'skipped: Windows PowerShell 5.1 not present'
} else {
    $probeFile = Join-Path $env:TEMP ('bom-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $bom = [byte[]](0xEF, 0xBB, 0xBF)

    # The probe file must physically CONTAIN non-ASCII bytes, otherwise there is
    # nothing to misread and the probe passes vacuously while proving nothing.
    # That is not hypothetical: an earlier version of this script built the probe
    # string with [char]0x.... escapes, which left the generated file pure ASCII,
    # and it then reported "this host reads no-BOM scripts correctly" on a host
    # that demonstrably does not. Keep this file ASCII-only by assembling the
    # bytes instead of typing the characters, and keep the assertion below.
    $cjk = [string]([char]0x4E2D + [char]0x6587 + [char]0x63A2 + [char]0x9488)
    $prefixText = '$s = "'
    $suffixText = '"' + "`r`n" + 'Write-Output (($s.ToCharArray() | ForEach-Object { [int]$_ }) -join ",")' + "`r`n"
    $probeBytes = $utf8NoBom.GetBytes($prefixText + $cjk + 'ABC' + $suffixText)

    $probeHasNonAscii = $false
    foreach ($b in $probeBytes) { if ($b -gt 0x7F) { $probeHasNonAscii = $true; break } }

    if (-not $probeHasNonAscii) {
        # Refuse to answer rather than answer wrongly.
        $scriptReading.verdict = 'UNRELIABLE: the generated probe file contains no non-ASCII bytes, so it cannot detect an encoding problem at all. This is a bug in the probe, not a fact about the host.'
    } else {
        try {
            [System.IO.File]::WriteAllBytes($probeFile, $probeBytes)
            $scriptReading.noBom = (& $ps51Path -NoProfile -ExecutionPolicy Bypass -File $probeFile 2>&1 | Out-String).Trim()

            [System.IO.File]::WriteAllBytes($probeFile, $bom + $probeBytes)
            $scriptReading.withBom = (& $ps51Path -NoProfile -ExecutionPolicy Bypass -File $probeFile 2>&1 | Out-String).Trim()

            $scriptReading.controlOk = ($scriptReading.withBom -eq $scriptReading.expected)

            if (-not $scriptReading.controlOk) {
                $scriptReading.verdict = 'UNRELIABLE: the with-BOM control did not reproduce the expected code points, so the probe or its invocation is wrong. Do not draw conclusions from this section.'
            } elseif ($scriptReading.noBom -eq $scriptReading.expected) {
                $scriptReading.verdict = 'This host reads a no-BOM UTF-8 .ps1 correctly under 5.1, so non-ASCII script content is safe here.'
            } else {
                $scriptReading.verdict = ('This host reads a no-BOM .ps1 as ANSI/CP{0} under 5.1. Save any .ps1 containing non-ASCII as UTF-8 WITH BOM, or keep script sources ASCII-only.' -f $facts.acp)
            }
        } finally {
            if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force }
        }
    }
}
$facts.scriptReading = $scriptReading

# ---------------------------------------------------------------------------
# 4. Path hazards
# ---------------------------------------------------------------------------
Write-Verbose 'Checking for non-ASCII path hazards...'

function Test-AsciiOnly {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $true }
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -gt 127) { return $false }
    }
    return $true
}

$pathHazards = [ordered]@{
    userProfile        = $env:USERPROFILE
    profileIsAscii     = (Test-AsciiOnly -Text $env:USERPROFILE)
    tempPath           = $env:TEMP
    tempIsAscii        = (Test-AsciiOnly -Text $env:TEMP)
    note               = ''
}
if (-not $pathHazards.profileIsAscii -or -not $pathHazards.tempIsAscii) {
    $pathHazards.note = 'A non-ASCII path is present. Some tools (bundled libcurl/TLS stacks in particular) fail on non-ASCII paths with misleading errors such as "error adding trust anchors". If a network tool fails here, test the same input from an ASCII-only directory under C:\ before blaming the network.'
} else {
    $pathHazards.note = 'User profile and TEMP are pure ASCII; non-ASCII path hazards are unlikely here.'
}
$facts.pathHazards = $pathHazards

# ---------------------------------------------------------------------------
# 5. Optional scan for latent script hazards
# ---------------------------------------------------------------------------
if ($ScanPath) {
    Write-Verbose ('Scanning {0} for non-ASCII scripts without BOM...' -f $ScanPath)
    $risky = @()
    $scriptCount = 0
    if (Test-Path -LiteralPath $ScanPath) {
        # Do NOT filter with -Include here. In Windows PowerShell 5.1, -Include is
        # SILENTLY IGNORED when it is combined with -LiteralPath: -Include needs a
        # wildcard in the -Path, and -LiteralPath forbids wildcards, so the filter
        # is dropped with no error or warning. Measured on a real repository:
        #   Get-ChildItem -LiteralPath X -Recurse -File -Include *.ps1,*.psm1  -> 6916 files
        #   ... -Recurse -File | Where-Object Extension -in '.ps1','.psm1'    ->   47 files
        # The -Include form returned 6869 non-PowerShell files (markdown, npm
        # cache blobs, images) and reported every one of them as a scan result.
        # Filter by Extension instead, and skip dependancy/runtime trees.
        $skipRegex = '\\(node_modules|_cacache|npm-cache|bower_components|\.git|\.venv|site-packages)\\'
        $candidates = @(Get-ChildItem -LiteralPath $ScanPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notmatch $skipRegex })
        foreach ($file in $candidates) {
            $scriptCount++
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $hasNonAscii = $false
            foreach ($b in $bytes) { if ($b -gt 0x7F) { $hasNonAscii = $true; break } }
            if ($hasNonAscii -and -not $hasBom) { $risky += $file.FullName }
        }
    }
    $facts.scanPath = $ScanPath
    $facts.scanScriptCount = $scriptCount
    $facts.scanRiskyCount = $risky.Count
    $facts.scanRiskyFiles = @($risky)
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($Json) {
    $facts | ConvertTo-Json -Depth 6
    return
}

Write-Output '=== Host profile (measured, not assumed) ==='
Write-Output ''
Write-Output 'Shell identity'
Write-Output ('  machine                    : {0}' -f $facts.machineName)
Write-Output ('  collected at               : {0}' -f $facts.collectedAt)
Write-Output ('  current shell              : {0}' -f $facts.currentShell)
Write-Output ('  Windows PowerShell 5.1     : {0}' -f $facts.windowsPowerShell51)
Write-Output ('  ACP / OEMCP                : {0} / {1}' -f $facts.acp, $facts.oemcp)
Write-Output ('  [Console]::OutputEncoding  : {0}' -f $facts.consoleOutputEncoding)
Write-Output ('  [Console]::InputEncoding   : {0}' -f $facts.consoleInputEncoding)
Write-Output ''
Write-Output 'Native command capture'
Write-Output ('  command                    : {0}' -f $capture.command)
Write-Output ('  exit code                  : {0}' -f $capture.exitCode)
Write-Output ('  bytes captured             : {0}' -f $capture.byteCount)
Write-Output ('  encoding verdict           : {0}' -f $capture.verdict)
Write-Output ('  evidence                   : {0}' -f $capture.evidence)
Write-Output ('  length self-check          : {0}' -f $capture.lengthCheck)
Write-Output ('  first bytes                : {0}' -f $capture.firstBytesHex)
Write-Output ''
Write-Output 'How 5.1 reads a .ps1 file'
Write-Output ('  expected code points       : {0}' -f $scriptReading.expected)
Write-Output ('  no-BOM probe               : {0}' -f $scriptReading.noBom)
Write-Output ('  with-BOM probe (control)   : {0}' -f $scriptReading.withBom)
Write-Output ('  verdict                    : {0}' -f $scriptReading.verdict)
Write-Output ''
Write-Output 'Path hazards'
Write-Output ('  user profile               : {0}' -f $pathHazards.userProfile)
Write-Output ('  profile is ASCII only      : {0}' -f $pathHazards.profileIsAscii)
Write-Output ('  TEMP is ASCII only         : {0}' -f $pathHazards.tempIsAscii)
Write-Output ('  note                       : {0}' -f $pathHazards.note)
if ($ScanPath) {
    Write-Output ''
    Write-Output ('Scan of {0}' -f $ScanPath)
    Write-Output ('  PowerShell files examined      : {0}' -f $facts.scanScriptCount)
    Write-Output ('  non-ASCII scripts without BOM : {0}' -f $facts.scanRiskyCount)
    foreach ($f in $facts.scanRiskyFiles) { Write-Output ('    {0}' -f $f) }
}
Write-Output ''
Write-Output 'Next step: copy the facts you just observed into the "Host profile"'
Write-Output 'section of SKILL.md and change its marker from [UNVERIFIED] to [VERIFIED].'
Write-Output 'Update the facts, the machine name and the marker together, or not at all.'
