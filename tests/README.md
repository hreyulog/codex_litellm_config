# 本地验证教程

本目录用于维护者验证脚本，使用本地模拟网关和虚拟 Key，不连接真实模型供应商。

测试需要 Windows、Windows PowerShell 5.1、Python 3 和 Codex 内置 CLI。CLI 路径通过参数传入。测试会创建临时配置、生成测试用 DPAPI 凭据并调整测试文件的访问权限，请在当前 Windows 用户的正常本地终端运行。

## 1. 启动本地模拟网关

在仓库根目录打开 PowerShell，运行：

```powershell
python .\tests\mock_gateway.py .\tests\mock-requests.jsonl
```

程序只监听 `127.0.0.1`，会输出自动分配的端口号，例如 `49691`。保持该终端运行。

## 2. 验证配置与恢复

再打开一个 PowerShell 终端，替换端口和内置 CLI 的实际路径后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-setup.ps1 -Port 49691 -CliPath "C:\实际路径\bin\codex.exe"
```

该测试检查：

- URL 路径处理及无效地址拦截。
- MCP、项目权限、多行字符串、数组和其他提供商配置保留。
- 重复运行不会产生重复设置。
- DPAPI 凭据加密、解密和访问权限。
- 自定义模型目录能通过实际 Codex 解析器加载。
- JSON 接口、截断 SSE、缺失 Responses 接口及 HTTP 错误处理。
- 网关检查失败时保留配置，写入失败时自动回滚。
- 恢复操作还原原文件的完整字节内容。

看到 `ALL CHECKS PASSED` 即表示通过。

## 3. 验证实际 Codex 请求

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-codex-runtime.ps1 -Port 49691 -CliPath "C:\实际路径\bin\codex.exe"
```

此测试启动实际 Codex 进程，使用测试用加密 Key 和公司模型别名向模拟网关发送请求。它检查认证命令、请求路由和完整流式回复，看到 `REAL CODEX RUNTIME PASSED` 即表示通过。

## 4. 测试输出

配置测试在 `tests/runs/` 下生成文件；进程测试使用 `tests/runtime-*/`。模拟请求写入 `tests/mock-requests.jsonl`。这些路径已加入 `.gitignore`，测试结束后可清理。

第一个终端按 `Ctrl+C` 可停止模拟网关。真实公司网关的兼容性仍需单独验证。
