# Windows 11长期无法更新：从下载错误到最终成功

这次排查涉及三段不同的问题：下载依赖服务被禁用；下载恢复后，累积更新安装需要的组件文件无法取得；转用安装介质后，首次升级又因系统盘空间不足回滚。最终用户明确回报系统已更新成功。

本文是连贯复盘。详细可复制命令见[命令流程](docs/command-playbook.md)，小问题见[FAQ](docs/faq.md)。未采集更新后构建号，因此成功依据明确限定为用户确认。

## 最终结果

| 检查项 | 状态 | 证据/限制 |
|---|---|---|
| Windows Update下载 | 恢复 | DoSvc运行后用户确认下载开始 |
| 系统最终更新 | 成功（用户确认） | 没有另外采集升级后版本记录 |
| KB5043145单独安装 | 未知 | 不以系统升级成功推定该旧KB成功 |
| 全部更新服务ACL/策略/任务 | 未核验恢复默认 | 此前只定向处理DoSvc |
| WPS数据清理 | 最终情况未确认 | 上次校验因文件占用停止，未继续删除源目录 |

## 1. 下载错误：先找到外层错误之前的线索

首次诊断环境为Windows 11家庭中文版22H2，构建22621.1778。用户称从2024年起长期更新失败，但现存日志不足以证明每次失败均由同一原因造成。

界面报0x80004002，而同一下载调用的日志为：

```text
DownloadManager *FAILED* [80070422] Connect to the DO service
DownloadManager Exit Code: 0x80246008, Extended Code: 0x80070422
DownloadManager *FAILED* [80004002] Method failed [CAgentDownloadManager::DownloadUpdate]
```

这里更直接的线索是DO服务连接失败与80070422。检查发现DoSvc的Start=4（禁用），WubLock=1；服务注册表键的SYSTEM、Administrators等规则仅允许读取。WaaSMedicSvc也有类似锁定配置。配置与日志相互印证，支持DoSvc禁用是本次下载阻断点。

WubLock及只读权限与更新屏蔽工具/脚本相符，但不足以证明具体工具或操作者。DLL签名有效也不等于所有更新组件都完整。

### 实际操作与结果

先导出相关服务注册表值并保存ACL和所有者。普通命令返回错误5“拒绝访问”：

```powershell
sc.exe config DoSvc start= delayed-auto
```

后续在管理员子PowerShell中启用接管所有权与恢复特权，暂时接管DoSvc根键，给SYSTEM与Administrators添加仅该根键的FullControl，再恢复原所有者。没有递归改整个Services目录，也没有证明此ACL为系统默认值。

权限处理成功后执行：

```powershell
reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc' /v Start /t REG_DWORD /d 2 /f
reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc' /v Start
```

输出成功且Start=0x2。保存工作、正常重启后：

```powershell
sc.exe qc DoSvc
sc.exe query DoSvc
```

本机显示延迟自动启动、RUNNING和退出代码0，之后下载恢复。延迟启动是本机已有配置保留后的观察，不是写Start=2在任何机器上的必然结果。

历史权限脚本全文未留存。项目附有[实验性重写示例](scripts/Restore-DoSvcAccess.ps1)，默认只读，并包含条件检查、备份与回退入口。它不是历史原文；目前仅作语法和静态检查，尚未在隔离环境验证修改、异常恢复与回退，不能将原案例的成功结果当成对它的验证。调用说明见命令流程第3节。

## 2. 安装失败：修复工具成功不等于目标KB成功

下载完成后，KB5043145安装先报0x800F0982，后来重试报0x800F0991。前者缺乏同等程度的日志上下文；不能把两个代码强行归为同一个根因。

后者CBS记录明确指向Microsoft-Windows-WMPNSS-Service.Resources的zh-CN资源wmpnetwk.mfl，所需版本22621.2506；文件无法取得，尝试从22621.608基线恢复失败，报PSFX_E_MISSING_PAYLOAD_FILE。这个证据定位安装阻断点，但不证明最初是下载包损坏、手动删除还是其他原因。

CheckHealth报告组件存储可修复。随后逐条运行：

```powershell
DISM.exe /Online /Cleanup-Image /RestoreHealth
sfc.exe /scannow
```

DISM进度曾停留3.8%，后来100%成功；SFC报告发现并修复损坏文件。重启后该KB仍然失败，因此转向匹配语言、版本的官方安装介质，保留个人文件和应用进行升级。

## 3. 首次就地升级：日志证实空间不足

安装介质为Windows 11家庭中文版，与本机版本类型相符。ISO保存在D盘，挂载后的F或G是虚拟DVD盘符，不是系统安装目标。

首次升级回滚显示0x80070070 - 0x2000A，SAFE_OS / PREPARE_FIRST_BOOT。setupact.log给出：

| 项目 | 字节 | GiB（约） |
|---|---:|---:|
| 后续操作估算需求 | 13,976,164,622 | 13.02 |
| 当时可用空间 | 10,816,671,744 | 10.07 |
| 缺口 | 3,159,492,878 | 2.94 |

它直接支持空间不足是此次失败阻断点。不能把13.02 GiB解读为整个升级总需求或所有电脑的最低余量；其他Error也需按调用链判断，不能一概认定是根因或无害。

## 4. 腾出空间并重试

磁盘清理工具只能释放几十MB，于是统计占用。用户明确选择保留应用、清理不需要的指定用户数据。数据先复制到D盘，逐文件哈希验证成功后才删C盘副本。

- Cursor用户数据约4.43 GiB：最初在Windows PowerShell中，深层长路径让Get-FileHash/Resolve-Path报错；切换PowerShell 7后校验通过，才清理源目录。
- 剪映User Data约2.25 GiB：复制、校验通过后清理。
- WPS数据约2.89 GiB：cache.db被wps.exe占用，校验中断；当时停止删除。其最终清理情况未确认。

这些数据量不足以完整解释最后40.6 GiB的全部增量，不能推断只靠三项清理获得所有空间。D盘也未被证明是独立物理磁盘，复制过去有助于腾空间，但不等同于独立灾备。

重试时用户报告系统盘有40.6“GB”可用（按/1GB换算，严格为GiB）。安装程序在获取更新处停留，用户取消并等待清理完成；重新打开后选“不是现在”获取更新。这个操作发生在空间释放后的再次安装阶段，只跳过在线动态更新检查。

最后确认页显示“Windows 11家庭中文版”与“保留个人文件和应用”，继续安装后，用户明确确认更新成功。

## 5. 给读者的复用方法

先按症状选择日志和操作：下载失败看服务与Windows Update日志；安装失败看CBS；升级回滚看Panther/回滚日志和空间估算。不要把整个过程做成一键执行脚本。

公开的[命令流程](docs/command-playbook.md)已处理路径选择、无0x前缀的错误码匹配、ISO挂载有效性，并为各阶段提供预期结果和失败处理。Word/WPS、长路径、进度停留等见[FAQ](docs/faq.md)。

本案最有价值的经验是用每一阶段的新证据决定下一步，并保留修改前配置与数据。系统更新成功是最终用户确认的结果；后续构建号、更新历史与全部服务默认配置仍需各自验证，不应由一个成功回报代替。
