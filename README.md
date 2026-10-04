# Connect Codex Desktop to Your Company's LiteLLM Gateway

**English** | [简体中文](README.zh-CN.md)

A setup script for **Codex Desktop on Windows**. Download the ZIP, run the launcher, and enter your company's API base URL, API key, and model alias to route local Codex model requests through your company's LiteLLM gateway.

The script backs up your existing configuration, encrypts the API key with Windows DPAPI, configures model metadata and the context window, checks the connection, and provides a restore option. Normal use requires no Python, Node.js, additional PowerShell modules, or administrator privileges.

**[Download the complete setup ZIP](https://github.com/hreyulog/codex_litellm_config/archive/refs/heads/main.zip)**

The setup supports English and Chinese. Choose your language when the launcher starts, or pass `-Language en` or `-Language zh-CN` to skip the language menu.

## 1. Prerequisites

Install your company's approved version of Codex Desktop and open it once to initialize its configuration directory. The script requires the desktop app's bundled **Codex CLI 0.160.0 or later** and checks the version automatically. You do not need to install a separate CLI.

Obtain these details from your company's API administrator:

| Detail | Example | Notes |
| --- | --- | --- |
| API base URL | `https://litellm.company.com/v1` | Include the complete API path provided by your company. |
| API key | Entered privately on your PC | Use your assigned LiteLLM key. Do not commit it to GitHub. |
| Model alias | `company-coding` | Use the model name exposed by your gateway. |

The gateway and selected model must support **Responses API, SSE streaming, and tool calls**. A working `/chat/completions` endpoint alone is insufficient for this direct Codex connection. Connect to your company network or VPN before running the script.

If your company manages Codex connections centrally or uses SSO, follow its administrator-provided setup. This script is intended for users configuring their own company API key.

## 2. Download and configure

### Step 1: Download and extract

Use the download link above, or select **Code → Download ZIP** on GitHub.

Extract the ZIP. The folder contains:

```text
codex_litellm_config-main/
├── setup.cmd                  Double-click to start
├── setup-codex-litellm.ps1     Main setup script
├── README.md                  English guide (repository homepage)
├── README.zh-CN.md            Chinese guide
└── tests/                     Local checks for maintainers
```

Run the files from the extracted folder. Keep `setup.cmd` and `setup-codex-litellm.ps1` together.

### Step 2: Exit Codex

Save your work and **fully exit Codex Desktop** before configuring it, so the app does not modify the same files during setup. Reopen it after setup finishes.

### Step 3: Run setup.cmd

Double-click **setup.cmd** and select a language:

```text
Language / 语言
1. English
2. 简体中文
Choose / 选择 [1]: 1
```

Press Enter to use English. Enter `2` for Chinese. Then select `1`, or press Enter to configure the company API:

```text
1. Configure company API
9. Restore the original configuration (back up current files first)
0. Exit
```

At the API base URL prompt, enter your company's address, for example:

```text
https://litellm.company.com/v1
```

The script keeps an existing `/v1`, adds `/v1` when you enter only the host's root URL, and preserves other company-provided base paths. If you enter a complete `/responses` or `/chat/completions` URL, it removes the endpoint suffix to obtain the base URL. Review the final request URL displayed on screen.

At the API key prompt, paste your key and press Enter. **The key is hidden on screen and is not passed as a command-line argument.**

### Step 4: Select a model and context window

The script tries to retrieve the gateway's model list. Enter a model number, or type the complete model alias supplied by your administrator:

```text
company-coding
```

Choose a chat model that supports tool calls. Use the LiteLLM alias exposed by your company rather than replacing it with the underlying provider's model name.

If the gateway supplies Codex model metadata, the script uses it. Otherwise:

- An alias matching a bundled Codex model uses that model's metadata.
- For an unknown alias, the script asks for the underlying model. Enter a model from the displayed bundled list only if your administrator has confirmed the mapping.
- If the model is unknown or is not an OpenAI model in that list, press Enter to use generic text and function-call metadata.

The script then asks for the context window, whether you use generic or existing model metadata:

```text
Context window (tokens, e.g. 100000 or 100k; Enter keeps 32768): 100k
Codex context window set to 100000 tokens; usable budget reserves space for prompts, tools and output.
```

Enter `100000` or `100k` for **100,000 tokens**, or another supported size such as `128k` for 128,000 tokens. Press Enter to keep the displayed default: 32768 for generic metadata, or the model's existing window when metadata is available. Invalid input prompts you to try again. The minimum is 4096 tokens.

**This setting does not increase the model's actual capacity.** Use a window your company's model supports. The script does not infer capacity from `100k`, `128k`, or `200k` in a model alias. Context includes prompts, conversation history, tool information, and output; Codex reserves space, so the usable budget may be lower than the entered value. Generic metadata retains a 90% effective context window.

The script writes the value to both `model_context_window` in `config.toml` and the selected model's catalog metadata. Supplying `-ContextWindow 100000` on the command line skips the context prompt. After changing the window, fully restart Codex and start a new chat.

Model metadata tells Codex about the context window, reasoning levels, and tool format. Requests still use your selected **company model alias**.

### Step 5: Wait for validation

The script first checks the generated configuration and model catalog with Codex's own parser. It then makes two small requests to verify:

1. A valid Responses API SSE stream.
2. A function call from the model.
3. A follow-up response after submitting the tool result.

These requests do not send your work files, but they count toward company API usage. The script writes the configuration only after these checks pass. On failure, it reports the error and keeps the original configuration. These basic checks do not establish compatibility with every tool, image, or search feature.

This message means the configuration was saved:

```text
Setup complete: Company LiteLLM / company-coding
```

### Step 6: Reopen Codex

Reopen Codex Desktop, select your company model, and **start a new chat**. Existing chats may retain their previous model or provider.

If you have access to LiteLLM usage records or request logs, check that requests use your assigned key and selected company alias.

## 3. API key storage

The key is encrypted with Windows **DPAPI** and decrypted by the Windows user who entered it. Codex calls a local PowerShell credential helper through `model_providers.<id>.auth`. This works after restarting the app and does not depend on the desktop app inheriting terminal environment variables.

Access to the credential file and helper is restricted to the current Windows user and SYSTEM. Other programs running as that same user can still decrypt the credential. DPAPI does not replace your company's key-management policy.

**Run setup and enter your key on the company PC.** Encrypted DPAPI files from another computer are not portable API keys. Do not share your `.codex` configuration or backup directory.

## 4. Configuration files and backups

The default configuration directory is `%USERPROFILE%\.codex`. If `CODEX_HOME` is set, the script uses it instead. You can also specify an existing directory with `-CodexHome`.

| File or directory | Purpose |
| --- | --- |
| `config.toml` | Model, gateway, context window, and credential-helper configuration. |
| `litellm-models.json` | Model catalog compatible with the installed Codex version. |
| `litellm-auth.ps1` | Local credential helper called by Codex. |
| `litellm-key.dpapi` | API key encrypted for the current Windows user. |
| `backup-litellm/initial/` | Complete backup of managed files before the first setup. |
| `backup-litellm/timestamp-random-id/` | Additional backup before each configuration or restore operation. |

Unrelated settings such as MCP servers, project permissions, and plugins are preserved. Existing default-model settings, related reasoning parameters, context overrides, service tiers, login restrictions, the default profile, and the model catalog are replaced or cleared to allow the company connection to take effect. Machine-level company configuration and project-level settings may still affect the final result.

If writing fails, the script attempts to roll back the changes. If rollback also fails, it displays a backup path for manual recovery.

## 5. Change the connection or restore the original configuration

### Change the model, key, or context window

Run `setup.cmd` again, select your language and then `1`, and enter the new settings. The current version configures one selected company model at a time and makes it visible in the model picker.

After upgrading Codex, you can rerun setup to regenerate the catalog using the updated bundled metadata.

### Restore the original configuration

Fully exit Codex, run `setup.cmd`, select your language, and then select `9`.

This restores the **complete managed files from before the first setup** and removes files created by the script that did not exist then. Later edits to these files are also reverted. The script backs up the current files before restoring them, so you can recover subsequent changes.

Reopen Codex and start a new chat after restoring.

## 6. PowerShell commands

Open PowerShell in the extracted folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-codex-litellm.ps1
```

If you know the base URL and alias, supply them along with a 100k context window and English prompts:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-codex-litellm.ps1 -Language en -Action Configure -BaseUrl "https://litellm.company.com/v1" -Model "company-coding" -ContextWindow 100000
```

You can also pass options through the launcher:

```powershell
.\setup.cmd -Language en -ContextWindow 100000
.\setup.cmd -Language zh-CN -ContextWindow 100000
```

The API key is always entered privately and is never accepted as a parameter.

| Parameter | Purpose |
| --- | --- |
| `-Language en` / `-Language zh-CN` | Use English or Chinese without the language menu. |
| `-Action Configure` | Go directly to configuration. |
| `-Action Restore` | Restore files from before the first setup. |
| `-BaseUrl "URL"` | Supply the company API base URL. |
| `-Model "company-alias"` | Supply the gateway model alias. |
| `-UpstreamModel "underlying-model"` | Use that bundled model's metadata after confirming the mapping with your administrator. |
| `-ContextWindow 100000` | Set the selected model's context window to 100k and skip the context prompt; stay within its actual capacity. |
| `-CodexExe "C:\actual-path\bin\codex.exe"` | Supply the bundled CLI path if it is installed elsewhere; use the CLI, not the desktop app executable. |
| `-CodexHome "D:\custom-config-directory"` | Use an existing custom configuration directory. |
| `-SkipProbe` | Skip the gateway checks for troubleshooting or an already validated connection; setup will not verify connectivity. |

`ExecutionPolicy Bypass` applies only to the launched PowerShell process and does not change the permanent execution policy. Company Group Policy, AppLocker, or WDAC may still block execution; ask IT for an approved or signed way to run the script.

## 7. Troubleshooting

| Symptom | What to check |
| --- | --- |
| `.codex` directory not found | Install and open Codex once; a custom directory must already exist. |
| Bundled CLI not found | Update Codex, or supply the correct CLI path with `-CodexExe`. |
| CLI version too old | Use a company-approved desktop version with bundled CLI 0.160.0 or later. |
| Model list unavailable | Enter the company alias manually; setup still checks the selected model. |
| HTTP 401 | Check whether the key is valid or expired. |
| HTTP 403 | Check the key's model and endpoint permissions. |
| HTTP 404 | Check the API base path, `/v1`, and availability of `/responses`. |
| HTTP 400 or failed tool calls | Ask the administrator to check the LiteLLM version, model routing, and Responses translation compatibility. |
| HTTP 429 | Check usage limits and concurrency, or retry later. |
| Missing `response.completed` | Ask the administrator to check the Responses SSE protocol. |
| Network or certificate error | Check VPN, proxy settings, and the company CA; the script does not disable certificate validation. |
| Credential helper fails | Use the Windows account that entered the key, keep the credential in its original location, and check whether company policy allows the helper to run. |
| Codex still uses another model | Fully exit, restart, and start a new chat; check company-managed and project configuration. |

This configuration routes **local Codex model requests** through the gateway. Other desktop features may connect to separate services according to your company's network and client-management policies.

## 8. Verification and references

The script has been tested with **Windows PowerShell 5.1 and Codex CLI 0.160.0**, using a local mock gateway. Checks cover configuration preservation, interactive 100k context selection, repeated setup, backups and restore, rollback after write failures, invalid gateway responses, and a real Codex process completing an SSE request using DPAPI authentication. Validate the real company gateway on the company PC.

Maintainers can follow the [local test guide](tests/README.md), currently available in Chinese.

- [OpenAI: Connect to a company gateway and configure credential helpers](https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway)
- [OpenAI: Context window configuration (`model_context_window`)](https://learn.chatgpt.com/docs/config-file/config-reference)
- [LiteLLM: Codex Desktop configuration](https://docs.litellm.ai/docs/proxy/client_setup/codex_chatgpt_desktop)
- [LiteLLM: Codex CLI and model metadata](https://docs.litellm.ai/docs/proxy/client_setup/codex_cli)
- [DeepSeek: Codex setup example](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)
