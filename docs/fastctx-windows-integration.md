# FastCtx Windows 集成

本文件是 Codex Desktop 的 FastCtx 运行约定。它描述的是稳定的运行状态，不是
`fastctx apply` 的替代说明。

## 结构

FastCtx 是一个 Rust MCP 服务。Codex 启动的 `fastctx serve --enable-shell` 进程
通常只是 stdio 代理；同一用户、同一构建会复用一个本地 control center。每个 MCP
连接仍然保留自己的 cwd、环境变量和 session，因此后台任务、读写路径和控制中心
生命周期不能按“一次命令一个进程”处理。

公开的九个同级工具是：

`read`、`grep`、`glob`、`replace`、`run`、`run_background`、`job_output`、
`job_kill`、`job_list`。

`run` 使用 Git Bash；需要 Windows 专属 API 的命令应由 MCP 客户端降级到原生
PowerShell，不属于 FastCtx 源码或安装器职责。

## 内部链路

`fastctx serve` 不是每次工具调用都重新加载整个服务。它先作为薄 stdio 代理启动，
再连接或拉起按“原生用户目录哈希 + FastCtx build id”隔离的 control center：

1. 代理在消费 MCP stdin 前连接 control center，启动/握手上限都是 10 秒；
2. 同一用户、同一 build 的多个 Codex 会话共享搜索执行器和后台任务管理器；
3. 每条连接仍单独捕获 cwd、环境变量、shell 开关和取消信号，不能跨会话假定 cwd；
4. control center 默认空闲 10 分钟退出，升级二进制后的新 build id 会自然隔离旧实例；
5. stdio 使用一行一个 JSON-RPC 消息，不是 `Content-Length` 帧。

文件工具的关键实现边界：

- `read` 先建立单次打开的文件快照，再做 BOM/UTF-8/候选编码判定；批量请求上限
  32 项，同一路径的各项拥有独立 `offset`、`limit`、`encoding`；
- `grep`/`glob` 共享有界并行搜索执行器，默认尊重 ignore 文件、包含隐藏文件并排除
  `.git`，输出达到预算时返回可续读偏移；
- `replace` 先做匹配计数和并发修改检查，再以同编码、BOM、换行原子替换，默认单文件
  输入/输出安全上限为 256 MiB；语义修改仍使用 `apply_patch`；
- `run` 适合有界前台 Git Bash 命令；长任务必须用 `run_background`，日志和退出码写入
  用户级 job store，`job_kill` 终止整棵进程树；
- 默认 job store 上限 1024 MiB、同时运行任务上限 128、`job_list` 默认页长 20。这些是
  上游 0.2.4 默认值，不应由 `fastctx apply` 在本 Codex profile 中擅自改写。

Git Bash 能启动普通 Windows `.exe`，但某些 Store CLI shim 会解析到无扩展 PE 路径并
报 `Exec format error`。这属于明确的 Windows-only 边界：先保留 FastCtx 的失败证据，
再用 PowerShell 执行 Appx、Codex Store CLI 或注册表命令，不要无意义地重复同一 Bash
命令。

## 固定路径

Windows 的 Git Bash 可能把 `HOME` 指向 Git 安装目录。Codex MCP 环境必须固定：

```toml
HOME = "C:/Users/<user>"
USERPROFILE = "C:/Users/<user>"
CODEX_HOME = "C:/Users/<user>/.codex"
FASTCTX_BASH = "C:/Program Files/Git/bin/bash.exe"
```

FastCtx 本地状态保存在 `C:/Users/<user>/.fastctx`：

- `config.toml`：用户设置；
- `bin/fastctx.exe`：稳定的用户级二进制入口；
- `jobs/`：后台任务的状态、完整输出和退出码；
- PDF/plugin 等运行时缓存：只在对应功能需要时保留。

不要把 MCP command 指向 Git 安装目录下的旧 `bin/fastctx.exe`，也不要把
`CODEX_HOME` 指向 `.codex-cli` 或 Git 安装目录。

## 安装与配置

Windows x64 新电脑克隆本仓库后直接运行：

```powershell
git clone https://github.com/Fooljack/Fast-CTX.git
cd Fast-CTX
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install-fastctx-windows.ps1"
```

仓库附带校验过的 Windows x64 二进制。安装器先按 `checksums/SHA256SUMS` 验证它，
再复制到用户级稳定路径，备份现有 Codex 配置，并且只更新
`[mcp_servers.fastctx]` 与 `[mcp_servers.fastctx.env]`。希望从源码编译时执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install-fastctx-windows.ps1" -BuildFromSource
```

源码构建需要 Rust 1.88 或更高版本，使用系统临时目录作为 Cargo target，结束后自动
删除。也可以把另一个已验证二进制显式传给安装器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install-fastctx-windows.ps1" `
  -FastCtxBinary "<verified-fastctx.exe>"
```

安装器和配置脚本都不会执行 `fastctx apply` 或 `fastctx unapply`。配置完成后重启 Codex
Desktop，使 MCP 进程重新读取 `config.toml`。

## 验证

先执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install-fastctx-windows.ps1" -VerifyOnly
```

`configure-fastctx.ps1` 负责只读状态、TOML 和 `initialize/tools/list` 检查；
`verify-fastctx-mcp.ps1` 会在一次性临时用户目录中真实调用九个工具。验证重点是：

- `tools/list` 返回九个同级工具；
- `read.files` 可以让同一路径出现两次，并分别带不同的 `offset`/`limit`；
- `run` 能执行 `printf`，且工作目录与请求一致；
- `run_background`、`job_output`、`job_kill`、`job_list` 能处理同一用户的任务；
- `replace` 只修改一次性临时测试文件；
- smoke 产生的 job、控制中心和测试目录全部回收；
- 正式 MCP 的 `~/.fastctx/jobs` 和控制中心路径落在原生用户目录，而不是 Git 安装目录。

`configure-fastctx.ps1 -VerifyOnly` 对已配置文件是只读的：不会创建缺失的
Codex/FastCtx 根目录、写入 `config.toml`、复制二进制或创建备份。握手会启动
真实 MCP 服务，因此可能触碰 FastCtx 正常的 control-center/runtime 状态；该状态
属于稳定运行所需的持久状态。

验证失败时，匹配的 FastCtx 工具重试一次；只有 FastCtx 不可用、仍失败，或命令
需要 Windows 专属 API 时，才降级到 PowerShell。不要因为 Git Bash 命令返回非零就
直接切换；非零结果本身应先作为诊断输出读取。

## 本地修改

当前验证过的 FastCtx 上游是：

```text
https://github.com/yc-duan/fastctx
86dac0c99efae7859ed2be468f68c16e58f5e16a
```

`docs/fastctx-local-hardening.patch` 保留了 Windows 用户目录选择和批量重复
路径读取的完整源码差异。升级 FastCtx 时先确认上游 commit，再应用 patch、运行完整
测试并重新计算二进制 SHA-256。patch 不能静默失败。

已处理的边界包括：

- Windows 同时存在 Git Bash `HOME` 和原生 `USERPROFILE` 时优先原生用户目录；
- 同一批量 read 请求中同一路径的每个条目独立解析范围和编码；
- unelevated Windows 创建符号链接返回 `PermissionDenied` 或 OS error `1314`
  时将其识别为环境能力缺失，而不是把测试误报为产品故障；
- 安装器通过 SHA-256 校验仓库二进制，并在复制后再次校验稳定入口；
- 自定义目录安装的 Git for Windows 可通过 PATH、注册表、标准用户目录或 `-GitBash`
  显式路径发现；
- 配置回归会验证备份、幂等性，以及与 FastCtx 无关的 Codex TOML 内容保持不变。

## 清理边界

每次构建或验证产生的临时 clone、Cargo target、staging、npm cache、测试文件和日志
都必须在脚本的 `finally` 路径中删除。安装器和回归测试只删除自己在系统临时目录下
创建的 GUID 子目录；完整测试结束后这些临时根目录必须为空。

以下内容不能按普通临时文件删除：

- `~/.fastctx/jobs`：`job_output`、跨会话恢复和进程树管理依赖它；
- `~/.fastctx/config.toml`：FastCtx 用户设置；
- `~/.codex/backups/config` 和明确标记的 legacy backup：用于回滚；
- FastCtx 按需提取的 PDF engine 等运行时缓存。

清理的目标是删除错误的旧命令、孤立 receipt、过期报告和本轮产物，不是删除 FastCtx
正常运行所需的状态。任何递归删除都必须先验证绝对路径在脚本声明的临时根目录内。
