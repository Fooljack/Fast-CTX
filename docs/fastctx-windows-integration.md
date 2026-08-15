# FastCtx Windows 集成

本文件描述 Windows x64 上 Claude Code、Codex 与可选 CC Switch 的稳定用户级 FastCtx
链路，包括仓库链接引导安装、Release 安装、配置所有权、Agent 说明、验证和降级边界。
它不是 `fastctx apply` 或 `fastctx unapply` 的替代说明；一键安装器不会调用这两个命令。

## 运行结构

FastCtx 是 Rust MCP 服务。宿主启动的 `fastctx serve --enable-shell` 通常只是 stdio
代理；同一原生用户、同一构建会复用本地 control center。每条 MCP 连接仍单独保存
cwd、环境变量、shell 开关和取消信号，不能跨会话假定 cwd。

公开工具必须恰好是九个：

`read`、`grep`、`glob`、`replace`、`run`、`run_background`、`job_output`、
`job_kill`、`job_list`。

文件与命令边界保持不变：

- `read` 支持单文件和最多 32 项文本批量读取，每一项独立携带范围与编码；
- `grep`/`glob` 使用有界并行遍历，默认尊重 ignore 文件，结果按预算分页；
- `replace` 在写入前完成匹配计数与并发修改检查，以同目录原子替换保留编码、BOM、
  换行和未修改字节，并拒绝硬链接目标；
- `run` 使用 Git Bash 执行有界非交互命令；长任务使用 `run_background` 与持久 job
  store，`job_kill` 终止整棵进程树；
- `serve` 的 stdio 协议是一行一个 JSON-RPC 消息，不使用 `Content-Length` 帧。

## 只用仓库链接安装

当前仓库已经公开，智能体只需这个链接即可获取 raw bootstrap 和 Release 地址。如果使用私有
fork，目标电脑必须已经拥有读取权限（例如已配置 GitHub 登录凭据或组织访问）；安装器不会
收集凭据。

把 `https://github.com/Fooljack/Fast-CTX` 交给智能体即可。智能体应先将
`scripts/install-fastctx-from-github.ps1` 下载为本地文件，按宿主策略检查后执行，不要把
远程 PowerShell 直接传给 `Invoke-Expression`：

```powershell
$bootstrap = Join-Path $env:TEMP 'install-fastctx-from-github.ps1'
Invoke-WebRequest `
  'https://raw.githubusercontent.com/Fooljack/Fast-CTX/main/scripts/install-fastctx-from-github.ps1' `
  -OutFile $bootstrap
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap
```

该引导器只接受规范的 `owner/repository` 名，跟随 GitHub 的最新稳定 Release 下载重定向，
只从构造出的 GitHub HTTPS 地址获取精确命名的 Windows ZIP 与 Release 级 `SHA256SUMS`，
校验归档后才解压并调用包内安装器，不调用受限流影响的 GitHub API。`-Tag v0.3.0` 可固定版本。

## 从 Release 手动安装

从同一个 GitHub Release 下载：

- `fastctx-x86_64-pc-windows-msvc.zip`；
- Release 级 `SHA256SUMS`。

先验证归档：

```powershell
certutil -hashfile .\fastctx-x86_64-pc-windows-msvc.zip SHA256
Select-String 'fastctx-x86_64-pc-windows-msvc.zip' .\SHA256SUMS
```

解压后在该目录运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install-fastctx-windows.ps1
```

ZIP 是扁平自包含安装包，包含预编译 `fastctx.exe`、安装器、配置器、九工具 smoke、
说明模板、`INSTALL-WINDOWS.md`、许可文件和包内 `SHA256SUMS`。默认路径不需要
Node.js、Rust 或 Cargo；需要 Git for Windows。安装器会根据包内清单验证二进制，复制
后再次验证稳定入口。

Claude Code 默认必须可用，因为 MCP 注册通过其受支持的用户级 CLI 完成。如果明确
只安装 Codex 集成：

```powershell
.\install-fastctx-windows.ps1 -SkipClaudeCode
```

源码 checkout 仍可运行 `scripts/install-fastctx-windows.ps1`。安装器不会在找不到预编译
文件时静默编译；只有显式传 `-BuildFromSource` 才会要求 Rust 1.88 或更高版本，并将
Cargo target 放在系统临时目录。也可传 `-FastCtxBinary <verified-fastctx.exe>`。

## 稳定路径与标准预算

默认二进制和 FastCtx 状态位于原生 Windows 用户目录：

- `C:/Users/<user>/.fastctx/bin/fastctx.exe`；
- `C:/Users/<user>/.fastctx/config.toml`；
- `C:/Users/<user>/.fastctx/jobs/`。

两个宿主的 MCP 环境都使用：

```text
HOME=C:/Users/<user>
USERPROFILE=C:/Users/<user>
CODEX_HOME=C:/Users/<user>/.codex
FASTCTX_BASH=<Git for Windows>/bin/bash.exe
FASTCTX_TOKEN_BUDGET=54000
FASTCTX_GREP_TOKEN_BUDGET=10800
FASTCTX_GLOB_TOKEN_BUDGET=5400
FASTCTX_RUN_TOKEN_BUDGET=10800
FASTCTX_JOB_OUTPUT_TOKEN_BUDGET=5400
```

Git Bash 自己可能导出不同 `HOME`，不能因此把 FastCtx 用户状态或 Codex 配置写进 Git
安装目录。`CODEX_HOME` 环境变量和显式 `-CodexHome` 均应被尊重。

## Claude Code 配置

Claude Code 用户级 MCP 定义使用受支持的 CLI：

```console
claude mcp add --scope user --transport stdio ... fastctx -- <stable-fastctx.exe> serve --enable-shell
```

配置器先直接读取 Claude CLI 的有效用户级 `.claude.json`，检查 `mcpServers.fastctx`，
不会在冲突预检中启动该定义所指向的命令：

1. 不存在时通过受支持的 `claude mcp add` 添加；
2. 与稳定路径、参数和九项环境值完全一致时不操作；
3. 存在不同定义时停止，不静默覆盖或执行它；
4. 只有用户审查后显式传 `-ForceMcpRegistration`，才通过受支持的
   `claude mcp remove`/`add` 重建用户级同名定义。

全局说明目标为 `CLAUDE_CONFIG_DIR/CLAUDE.md`；未设置该环境变量时使用
`~/.claude/CLAUDE.md`。Claude MCP 用户状态不写入 `settings.json`，也不由安装器整体
覆盖 `.claude.json`。

## Codex 配置

Codex MCP 表位于 `$CODEX_HOME/config.toml`，默认是 `~/.codex/config.toml`。配置器在
首次修改前备份现有文件，只更新 `[mcp_servers.fastctx]` 与
`[mcp_servers.fastctx.env]`，保留其他表、键、注释和内容。FastCtx 自己拥有的五个预算
键写入上面的已验证标准值；不相关的用户配置不属于 FastCtx 管理范围。

Codex 的有效全局说明按其发现顺序选择：

1. 非空 `$CODEX_HOME/AGENTS.override.md`；
2. 否则 `$CODEX_HOME/AGENTS.md`。

这样不会把说明写入一个被 `AGENTS.override.md` 遮蔽、实际不生效的文件。

## CC Switch 配置

CC Switch 的 MCP 单一真源是 `~/.cc-switch/cc-switch.db` 中的全局 MCP 表；供应商快照会
主动剥离 MCP，切换供应商后再从该表投影。因此安装器不会向每个供应商配置复制一份
FastCtx，也不会直接改 SQLite。检测到注册的 `ccswitch://` 协议时，它使用官方深链导入
一项 `fastctx`，并同时启用 `claude,codex,gemini,grokbuild,opencode,hermes`。

CC Switch 必须显示导入确认；安装器不能也不会自动点击确认。建议使用 v3.19.0 或更高
版本，让确认框完整显示命令、参数和环境并对凭据形态值脱敏。用户应核对稳定二进制、
`serve --enable-shell` 和标准预算后点击 **Import**。已有同名条目时，CC Switch 会保留
原服务器定义，只合并新增应用开关，因此陈旧定义应先在 CC Switch 中检查或删除。

- `-SkipCcSwitch`：完全跳过 CC Switch；
- `-NoLaunchCcSwitch`：生成并验证载荷，但不打开外部应用；
- `-RequireCcSwitch`：没有注册协议时失败；
- `-VerifyOnly`：只报告协议是否注册，不读取或写入 CC Switch 数据库。

## 受管 Agent 说明

两个宿主使用同一个 `fastctx-agent-guidance.md` 模板。安装器只插入或替换以下标记之间
的内容：

```markdown
<!-- fastctx:begin -->
...
<!-- fastctx:end -->
```

标记外的 UTF-8 字节、BOM 与用户文本保持不变；写入前保存快照，提交时再次比较，
然后同目录原子替换。缺失、重复、倒置或不配对的标记会阻止安装，要求先人工修复，
不会猜测或删除用户内容。重复安装必须字节级幂等。

说明合同要求 Agent：

- 本地文件读取、内容搜索、路径搜索、机械替换、命令执行和后台任务优先使用对应
  FastCtx MCP 工具；
- 对同一个 FastCtx 支持的操作目标，只有连续三次合理尝试都失败后才可降级到原生
  PowerShell 或 Bash；
- 每次重试必须根据上次失败修正命令、路径、参数或策略，不能原样重复失败调用来凑满
  三次；
- 第三次修正尝试仍失败并降级时，简要说明 FastCtx 失败及原因；
- `apply_patch` 等宿主专用工具明确豁免，不强行通过 FastCtx shell 执行。

Git Bash 能运行普通 Windows `.exe`，但 Store CLI shim、注册表或其他 Windows 专属
API 可能不适用。即使属于明确边界，也要保留三次经过修正的 FastCtx 失败证据；不能只
因为一次非零退出码就立即切换。非零退出码本身是待诊断结果。

## 验证

解压目录中的只读验证命令：

```powershell
.\install-fastctx-windows.ps1 -VerifyOnly
```

验证内容包括：

- 已安装二进制与 Release 包内 SHA-256 一致；
- FastCtx 配置、Codex MCP 表和标准预算有效；
- Claude Code 用户级 MCP 定义与期望完全一致（除非显式 `-SkipClaudeCode`）；
- Claude/Codex 生效说明文件中只有一个精确受管块；
- CC Switch 深链载荷包含稳定命令、标准预算和全部六个受支持应用；只读验证不检查数据库；
- MCP `initialize` 成功，`tools/list` 恰好返回九个工具；
- `verify-fastctx-mcp.ps1` 在一次性用户目录中真实调用九个工具并清理 job 与测试文件。

`-VerifyOnly` 不创建缺失目录、不写配置、不复制二进制、不创建备份，也不修复差异；
任何缺失或冲突都会返回失败。握手会启动真实 MCP 服务，因此可能触碰 FastCtx 正常的
control-center runtime 状态，但不会改写受检配置文件。

仓库回归还覆盖：

- Claude MCP 添加、匹配 no-op、冲突拒绝与显式强制替换；
- `CLAUDE_CONFIG_DIR` 和 `AGENTS.override.md` 优先级；
- BOM/CRLF 与标记外用户内容保持、畸形标记拒绝及幂等；
- Codex 非 FastCtx TOML 保持、备份和标准预算；
- CC Switch 六应用深链字段、命令、环境、preflight 和无界面/只读边界；
- 仓库链接引导器的 latest/固定 tag URL、Release 级校验、损坏清单拒绝和临时目录清理；
- Release ZIP 解压后脱离源码树完成安装与只读验证；
- 包内与 Release 级 SHA-256、PowerShell 语法和精确归档内容。

## 清理边界

构建和测试只能删除自己在系统临时目录下创建的 GUID 子目录。递归删除前必须验证绝对
路径仍位于声明的临时根内。不要把以下持久状态当作测试垃圾：

- `~/.fastctx/jobs`；
- `~/.fastctx/config.toml`；
- `~/.codex/backups/config`；
- 正在使用的 Claude/Codex 配置和 FastCtx runtime cache。

升级后重启已经安装的 MCP 客户端，让新会话重新加载 MCP 定义和全局说明；如果安装时
打开了 CC Switch 确认框，还必须先核对并点击 **Import**。
