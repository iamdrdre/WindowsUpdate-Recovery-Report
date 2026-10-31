# 按证据执行的命令流程

按症状选择分支，不要从头到尾盲目执行。修改操作在独立的管理员 PowerShell 中进行。本案例旧 KB5043145 仅供复盘，不是当前安装建议。

## 1. 记录环境

后续示例使用 `$recordRoot` 保存记录，路径由读者选择。变量只在当前窗口有效；如果关闭或新开终端，应重新指定这个已有目录。第3节给出了新窗口的衔接命令。

```powershell
$ErrorActionPreference = 'Stop'
$recordRoot = Read-Host '输入新的记录目录，例如 D:\UpdateEvidence-01'
if (Test-Path -LiteralPath $recordRoot) { throw '请选择不存在的新目录' }
New-Item -ItemType Directory -Path $recordRoot | Out-Null
DISM.exe /Online /Get-CurrentEdition |
    Tee-Object -FilePath (Join-Path $recordRoot 'edition-before.txt')
if ($LASTEXITCODE -ne 0) { throw '版本查询失败，停止并保留错误信息' }
DISM.exe /Online /Get-Intl |
    Tee-Object -FilePath (Join-Path $recordRoot 'language-before.txt')
if ($LASTEXITCODE -ne 0) { throw '语言查询失败，停止并保留错误信息' }
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
    Select-Object ProductName,DisplayVersion,CurrentBuild,UBR |
    Format-List | Tee-Object -FilePath (Join-Path $recordRoot 'version-before.txt')
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" |
    Select-Object @{n='C盘剩余GiB';e={[math]::Round($_.FreeSpace/1GB,2)}} |
    Format-List | Tee-Object -FilePath (Join-Path $recordRoot 'space-before.txt')
```

**预期：** 目录建立成功，终端显示语言、版本和剩余空间，同时保存四份修复前记录。**失败时：** 先处理路径/权限，不能继续依赖不存在的记录目录；查询报错时不要将该输出视为有效基线。历史输出的“40.6 GB”来自 `/1GB` 换算，严格单位是 GiB。

## 2. 确认下载错误是否来自 DoSvc

```powershell
sc.exe qc DoSvc
sc.exe query DoSvc
$doPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DoSvc'
Get-ItemProperty -LiteralPath $doPath | Select-Object Start,WubLock
Get-Acl -LiteralPath $doPath | Format-List Owner,AccessToString
$wuLog = Join-Path $recordRoot 'WindowsUpdate.log'
Get-WindowsUpdateLog -LogPath $wuLog
Select-String -LiteralPath $wuLog `
    -Pattern 'Connect to the DO service|(?:0x)?80070422|(?:0x)?80004002' `
    -Context 2,3 | Select-Object -Last 30 | ForEach-Object { $_.ToString() }
```

**本案预期：** Start=4、WubLock=1、SYSTEM 所有者、ACL 仅 ReadKey；同一时间段日志先报 DO 服务连接失败与80070422，随后80004002。搜索同时匹配 `[80004002]` 和 `0x80004002`。

**失败或不符时：** 保留转换日志的报错；无匹配不等于无故障。不要套用下面的权限示例。按需服务 STOPPED 本身不能证明异常。

## 3. DoSvc 拒绝访问：备份、定向恢复和验证

### 历史上实际执行的步骤

本案先导出了 DoSvc、WaaSMedicSvc、wuauserv 的注册表项，保存了 ACL 与所有者。随后以下命令返回错误5“拒绝访问”，直接写 Start 也被拒绝：

```powershell
sc.exe config DoSvc start= delayed-auto
```

之后在管理员子 PowerShell 中启用 `SeTakeOwnershipPrivilege`、`SeRestorePrivilege`，暂时接管 **DoSvc 根键**，给 SYSTEM 和 Administrators 添加**仅根键**的 FullControl，然后恢复原所有者。没有递归处理子键，也没有证明改后的 ACL 是 Windows 默认值。

权限处理成功后，实际执行的启动类型恢复命令是：

```powershell
reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc' /v Start /t REG_DWORD /d 2 /f
if ($LASTEXITCODE -ne 0) { throw '写入失败，停止' }
reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc' /v Start
```

**预期：** 成功，Start 为0x2。本机原有延迟启动设置被保留，重启后显示 AUTO_START (DELAYED)。仅写 Start=2 并不保证其他机器带有延迟启动设置。

### 实验性重写示例：尚未完成修改与回退验证

历史脚本全文没有留存在项目中。[Restore-DoSvcAccess.ps1](../scripts/Restore-DoSvcAccess.ps1) 是按相同思路重写的实验性示例。历史上下载恢复的结果不等于此脚本已经验证通过：目前只做了语法和静态检查，没有在隔离测试系统中验证修改、中途失败后的恢复及回退路径。

默认只读模式可用于查看配置。修改和回退示例收在下方折叠说明中，供审阅及隔离环境验证，不作为已验证的一键修复步骤。修改模式要求 Start=4、WubLock=1、SYSTEM 所有者、现有规则均为只读允许规则；不符即停止。

新开管理员 PowerShell 后，先进入项目目录，再重新指定步骤1创建的记录目录。这里应输入已有目录，不要重新执行步骤1的“新建目录”代码：

```powershell
$ErrorActionPreference = 'Stop'
$recordRoot = Read-Host '输入步骤1已经创建的记录目录完整路径'
if (-not (Test-Path -LiteralPath $recordRoot -PathType Container)) {
    throw '未找到记录目录，请检查路径'
}
# 在项目根目录查看现状，不修改
.\scripts\Restore-DoSvcAccess.ps1
```

<details>
<summary>实验环境中的修改预览、执行与回退示例（尚未验证）</summary>

以下命令依赖上面重新定义的 `$recordRoot`。`-WhatIf` 只预览；由于修改在此处被跳过，它不会验证后续特权启用、权限写入与回退是否可行。

```powershell
# 预览；不执行权限修改
.\scripts\Restore-DoSvcAccess.ps1 -Apply -BackupDirectory (Join-Path $recordRoot 'DoSvc-before') -WhatIf
# 下列为实际修改入口；须先完成审阅和隔离验证
.\scripts\Restore-DoSvcAccess.ps1 -Apply -BackupDirectory (Join-Path $recordRoot 'DoSvc-before')
```

**预期：** 新备份目录包含 `DoSvc.reg`、`DoSvc-acl.sddl`、`DoSvc-config.txt`；脚本报告 ACL 操作完成并恢复原所有者。然后运行上面的 Start 恢复命令。

**失败时：** 备份、条件检查、特权或 ACL 操作失败都应停止；保留报错，不删检查、不对整个 Services 授权。若执行策略阻止脚本，按本机管理策略处理，不全局关闭策略。

需要返回修改前配置时，先恢复值，再恢复 ACL。原备份可能重新禁用服务，因此这不是修复命令：

```powershell
reg.exe import (Join-Path $recordRoot 'DoSvc-before\DoSvc.reg')
if ($LASTEXITCODE -ne 0) { throw '值恢复失败，停止' }
.\scripts\Restore-DoSvcAccess.ps1 -Apply -RestoreAclFrom (Join-Path $recordRoot 'DoSvc-before\DoSvc-acl.sddl')
```

此回退覆盖示例涉及的值、根键权限与所有者，不是未来新增键值的完整快照还原。操作后关闭这个 PowerShell 窗口，释放进程启用的特权。

</details>

### 重启后检查

保存工作，正常重启，之后执行：

```powershell
sc.exe qc DoSvc
sc.exe query DoSvc
```

**本机结果：** AUTO_START (DELAYED)、RUNNING、退出代码0，更新实际开始下载。**仍失败时：** 查看重启后的新日志。WaaSMedicSvc、wuauserv、全部计划任务没有在本案中完成默认配置恢复核验。

## 4. CBS 与组件修复

```powershell
Select-String -LiteralPath "$env:windir\Logs\CBS\CBS.log" `
    -Pattern '(?:0x)?800f0982|(?:0x)?800f0991|PSFX_E_MISSING_PAYLOAD_FILE|Hydration failed|wmpnetwk.mfl' `
    -Context 2,3 | Select-Object -Last 40 | ForEach-Object { $_.ToString() }
DISM.exe /Online /Cleanup-Image /CheckHealth
```

**本案结果：** 先出现0x800F0982，之后0x800F0991；后者日志明确指出所需文件缺失和基线恢复失败。不能据此认定下载包损坏。CheckHealth 报告可修复后，先单独运行 DISM：

```powershell
DISM.exe /Online /Cleanup-Image /RestoreHealth
$restoreExit = $LASTEXITCODE
if ($restoreExit -eq 3010) { throw 'DISM要求重启；请先保存工作并正常重启，再继续检查' }
if ($restoreExit -ne 0) { throw "DISM失败，退出码：$restoreExit；先查看DISM/CBS日志" }
```

确认 DISM 最终摘要成功后，再单独运行 SFC。若 DISM 提示重启，先完成重启，再根据结果继续，不整段盲目粘贴：

```powershell
sfc.exe /scannow
```

**本案结果：** DISM成功、SFC修复损坏文件，重启后目标KB仍失败。**失败时：** 保存 DISM/CBS 错误码再处理。百分比暂时不动不代表挂死，不在处理过程中盲目杀进程。

## 5. ISO 就地升级

先备份重要文件、接通电源。40.6 GiB 是本案重试记录，不是所有电脑的最低要求；空间与兼容性仍需安装程序检查。

```powershell
$isoPath = Read-Host '输入微软官方 ISO 完整路径'
$isoFile = Get-Item -LiteralPath $isoPath -ErrorAction Stop
if ($isoFile.PSIsContainer -or $isoFile.Extension -ne '.iso') { throw '请选择 ISO 文件' }
$image = Get-DiskImage -ImagePath $isoFile.FullName -ErrorAction Stop
if (-not $image.Attached) {
    $image = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru -ErrorAction Stop
}
$letters = @($image | Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter)
if ($letters.Count -ne 1) { throw '未取得唯一有效盘符，请检查挂载结果' }
$setupPath = '{0}:\setup.exe' -f $letters[0]
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw '介质中未找到 setup.exe' }
Start-Process -FilePath $setupPath -ErrorAction Stop
```

**预期：** 安装向导打开。检查语言、版本、架构及最终“保留个人文件和应用”选项。**不符时：** 取消安装，不选删除文件继续。

本案再次安装时在获取更新处取消，等待清理完成后重开，点击“更改安装程序下载更新的方式”并选“不是现在”。它只跳过在线动态更新检查，不解决空间不足，也不能证明网络已经修复。

## 6. 回滚后按时间读取日志

```powershell
$setupLogs = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources'
$actLog = Join-Path $setupLogs 'Panther\setupact.log'
if (-not (Test-Path -LiteralPath $actLog)) { throw '日志不存在，可能已清理；不要用旧日志判断新尝试' }
Select-String -LiteralPath $actLog `
    -Pattern '(?:0x)?80070070|DISKSPACEQUERY|Not enough disk space|Disk space available|Disk space needed' `
    -Context 8,4 | Select-Object -Last 15 | ForEach-Object { $_.ToString() }
```

**本案结果：** 需求13.02 GiB、可用10.07 GiB，缺口2.94 GiB。**无匹配时：** 结合 Panther/回滚日志的时间和失败操作继续定位；不是每次回滚都来自空间不足。

## 7. 完成后核验

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
    Select-Object ProductName,DisplayVersion,CurrentBuild,UBR |
    Format-List | Out-File -LiteralPath (Join-Path $recordRoot 'version-after.txt')
Start-Process 'ms-settings:windowsupdate'
```

**预期：** 保存版本记录，并检查设置中的更新历史和待重启状态。重启后需先按第3节重新指定 `$recordRoot`；不要把新版本记录写到不明位置。**仍失败时：** 记录新的标题、时间、错误码，重新定位。原案例的最终成功来自用户确认，未采集此升级后构建号文件。
