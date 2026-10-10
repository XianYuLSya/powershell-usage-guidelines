# powershell-usage-guidelines

> 一份**不给你答案**的 PowerShell 使用规范 skill。
>
> 它只教一件事：**别假设，去实测，然后把测到的东西记下来。**
>
> 所以这个仓库一开始几乎是空的——不是没写完，是设计如此。

---

## 为什么会有这个东西

Windows 上的 PowerShell 有一类 bug，特征是**失败得很安静**：

- 抓原生命令的输出，中文变成乱码，或者英文字母之间被塞进空格
- 你自己的 `.ps1` 明明读起来没问题，一跑就报语法错误，还报在离真正原因很远的地方
- 一个工具报错说证书/网络有问题，你查了半天网络，其实是**路径里有中文**
- 子进程根本没启动，调用方却等了整整一个超时，最后告诉你"太慢了"

这些都是真实踩过的坑。它们的共同点是：**网上的"标准答案"在你的机器上可能正好是错的**，因为答案取决于代码页、PowerShell 版本、路径、以及调用方所处的进程环境。

一份把这些坑写死的文档，迟早会变成一份看起来很权威的错误信息。所以这里反着来。

## 设计原则

| 原则 | 含义 |
| --- | --- |
| **不给固定方法** | 文档里只有"该去哪里看"，没有"答案是什么"。任何具体事实都属于某一台机器。 |
| **必须有对照组** | 探针自带一个必然正确的对照组。如果对照组都错了，说明探针坏了，结论必须被丢弃——而不是被相信。 |
| **打印证据，不打印结论** | 退出码、字节数、前 16 个字节。这些很便宜，而且能终结争论。 |
| **脚本源码只用 ASCII** | 从根上免疫一整类编码问题。人类语言只写在 `.md` 和数据文件里。 |
| **环境标记** | `[UNVERIFIED]` 表示这台机器还没人量过。看到它就该先侦察，而不是先写代码。 |

## 环境标记机制

`SKILL.md` 的 "Host profile" 段落带一个标记：

| 标记 | 含义 | 该做什么 |
| --- | --- | --- |
| `[UNVERIFIED]` | 这台机器没量过，或者里面记的是另一台机器的数据 | 跑探针 → 把实测结果落进去 → 改成 `[VERIFIED]` |
| `[VERIFIED]` | 数据是在段落里写的那台机器上量的 | 核对机器名是否仍是当前主机。对不上就是过期数据，按 `[UNVERIFIED]` 处理 |

**看到 `[UNVERIFIED]` 就是新环境。** 更新这一段是三件事一起做：事实、机器名、标记；要么全改，要么都不改。

## 怎么用

把整个目录放进你的 agent 的 skills 目录即可。例如：

```powershell
# Claude Code / DSH / 兼容 SKILL.md 的 agent，以 DSH 为例
Copy-Item -Recurse .\powershell-usage-guidelines "$env:USERPROFILE\.dsh\skills\"
```

然后：

```powershell
# 量这台机器
.\scripts\Get-HostProfile.ps1

# 关心某个具体原生命令时
.\scripts\Get-HostProfile.ps1 -ProbeCommand 'docker version'

# 机器可读 + 顺带扫一遍项目里的隐患脚本
.\scripts\Get-HostProfile.ps1 -Json -ScanPath 'C:\path\to\project'
```

把输出里的实测值填进 `SKILL.md` 的 Host profile，标记改成 `[VERIFIED]`。

### 平时怎么跑原生命令

`scripts/Invoke-NativeCommand.ps1` 会把子进程的 stdout/stderr 当**原始字节**读出来，再用你指定的编码解码——而不是让 PowerShell 替你猜：

```powershell
# 让它自己判断，并且把判断依据报回来
$r = .\scripts\Invoke-NativeCommand.ps1 wsl.exe @('--help')
$r.EncodingUsed     # 先看这个，再决定信不信 $r.StdOut

# 你已经知道编码时，直接指定
(.\scripts\Invoke-NativeCommand.ps1 docker @('version') -Encoding Utf8).StdOut
```

超时会如实报成 `TimedOut`，"没跑起来"不会被伪装成"跑得慢"。

## 两个脚本

| 脚本 | 作用 |
| --- | --- |
| `scripts/Get-HostProfile.ps1` | 侦察。量 shell 版本、代码页、原生命令抓取的编码、本机怎么读 `.ps1`、路径有没有非 ASCII 隐患，可选扫一遍项目。 |
| `scripts/Invoke-NativeCommand.ps1` | 按指定编码正确解码任意原生命令的输出，原始字节直读，双流异步排空不死锁。 |

两个都是**Windows PowerShell 5.1 兼容**的——故意如此，因为编码陷阱恰恰都在老 shell 上。也正因如此，它们的源码是纯 ASCII。

## 贡献

欢迎提 PR，但请遵守这个仓库的规矩：

- **不要**把你本机的实测结果当成通用结论写进正文。加"失败类别"和"该去哪里看"可以；写"这里一定是 UTF-16LE"不行。
- 如果你发现某个指导在你的机器上是错的，**在 Host profile 的 "Local deviations" 里说明**，不要去改正文把它改成只在你这儿成立的说法。
- 探针的改动必须保留对照组。没有对照组的探针，迟早会静默地给出错误答案。

## 交流

QQ 群：**259109974**

## License

MIT © [XianYuLSya](https://github.com/XianYuLSya)

---

## English summary

A skill that deliberately ships **without answers**.

Windows PowerShell has a class of failures that are quiet and expensive:
captured native output decoded with the wrong encoding, a `.ps1` file that
parses differently than it reads because of how the host decodes a file with no
byte-order mark, bundled TLS libraries that break on non-ASCII paths and report
it as a certificate error, and child processes that never start while the caller
waits out a timeout and calls it slowness.

Every one of those depends on the specific machine. A document that hardcodes
the answers turns into confident misinformation the moment it travels. So this
project ships the *discipline* and the *instruments* instead: measure first, keep
a control group so a broken probe is detectable, print evidence rather than
conclusions, and keep script sources ASCII-only.

`SKILL.md` carries an environment marker. `[UNVERIFIED]` means nobody has
measured this host yet - run `scripts/Get-HostProfile.ps1`, write the observed
facts into the Host profile section, and change the marker to `[VERIFIED]`.

`scripts/Get-HostProfile.ps1` performs the reconnaissance.
`scripts/Invoke-NativeCommand.ps1` runs a native command and decodes its raw
bytes with an encoding you chose deliberately, reporting which one it used.

MIT licensed. The skill body is in English; the README above is in Chinese
because that is where this project's community lives.
