# powershell-usage-guidelines

让 agent 用 Windows PowerShell 时不踩编码坑的 skill。

它**不给你答案**。编码、代码页、`.ps1` 怎么被读、路径里的非 ASCII——答案都取决于机器。
所以这里只有"该去哪里看"和两个探针脚本，具体事实由 agent 在这台机器上实测后写进
`SKILL.md` 的 Host profile 段。

## 怎么用

把整个目录放进 agent 的 skills 目录：

```powershell
Copy-Item -Recurse .\powershell-usage-guidelines "$env:USERPROFILE\.dsh\skills\"
```

然后量这台机器，把结果填进 `SKILL.md` 的 Host profile，标记改成 `[VERIFIED]`：

```powershell
.\scripts\Get-HostProfile.ps1                                    # 量这台机器
.\scripts\Get-HostProfile.ps1 -ProbeCommand 'docker version'     # 换个原生命令来探
.\scripts\Get-HostProfile.ps1 -Json -ScanPath 'C:\path\to\project'  # 机器可读 + 扫项目隐患
```

平时抓原生命令输出用另一个脚本，它把 stdout/stderr 当**原始字节**读出来再按你指定的编码解码，
而不是让 PowerShell 替你猜：

```powershell
$r = .\scripts\Invoke-NativeCommand.ps1 wsl.exe @('--help')
$r.EncodingUsed     # 先看这个，再决定信不信 $r.StdOut

(.\scripts\Invoke-NativeCommand.ps1 docker @('version') -Encoding Utf8).StdOut
```

超时会如实报成 `TimedOut`，"没跑起来"不会被伪装成"跑得慢"。

## 两个脚本

| 脚本 | 作用 |
| --- | --- |
| `scripts/Get-HostProfile.ps1` | 量 shell 版本、代码页、抓原生输出的编码、本机怎么读 `.ps1`、路径有没有非 ASCII 隐患；可选扫一遍项目。 |
| `scripts/Invoke-NativeCommand.ps1` | 按指定编码正确解码任意原生命令的输出，原始字节直读，双流排空不死锁。 |

两个都是 **Windows PowerShell 5.1 兼容**的——故意如此，因为编码陷阱恰恰都在老 shell 上；也正因如此它们源码纯 ASCII。

## 贡献

- **不要**把你本机的实测结果当通用结论写进正文。加"失败类别"和"该去哪里看"可以，写"这里一定是 UTF-16LE"不行。
- 某条指导在你的机器上不成立，写进 Host profile 的 "Local deviations"，不要去改正文把它改成只在你这儿成立的说法。
- 探针的改动必须保留对照组。没有对照组的探针，迟早会静默地给出错误答案。

## 交流

QQ 群：**259109974**

## License

MIT © [XianYuLSya](https://github.com/XianYuLSya)
