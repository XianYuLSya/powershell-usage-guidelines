---
name: powershell-usage-guidelines
description: Guidelines for running PowerShell and native Windows commands reliably, especially when capturing their output into a file, a GUI, or another process. Use this skill whenever PowerShell is the shell on Windows and you are about to trust an assumption about it - text encoding, console code pages, how a .ps1 file is read, how argv carries non-ASCII text, how a redirected native command's bytes are laid out, or why captured Chinese/Japanese/accented text turns into mojibake. Also use it when a Windows host is new or unfamiliar and nobody has recorded what its shell actually does.
---

# PowerShell usage guidelines

## The only rule that always applies

**Do not assume. Measure, then record what you measured.**

Everything else in this document is a checklist of *where to look*, never a set
of answers. Any concrete fact belongs to one machine and one configuration, and
the moment you copy it somewhere else you have created a lie that looks like
knowledge.

Two consequences worth stating plainly:

- If you have not measured it on this host, say so. "I haven't verified the
  capture encoding here" is a useful sentence; a confident guess is not.
- When a measurement contradicts this document, the measurement wins. Fix the
  document.

## The environment marker

The "Host profile" section below carries a marker.

| Marker | Meaning | What to do |
| --- | --- | --- |
| `[UNVERIFIED]` | Nobody has measured this host, or the facts recorded there belong to a different machine. | Run the probe routine, then land the observed facts in the section and change the marker to `[VERIFIED]`. Do this **before** relying on PowerShell behaviour for real work. |
| `[VERIFIED]` | The facts were measured on the machine named in the section. | Check the machine name still matches the current host. If it does not, the facts are stale: treat this as `[UNVERIFIED]`. |

The marker is not decoration. Seeing `[UNVERIFIED]` means the environment is new
or unknown, and the correct first move is reconnaissance - not writing code.

Updating this section is a single atomic act: facts, machine name, and marker
change together, or none of them change.

## Probe routine

`scripts/Get-HostProfile.ps1` performs the reconnaissance. It assumes nothing
and prints evidence next to every verdict, including a self-check that tells you
when its own result should be ignored.

```powershell
# Full profile for this host
.\scripts\Get-HostProfile.ps1

# Inspect a specific native command instead of the default wsl.exe probe
.\scripts\Get-HostProfile.ps1 -ProbeCommand 'docker version'

# Machine-readable, and audit a tree for latent hazards
.\scripts\Get-HostProfile.ps1 -Json -ScanPath 'C:\path\to\project'
```

Run it with `-Verbose` if you want to watch the stages. It touches only `%TEMP%`
and cleans up after itself.

## Where to look when something is wrong

These are failure *classes*. Each has reproduced on a real machine at least
once, which is why it is listed - not because it applies to yours.

### Captured native output is garbled

Symptom: Chinese/Japanese/accented text becomes `?` or wrong characters; English
sometimes arrives with a space or a NUL between every letter.

Look at: whether the bytes came from a **redirected handle** rather than the
console. Programs commonly detect redirection and switch encodings, and on
Windows a native command writing UTF-16LE to a redirected handle is normal, not
a bug. Check the first bytes of the file - a UTF-16LE stream is full of `00`.

Fix by decoding the bytes with the encoding you *proved*, rather than by
changing a code page globally. `chcp 65001` is not a universal answer, and it
changes behaviour for every process that inherits the console afterwards.

### Your own .ps1 behaves differently than it reads

Symptom: a script containing non-ASCII text fails to parse, complains about
unexpected tokens or an unterminated string, or prints text nobody wrote.

Look at: **the encoding of the script file itself**, not the encoding of its
output. Windows PowerShell 5.1 may read a `.ps1` with no byte-order mark as
ANSI in the system code page, in which case multi-byte characters are
misinterpreted and a misread byte can even swallow the closing quote of a
string literal, producing a syntax error far from the real cause.

The safest habit, and the reason this project's scripts are ASCII-only: **keep
script source ASCII**. Put human-language text in files that are not parsed as
code (`README.md`, `SKILL.md`, data files). If a script must contain non-ASCII,
prove with the probe whether this host needs a BOM, and remember that many
editing tools silently strip BOMs - re-verify after every edit.

### A tool fails in a way that smells like network or TLS, but the network is fine

Look at: **whether the path it was handed contains non-ASCII characters**.
Bundled `libcurl` builds and similar C libraries can fail on non-ASCII paths
with messages that name certificates or trust anchors, sending you after the
wrong problem entirely. The test that separates the two: run the identical
input from an ASCII-only directory such as `C:\` and compare. If the ASCII path
works, the path is the bug and the network was never involved.

This matters more than it sounds, because on Windows the user profile directory
is frequently non-ASCII, and `%TEMP%` lives inside it.

### A child process never starts, or "times out" with no output

Look at: **the context you launched it from**, before you blame the child.
Process-creation primitives that assign the new process to a Windows Job Object,
or that create it suspended and then resume it, can behave differently when the
caller is itself running inside a Job Object - as it is under some job runners,
task schedulers, and CI or automation sandboxes. The failure mode is nasty:
the child never runs, the caller waits out its entire timeout, and a timeout
message makes it look like a slow operation rather than a broken launch.

The test: run the exact same call directly in your own process and compare. If
it works there, the launcher is the problem.

Do not let a harness report a launch failure as a latency number. When a probe
distinguishes "did not run" from "ran slowly", preserve that distinction.

### Console and redirected output disagree

`$OutputEncoding`, `[Console]::OutputEncoding` and `[Console]::InputEncoding`
are three different things governing three different hops. Setting one and
observing no change is expected, not mysterious. Change one thing at a time and
re-measure.

### A cmdlet parameter silently does nothing

Look at: **whether the parameter you passed is actually compatible with the path
parameter you passed alongside it**. Some filters are not honoured in every
combination, and the cmdlet reports no error and no warning - it simply returns
a different set than you asked for.

The case worth remembering: `-Include` needs a wildcard in `-Path`. Pair it with
`-LiteralPath` and the filter is dropped. Measured on one real repository:

```powershell
Get-ChildItem -LiteralPath X -Recurse -File -Include *.ps1,*.psm1   # 6916 files
Get-ChildItem -LiteralPath X -Recurse -File | Where-Object { ... }  #   47 files
```

6916 files, 6869 of which were not PowerShell scripts at all. Anything downstream
then reads every markdown file and binary blob in the tree and reports them as
findings, with no hint that the filter never ran.

The defence is not to memorise the quirk. It is to **count what came back and
compare it against an independent count**. A filter that returns more rows than
exist has already told you it did not run.
## Writing scripts that survive

1. Prefer ASCII-only script sources. It removes an entire failure class for
   free.
2. Never build a native command line by string concatenation when arguments may
   contain non-ASCII text or quotes. On Windows PowerShell 5.1 there is no
   argument-list API on `ProcessStartInfo`, and non-ASCII payloads routed through
   `argv` can corrupt. Pass such payloads through the environment or a file
   instead.
3. When you launch a native command to capture its output, decode the bytes
   explicitly, and report which encoding you used. A caller that has to guess is
   a caller that will guess wrong.
4. Print evidence, not conclusions. Exit codes, byte counts, and the first bytes
   of a capture are cheap to print and settle arguments.
5. When a probe can be wrong, ship a control that proves the probe itself works.
   A probe that cannot fail visibly will eventually fail invisibly.

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
