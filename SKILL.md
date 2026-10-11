---
name: powershell-usage-guidelines
description: Use when PowerShell on Windows is the shell and you are about to trust an assumption about it - how a .ps1 file is read, how captured native output is encoded, how argv carries non-ASCII text, or why captured Chinese/Japanese turns into mojibake. Also use on an unfamiliar Windows host.
---

# PowerShell usage guidelines

Drive PowerShell without encoding surprises.

PowerShell facts are per-machine: code page, shell version, path, and the
calling process all matter. The **Host profile** below holds the facts measured
on one machine. If its marker is `[UNVERIFIED]`, or the machine name is not the
current host, run `scripts/Get-HostProfile.ps1` first and record the result
there. Do not write code on an unmeasured host.

## Traps: symptom -> what to check

**Captured native output is garbled.** Chinese/Japanese becomes `?`, or English
gains a space or NUL between every letter.
A native command writing UTF-16LE to a **redirected** handle is normal on
Windows - check the file's first bytes for `00`. Decode with the encoding you
proved; do not reach for a global `chcp 65001`.

**Your `.ps1` parses differently than it reads.** A syntax error about an
unterminated string, reported far from the real cause.
Look at the **file's own encoding**. Windows PowerShell 5.1 can read a `.ps1`
with no BOM as ANSI in the system code page, and a misread byte can swallow the
closing quote of a string literal. Keep script sources ASCII-only; if non-ASCII
is unavoidable, save UTF-8 **with BOM**, and re-check the first bytes after
every edit, because editors and programmatic rewrites silently strip BOMs.

**A TLS or network error that is neither.** Certificate or trust-anchor
messages.
Check whether the **path** contains non-ASCII. Bundled `libcurl` and similar C
libraries fail on such paths and blame certificates instead. Test the same input
from `C:\`: if it works, the path was the bug. `%USERPROFILE%` and `%TEMP%` are
frequently non-ASCII on Windows.

**A child process never starts, or "times out" with no output.**
Suspect the **calling context**, not the child. Launch paths that use a Job
Object, or that create the process suspended, misbehave when the caller is
itself inside a Job Object - as under job runners, task schedulers, and CI or
automation sandboxes. The child never runs and the caller waits out its entire
timeout. Test the identical call in-process; if it works there, the launcher is
the problem. Never let a launch failure be reported as a latency number.

**A cmdlet parameter silently does nothing.**
Check the filter against the path parameter beside it. `-Include` needs a
wildcard in `-Path`; paired with `-LiteralPath` it is dropped, with no error and
no warning. Measured on a real repository: 6916 rows returned where 47 were
scripts. Defence: **count what came back** and compare with an independent
count.

**Console and redirected output disagree.**
`$OutputEncoding`, `[Console]::OutputEncoding` and `[Console]::InputEncoding`
govern three different hops. Setting one and observing no change is expected.
Change one thing, re-measure.

## Rules

1. ASCII-only script sources. Removes a whole failure class for free.
2. Never build a native command line by string concatenation when arguments may
   hold non-ASCII or quotes: Windows PowerShell 5.1 has no argument-list API on
   `ProcessStartInfo`, and non-ASCII routed through `argv` can corrupt. Pass
   such payloads through the environment or a file.
3. Decode captured bytes explicitly, and report which encoding you used.
4. Print evidence - exit codes, byte counts, first bytes - not conclusions.
5. If a probe can be wrong, ship a control that proves the probe works.

## Scripts

```powershell
.\scripts\Get-HostProfile.ps1                                   # measure this host
.\scripts\Get-HostProfile.ps1 -ProbeCommand 'docker version'    # probe another command
.\scripts\Get-HostProfile.ps1 -Json -ScanPath 'C:\path\to\proj' # machine-readable + audit a tree
```

`scripts/Invoke-NativeCommand.ps1` reads a child's stdout/stderr as raw bytes,
decodes with an encoding you choose, reports `EncodingUsed`, and surfaces
timeouts as `TimedOut` rather than slowness. Both scripts are Windows
PowerShell 5.1 compatible and ASCII-only by design.


## Host profile

<!--
This section is filled in per machine by running scripts/Get-HostProfile.ps1.
Until then it stays deliberately empty. An empty section is honest; a section
full of another machine's numbers is not.
-->

**Marker:** `[UNVERIFIED]`

**Machine:** _(not measured)_

**Collected:** _(not measured)_

**Shell identity**

| Fact | Observed value |
| --- | --- |
| Current shell | _(not measured)_ |
| Windows PowerShell 5.1 present | _(not measured)_ |
| ACP / OEMCP | _(not measured)_ |
| `[Console]::OutputEncoding` | _(not measured)_ |
| `[Console]::InputEncoding` | _(not measured)_ |

**Native command capture**

| Fact | Observed value |
| --- | --- |
| Command probed | _(not measured)_ |
| Encoding of redirected output | _(not measured)_ |
| Evidence for that verdict | _(not measured)_ |
| Length self-check | _(not measured)_ |

**How this host reads a .ps1**

| Fact | Observed value |
| --- | --- |
| No-BOM script code points | _(not measured)_ |
| With-BOM script code points (control) | _(not measured)_ |
| Verdict | _(not measured)_ |

**Path hazards**

| Fact | Observed value |
| --- | --- |
| User profile path ASCII-only | _(not measured)_ |
| Notes | _(not measured)_ |

**Local deviations from this document**

_(Record anything this host does differently. If a guidance above turned out to
be wrong here, say so here rather than editing the guidance into a claim that
only holds on one machine.)_