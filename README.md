# Windows 11 更新故障排查与修复记录：最终更新成功

一份来自真实故障排查过程的经验记录：Windows 11 22H2 长期无法更新，先后出现下载错误 `0x80004002`、累积更新安装错误 `0x800F0991`，以及安装介质修复升级因空间不足回滚。

> 这是个案复盘，不是适用于所有电脑的一键修复脚本。操作系统版本、语言、磁盘空间和日志证据都会影响结果。执行前先备份重要文件；涉及注册表权限、服务 ACL、系统升级的步骤应逐项核对。

## 结果摘要

- **下载失败的直接原因已由日志确认：** Delivery Optimization 服务 `DoSvc` 被禁用。日志先报 `0x80070422`，随后 Windows Update 外层报 `0x80004002`。
- 检查还发现 `DoSvc` 和 `WaaSMedicSvc` 的服务注册表键被设置为只读，并带有 `WubLock=1`。这与更新屏蔽工具/脚本的设置相符，但无法证明具体工具或操作者。
- 恢复 `DoSvc` 后，服务能正常运行，更新下载恢复；但旧的 KB5043145 仍因组件有效负载缺失而安装失败（`0x800F0991`）。
- DISM `/RestoreHealth` 与 SFC 后续报告修复成功，但 KB 安装仍失败。安装介质升级随后因 C 盘空间不足而回滚（`0x80070070 - 0x2000A`）。
- 用户在释放空间至40.6 GB后重新安装，确认“保留个人文件和应用”。最终用户回报系统已更新成功；尚未采集更新后的构建号，不能据此认定旧 KB5043145 单独安装成功。

| 检查项 | 最终状态 | 依据 |
|---|---|---|
| 更新下载 | 已恢复 | DoSvc运行，用户确认开始下载 |
| 系统最终更新 | 成功（用户确认） | 用户最终回报 |
| 旧 KB5043145 单独安装 | 未知 | 没有成功历史记录 |
| 更新后的具体构建号 | 未采集 | 没有升级后版本记录 |
| 全部服务权限、策略、任务恢复默认 | 未核验 | 仅定向处理DoSvc，不能推广 |
| WPS数据清理 | 最终状态未确认 | 上次校验因占用停止 |

## 阅读顺序

希望一次读完，可直接看[独立整理的完整报告](Windows更新修复完整报告.md)；下面各篇供按需查阅。

1. [经验分享贴：从下载错误到最终更新成功](docs/experience-post.md)
2. [故障经过与证据](docs/incident-report.md)
3. [可复用的命令与操作流程](docs/command-playbook.md)
4. [踩坑总结与安全边界](docs/lessons-learned.md)
5. [典型小问题与处理](docs/faq.md)
6. [DoSvc权限处理实验示例](scripts/Restore-DoSvcAccess.ps1)（默认只读；非历史脚本原文，修改与回退尚未经隔离环境验证）

## 关键经验

1. 错误码要看上下文：`0x80004002` 是外层错误；本案下载链里更有定位价值的是前一条 `0x80070422`。
2. 先读日志和服务状态，再动注册表、清缓存或重装系统。
3. 组件修复成功不代表某个更新一定能安装；后续仍需按新日志定位。
4. 就地升级前，不只看“当前剩余空间”，还要看安装日志的峰值需求。失败日志显示所需约 13.0 GiB、实际可用约 10.1 GiB。
5. 只在用户明确确认可删除、且备份和逐文件校验通过后，才清理应用用户数据。应用数据不等于普通文档，但也可能含设置、历史或草稿。

## 隐私说明

此复盘已省略账户邮箱、用户名、机器路径、设备标识、备份文件名等个人信息。发布前仍应检查截图、日志和提交记录，确认没有令牌、邮箱、设备名或本机路径。

## 建议的 GitHub 描述

Windows 11 更新故障个案复盘：从 `0x80004002`、被禁用的 Delivery Optimization 服务，到 `0x800F0991` 组件有效负载失败与就地升级空间不足。包含日志解读、PowerShell 检查命令和踩坑总结。

## 参考资料

- [微软：Windows Update 常见错误](https://learn.microsoft.com/en-us/troubleshoot/windows-client/installing-updates-features-roles/common-windows-update-errors)
- [微软：Windows Update 日志](https://learn.microsoft.com/en-us/windows/deployment/update/windows-update-logs)
- [微软：修复 Windows 映像](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image)
- [微软：下载 Windows 11](https://www.microsoft.com/zh-cn/software-download/windows11)
