# Codex 桌面客户端一键接入公司 LiteLLM

[English](README.md) | **简体中文**

面向 **Windows Codex 桌面客户端**的配置脚本。下载后双击运行，按提示填写公司 API 地址、Key 和模型名，即可把本地 Codex 的模型请求接入公司 LiteLLM 网关。

脚本提供原配置备份、Windows DPAPI 加密保存 Key、模型别名配置、连接检查和恢复功能。正常使用无需安装 Python、Node.js 或额外 PowerShell 模块，也无需管理员权限。

setup 支持英文与中文。启动时先选择语言；也可传入 `-Language en` 或 `-Language zh-CN` 跳过语言菜单。

**[下载完整配置包 ZIP](https://github.com/hreyulog/codex_litellm_config/archive/refs/heads/main.zip)**

## 一、运行前准备

先安装并打开一次公司认可的 Codex 桌面客户端，完成必要的初始化。此脚本要求客户端内置的 **Codex CLI ≥ 0.160.0**，运行时会自动检查版本；不必另装 CLI。

向公司的 API 管理员确认以下信息：

| 需要的信息 | 示例 | 说明 |
| --- | --- | --- |
| API 基础地址 | `https://litellm.company.com/v1` | 包含管理员提供的完整 API 路径 |
| API Key | 在本机隐藏输入 | 使用公司分配的 LiteLLM Key，不要提交到 GitHub |
| 模型名 | `company-coding` | 使用网关对外提供的模型名，也称模型别名 |

公司的网关和所选模型需要支持 **Responses API、SSE 流式输出和工具调用**。只有 `/chat/completions` 接口不足以直接接入当前 Codex。公司网络需要能访问该网关；若要求 VPN，请先连接 VPN。

如果公司已统一管理 Codex 连接或使用 SSO，请以管理员提供的配置方式为准。本脚本适用于自行配置公司 API Key 的情况。

## 二、下载和运行

### 第 1 步：下载脚本

点击上面的“下载完整配置包 ZIP”，或在本仓库点击绿色 **Code → Download ZIP**。

解压 ZIP，打开解压后的文件夹。应能看到：

```text
codex_litellm_config-main/
├── setup.cmd                  双击启动
├── setup-codex-litellm.ps1     主配置脚本
├── README.md                  英文教程（仓库主页）
├── README.zh-CN.md             本中文教程
└── tests/                     维护者使用的本地测试
```

请解压后再运行，保留 `setup.cmd` 和 `setup-codex-litellm.ps1` 在同一个文件夹中。

### 第 2 步：退出 Codex

保存当前工作，**完全退出 Codex 桌面客户端**，避免客户端在配置期间更新文件。完成配置后再重新打开。

### 第 3 步：双击 setup.cmd

双击 **setup.cmd**，先选择语言：

```text
Language / 语言
1. English
2. 简体中文
Choose / 选择 [1]: 2
```

输入 `2` 使用中文；输入 `1` 或直接回车使用英文。随后出现操作菜单，输入 `1` 或直接按回车配置公司 API：

```text
1. 配置公司 API
9. 恢复首次运行前的配置（先备份当前文件）
0. 退出
```

按提示填写 API 基础地址，例如：

```text
https://litellm.company.com/v1
```

已有 `/v1` 时不会重复添加。仅填写域名根地址时，脚本自动补 `/v1`；公司提供的其他路径会保留。如果你拿到的是完整 `/responses` 或 `/chat/completions` 地址，脚本会去掉接口尾部，转换成基础地址。屏幕会显示最终请求地址，供你核对。

接着输入公司的 API Key。**输入内容不会显示在屏幕上，也不会作为命令行参数保存。**粘贴后按回车。

### 第 4 步：选择公司模型

脚本尝试读取网关模型列表。列表可用时，可以输入模型编号；也可以直接输入管理员提供的完整模型名：

```text
company-coding
```

请选支持工具调用的聊天模型。这里使用 LiteLLM 的模型别名，不要擅自替换成底层供应商的模型名。

如果网关已提供 Codex 模型元数据，脚本会直接使用。否则：

- 模型名与客户端内置模型一致时，自动使用对应的内置元数据。
- 自定义别名没有元数据时，脚本会询问别名背后的实际模型。只有管理员确认了映射、且该模型在屏幕列出的内置目录中，才填写实际模型名。
- 不知道实际模型时，直接回车，使用通用文本和函数调用配置。

随后脚本会让你设置上下文长度，无论使用通用配置还是已有模型元数据：

```text
上下文长度（tokens，例如 100000 或 100k；回车默认 32768）: 100k
Codex 上下文窗口设置为 100000 tokens
```

可以输入 `100000` 或 `100k`，两者都表示 **100,000 tokens**；`128k` 表示 128,000。回车使用默认值：通用配置为 32768，已有元数据时使用该模型的窗口。无效输入会提示重新填写；最小值为 4096 tokens。

**这个设置不会扩大模型本身的容量。**请填写公司模型实际支持的长度；脚本不会仅根据模型名中的 `100k`、`128k`、`200k` 推断容量。上下文包含提示、聊天记录、工具信息与输出，Codex 还会预留空间，因此界面显示的可用预算可能低于填写的数值。通用配置保留 90% 的有效窗口比例。

脚本将数值同步写入 `config.toml` 的 `model_context_window` 和所选模型的目录元数据。命令行传入 `-ContextWindow 100000` 时，直接使用该值，不再询问；更换长度后完全退出客户端、重新打开并新建聊天。

这些信息用于让 Codex 了解模型的上下文窗口、推理等级和工具格式。实际请求仍然使用你选定的**公司模型别名**。

### 第 5 步：等待检查完成

脚本先用 Codex 内置解析器检查生成的配置与模型目录，再发送两次简短请求，检查：

1. Responses API 是否返回有效 SSE 流式响应。
2. 模型能否返回函数调用。
3. 工具结果能否续接成下一轮回复。

这两次请求不发送工作文件，会计入公司 API 用量。检查通过后才写入正式配置；检查失败会显示原因，并保留原配置。基础检查不能保证所有工具、图片、搜索等功能都兼容。

看到下面的提示，表示配置写入完成：

```text
配置完成：Company LiteLLM / company-coding
```

### 第 6 步：重新打开 Codex

重新打开桌面客户端，选择公司的模型，**新建聊天**后使用。已有聊天可能仍保留原来的模型或提供商。

如有权限查看公司的 LiteLLM 用量或请求日志，可以确认请求使用了你的 Key 和公司模型别名。

## 三、Key 如何保存

Key 用 Windows **DPAPI 加密**保存，由录入凭据时的 Windows 用户解密。Codex 通过官方的 `model_providers.<id>.auth` 认证命令调用本地 PowerShell 程序读取 Key，因此客户端重启后仍可使用，不依赖桌面程序继承终端环境变量。

凭据文件与认证程序的访问权限限制为当前 Windows 用户和 SYSTEM。同一 Windows 用户运行的其他程序仍有能力解密凭据，DPAPI 不替代公司的密钥管理制度。

**在公司电脑上运行配置并输入 Key。**不要把另一台电脑生成的 DPAPI 凭据文件当作可移植 Key，也不要分享 `.codex` 配置或备份目录。

## 四、配置文件和备份

默认配置目录是 `%USERPROFILE%\.codex`。若已设置 `CODEX_HOME`，脚本使用该目录；也可通过 `-CodexHome` 指定。

| 文件或目录 | 用途 |
| --- | --- |
| `config.toml` | Codex 模型、公司网关和本地认证命令配置 |
| `litellm-models.json` | 与当前客户端版本匹配的模型目录 |
| `litellm-auth.ps1` | 供 Codex 调用的本地凭据读取程序 |
| `litellm-key.dpapi` | 当前 Windows 用户的加密 Key |
| `backup-litellm/initial/` | 首次配置前的完整文件备份 |
| `backup-litellm/时间-随机编号/` | 每次写入或恢复前的额外备份 |

原有 MCP、项目权限、插件等无关设置会保留。已有默认模型、相关推理参数、服务等级、登录限制、默认 profile 和模型目录等设置会被替换或清除，避免覆盖公司连接。公司机器级和项目级配置仍可能影响最终生效的设置。

写入期间发生错误时，脚本会尝试自动回滚；如果回滚也失败，会显示可用于手动恢复的备份路径。

## 五、更换模型、Key 或恢复原配置

### 更换公司连接

再次双击 `setup.cmd`，先选择语言，再选择 `1`，重新填写地址、Key 和模型。当前版本一次配置一个选定公司模型，并让它出现在模型选择器中。

客户端升级后，也可重新运行脚本，用新版本的内置模型元数据重新生成目录。

### 恢复原来的配置

完全退出 Codex，再运行 `setup.cmd`，先选择语言，再选择 `9`。

这会恢复**首次运行前的完整配置文件**，并清除当时不存在、由脚本新增的文件。以后在这些文件中添加的设置也会被还原；恢复操作前会先备份当前文件，方便取回后续修改。

恢复后重新打开 Codex，并新建聊天验证。

## 六、PowerShell 命令用法

在解压后的文件夹打开 PowerShell，运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-codex-litellm.ps1
```

如果已知地址和公司模型名，可以减少交互：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-codex-litellm.ps1 -Language zh-CN -Action Configure -BaseUrl "https://litellm.company.com/v1" -Model "company-coding" -ContextWindow 100000
```

也可以通过启动器直接使用中文和 100k 上下文：

```powershell
.\setup.cmd -Language zh-CN -ContextWindow 100000
```

Key 始终隐藏输入，不作为参数。

| 参数 | 作用 |
| --- | --- |
| `-Language en` / `-Language zh-CN` | 使用英文或中文，跳过语言菜单 |
| `-Action Configure` | 直接进入配置流程 |
| `-Action Restore` | 直接恢复首次配置前的文件 |
| `-BaseUrl "地址"` | 指定公司 API 基础地址 |
| `-Model "公司模型别名"` | 指定网关模型名 |
| `-UpstreamModel "实际模型名"` | 在管理员确认映射后，使用该内置模型的元数据 |
| `-ContextWindow 100000` | 指定所选模型的上下文窗口为 100k，跳过长度输入；不得超过实际模型容量 |
| `-CodexExe "C:\实际路径\bin\codex.exe"` | 安装位置特殊时，指定内置 CLI，而非桌面主程序 |
| `-CodexHome "D:\自定义配置目录"` | 指定已有配置目录 |
| `-SkipProbe` | 已验证兼容性或排查时跳过网关检查；此时连接尚未由脚本确认 |

`ExecutionPolicy Bypass` 只用于这次 PowerShell 进程，不修改永久执行策略。公司组策略、AppLocker 或 WDAC 仍可能禁止运行；这时需要 IT 提供签名或批准的运行方式。

## 七、常见问题

| 现象 | 处理方法 |
| --- | --- |
| 找不到 `.codex` 目录 | 先安装并打开一次客户端；自定义目录需提前存在 |
| 找不到内置 CLI | 更新客户端；安装路径特殊时用 `-CodexExe` 指定正确的内置程序 |
| 内置 CLI 版本过低 | 更新公司认可的 Codex 桌面客户端，脚本要求至少 0.160.0 |
| 读取不到模型列表 | 手动输入管理员提供的公司模型别名；脚本仍会检查该模型的基础连接 |
| HTTP 401 | 检查 Key 是否有效、是否过期 |
| HTTP 403 | 检查 Key 是否有模型和接口权限 |
| HTTP 404 | 检查公司基础路径、`/v1` 和网关是否提供 `/responses` |
| HTTP 400 / 工具调用失败 | 请管理员检查 LiteLLM 版本、模型路由和 Responses 转换是否兼容 |
| HTTP 429 | 检查额度、并发限制，或稍后重试 |
| 没收到 `response.completed` | 请管理员检查 Responses 的 SSE 流式协议 |
| 网络或证书失败 | 检查 VPN、代理、公司 CA；脚本不会跳过证书校验 |
| 本地认证命令失败 | 确认使用录入 Key 时的 Windows 用户，凭据仍在原目录，且公司允许认证程序运行 |
| 配置成功但仍用其他模型 | 完全退出客户端、重启、新建聊天；检查公司管理配置和项目配置 |

接入公司 API 改变的是**本地 Codex 的模型请求路由**。桌面客户端的其他联网功能可能访问其他服务，具体以公司网络与客户端管理策略为准。

## 八、验证情况与参考资料

已在 **Windows PowerShell 5.1 + Codex CLI 0.160.0** 上用本地模拟网关验证：配置保留、重复运行、备份恢复、写入失败回滚、错误响应拦截，以及实际 Codex 进程通过 DPAPI 认证完成一次流式模型请求。真实公司网关需在公司电脑上验证。

维护者可参考 [本地测试教程](tests/README.md)。

- [OpenAI：连接公司网关与认证命令](https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway)
- [OpenAI：上下文窗口配置 `model_context_window`](https://learn.chatgpt.com/docs/config-file/config-reference)
- [LiteLLM：Codex 桌面客户端配置](https://docs.litellm.ai/docs/proxy/client_setup/codex_chatgpt_desktop)
- [LiteLLM：Codex CLI 与模型元数据](https://docs.litellm.ai/docs/proxy/client_setup/codex_cli)
- [DeepSeek：Codex 一键配置示例](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)
