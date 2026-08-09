# Codex Windows Fast Patch Run

- Started: 2026-08-09 12:53:57 +08:00
- Finished: 2026-08-09 13:24:50 +08:00
- Active skill root: $env:USERPROFILE\Desktop\BLOG\codex-windows-fast-patch-skill-main
- Upstream skill source: chen0416ccc-cpu/codex-windows-fast-patch-skill@main
- Private archive remote: https://github.com/Fooljack/Fast-CTX.git@main
- Final skill SHA: 198da1ee099585d0aa25447e649419dd48e2b95d
- Self-update result: already up to date
- Private archive result: pending publish eligibility check
- Selected workflow: run-latest-fast-patch.ps1 default Fast/browser/Computer Use repair
- Main install exit code: 0

## Codex Package Before

- PackageFullName: OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
- Version: 26.803.5235.0
- SignatureKind: Developer
- InstallLocation: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0

## Codex Package After

- PackageFullName: OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
- Version: 26.803.5235.0
- SignatureKind: Developer
- InstallLocation: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0

## Version Correspondence

- MSIX dry run was executed before install.
- Dry-run summary:
```text
[codex-windows-fast-patch] warning: local marketplace not found: $env:USERPROFILE\.codex\marketplaces\openai-curated-local\.agents\plugins\marketplace.json
[codex-windows-fast-patch] warning: restore it from backup or re-extract it before registering marketplace
[codex-windows-fast-patch] Computer Use verify/repair: preflight before MSIX dry run
[codex-windows-fast-patch] powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\Desktop\BLOG\codex-windows-fast-patch-skill-main\scripts\install-computer-use-local.ps1 -VerifyOnly
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] Chrome native messaging manifest verification ok: origins=2
[codex-computer-use-local] Chrome app-server host config verification ok: $env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host-config.json
[codex-computer-use-local] Chrome native-host v2 state verification ok: entry=codex-runtime-9af64331750c5a8012115ed52d4de3e9 files=2
[codex-computer-use-local] runtime import ok: {"ok":true,"exports":["sky"],"method":"list_windows","resultType":"array","count":5}
[codex-computer-use-local] official lightweight cache verification ok: computer-use@26.803.41515 / runtime=$env:USERPROFILE\AppData\Local\OpenAI\Codex\runtimes\cua_node\package-fb5c760e14cf8fe8\bin\node_modules\@oai\sky
[codex-computer-use-local] verification ok
[codex-windows-fast-patch] config.toml backup before overwrite: $env:USERPROFILE\.codex\backups\config\config.toml.20260809-125431-445.set--features--computer_use.bak
[codex-windows-fast-patch] local feature enabled: features.computer_use = true
[codex-windows-fast-patch] Windows sandbox mode set: windows.sandbox = unelevated
[codex-windows-fast-patch] patch attempt 1/1 source package: OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0 signature=Developer
[codex-windows-fast-patch] powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\Desktop\BLOG\codex-windows-fast-patch-skill-main\scripts\patch_codex_fast_mode_windows_msix.ps1 -DryRun -ForceRebuild -CleanupAfter -OutputRoot D:\codex-msix-repack-fastctx
[codex-msix-patch-win] source app: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0\app
[codex-msix-patch-win] source package: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
[codex-msix-patch-win] output root: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0
[codex-msix-patch-win] copying package layout to: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\package
[codex-msix-patch-win] Chrome localized registry parsing patch result: already-patched
[codex-msix-patch-win] extracting app.asar
[codex-msix-patch-win] plugin auth gate not found; treating current build as already open or migrated
[codex-msix-patch-win] goal composer gate not found; treating current build as already open or migrated
[codex-msix-patch-win] fast-mode patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] fast-mode UI patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] custom models patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] Power slider patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] Ultra slider local-fallback patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] locale i18n patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] GPT-5.6 model UI patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] plugin sidebar patch target:
[codex-msix-patch-win] plugin skills-page patch target:
[codex-msix-patch-win] plugin detail patch target:
[codex-msix-patch-win] plugin page auth patch target:
[codex-msix-patch-win] goal composer patch target:
[codex-msix-patch-win] goal slash-command patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] browser-use feature hook patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] browser-sidebar availability patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] desktop browser-use sender patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] desktop browser-use receiver patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\.vite\build\main-9TSQ_KaE.js
[codex-msix-patch-win] computer-use availability patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] computer-use install-flow patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] computer-use setup patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\webview\assets\codex-mobile-setup-dialog-qtLFZRnM.js
[codex-msix-patch-win] bundled marketplace copy patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-1a1bd6ba57d94952b7c5498339eb5df0\asar-extracted\.vite\build\main-9TSQ_KaE.js
[codex-msix-patch-win] fast-mode patch result: already-patched
[codex-msix-patch-win] fast-mode UI patch result: already-patched
[codex-msix-patch-win] custom models patch result: already-patched (already-patched)
[codex-msix-patch-win] Power slider patch result: already-patched
[codex-msix-patch-win] Ultra slider local-fallback patch result: already-patched
[codex-msix-patch-win] locale i18n patch result: already-patched
[codex-msix-patch-win] GPT-5.6 model UI patch result: patched
[codex-msix-patch-win] plugin patch result: already-patched
[codex-msix-patch-win] goal patch result: already-patched
[codex-msix-patch-win] browser-use gate patch result: already-patched
[codex-msix-patch-win] computer-use gate patch result: already-patched
[codex-msix-patch-win] bundled marketplace copy patch result: already-patched
[codex-msix-patch-win] dry run: patch target validation completed; no package was changed
[codex-msix-patch-win] cleanup build root: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0
[codex-msix-patch-win] done
[codex-windows-fast-patch] warning: local marketplace not found: $env:USERPROFILE\.codex\marketplaces\openai-curated-local\.agents\plugins\marketplace.json
[codex-windows-fast-patch] warning: restore it from backup or re-extract it before registering marketplace
[codex-windows-fast-patch] Computer Use verify/repair: post-dry-run final verification
[codex-windows-fast-patch] powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\Desktop\BLOG\codex-windows-fast-patch-skill-main\scripts\install-computer-use-local.ps1 -VerifyOnly
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] Chrome native messaging manifest verification ok: origins=2
[codex-computer-use-local] Chrome app-server host config verification ok: $env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host-config.json
[codex-computer-use-local] Chrome native-host v2 state verification ok: entry=codex-runtime-9af64331750c5a8012115ed52d4de3e9 files=2
[codex-computer-use-local] runtime import ok: {"ok":true,"exports":["sky"],"method":"list_windows","resultType":"array","count":5}
[codex-computer-use-local] official lightweight cache verification ok: computer-use@26.803.41515 / runtime=$env:USERPROFILE\AppData\Local\OpenAI\Codex\runtimes\cua_node\package-fb5c760e14cf8fe8\bin\node_modules\@oai\sky
[codex-computer-use-local] verification ok
[codex-windows-fast-patch] local feature enabled: features.computer_use = true
[codex-windows-fast-patch] Windows sandbox mode set: windows.sandbox = unelevated
[codex-windows-fast-patch] package: OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
[codex-windows-fast-patch] signature: Developer
[codex-windows-fast-patch] install location: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
[codex-windows-fast-patch] makeappx.exe: <missing>
[codex-windows-fast-patch] signtool.exe: <missing>
[codex-windows-fast-patch] computer-use helper: <missing>
[codex-windows-fast-patch] computer-use user env: 1
```

## Commands Used

- scripts\update-skill-from-github.ps1 -SkillDir "$env:USERPROFILE\Desktop\BLOG\codex-windows-fast-patch-skill-main" -Owner "chen0416ccc-cpu" -Repo "codex-windows-fast-patch-skill" -Branch "main"
- scripts\apply-local-hardening.ps1 -SkillDir "$env:USERPROFILE\Desktop\BLOG\codex-windows-fast-patch-skill-main"
- scripts\configure-fastctx.ps1 -VerifyOnly
- scripts\manage-codex-backups.ps1 -Action Backup
- codex plugin list
- scripts\install-computer-use-local.ps1 -VerifyOnly
- scripts\install-computer-use-local.ps1 -StrictVerifyOnly -VerifyAllBundledPluginsAvailable
- scripts\repatch-codex-windows.ps1 -DryRun
- scripts\repatch-codex-windows.ps1 -SkipComputerUse (skipped when -DryRunOnly is set)
- shell:AppsFolder launch fallback when needed
- scripts\patch_codex_fast_mode_windows_msix.ps1 -DryRun -ForceRebuild -VerifyFastModeRequest
- codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK

## Problems And Resolutions

- None

## Final Validation

- Package status:
```text
- PackageFullName: OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
- Version: 26.803.5235.0
- SignatureKind: Developer
- InstallLocation: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
```
- Plugin list:
```text
Marketplace `personal`
$env:USERPROFILE\.agents\plugins\marketplace.json

PLUGIN                 STATUS         VERSION  PATH
computer-use@personal  not installed           $env:USERPROFILE\plugins\computer-use

Marketplace `openai-primary-runtime`
$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\plugins\openai-primary-runtime\.agents\plugins\marketplace.json

PLUGIN                                   STATUS              VERSION       PATH
documents@openai-primary-runtime         installed, enabled  26.805.11740  $env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\plugins\openai-primary-runtime\plugins\documents
pdf@openai-primary-runtime               installed, enabled  26.805.11740  $env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\plugins\openai-primary-runtime\plugins\pdf
spreadsheets@openai-primary-runtime      installed, enabled  26.805.11740  $env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\plugins\openai-primary-runtime\plugins\spreadsheets
presentations@openai-primary-runtime     installed, enabled  26.805.11740  $env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\plugins\openai-primary-runtime\plugins\presentations
template-creator@openai-primary-runtime  installed, enabled  26.805.11740  $env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\plugins\openai-primary-runtime\plugins\template-creator

Marketplace `openai-api-curated`
$env:USERPROFILE\.codex\.tmp\plugins\.agents\plugins\api_marketplace.json

PLUGIN                                           STATUS              VERSION   PATH
game-studio@openai-api-curated                   not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\game-studio
superpowers@openai-api-curated                   not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\superpowers
circleci@openai-api-curated                      not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\circleci
sentry@openai-api-curated                        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\sentry
build-macos-apps@openai-api-curated              not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\build-macos-apps
build-web-apps@openai-api-curated                not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\build-web-apps
build-web-data-visualization@openai-api-curated  not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\build-web-data-visualization
test-android-apps@openai-api-curated             not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\test-android-apps
life-science-research@openai-api-curated         not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\life-science-research
zotero@openai-api-curated                        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\zotero
expo@openai-api-curated                          not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\expo
coderabbit@openai-api-curated                    not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\coderabbit
remotion@openai-api-curated                      not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\remotion
plugin-eval@openai-api-curated                   not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\plugin-eval
render@openai-api-curated                        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\render
temporal@openai-api-curated                      not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\temporal
hyperframes@openai-api-curated                   not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\hyperframes
codex-security@openai-api-curated                not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\codex-security
twilio-developer-kit@openai-api-curated          not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\twilio-developer-kit
mixpanel-headless@openai-api-curated             not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\mixpanel-headless
nvidia@openai-api-curated                        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\nvidia
ngs-analysis@openai-api-curated                  not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\ngs-analysis
magicpath@openai-api-curated                     not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\magicpath
openai-ads-conversions@openai-api-curated        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\openai-ads-conversions
boltz-api-cli@openai-api-curated                 not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\boltz-api-cli
linear@openai-api-curated                        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\linear
figma@openai-api-curated                         installed, enabled  11c74d6b  $env:USERPROFILE\.codex\.tmp\plugins\plugins\figma
notion@openai-api-curated                        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\notion
github@openai-api-curated                        not installed                 $env:USERPROFILE\.codex\.tmp\plugins\plugins\github

Marketplace `openai-bundled`
$env:USERPROFILE\.codex\marketplaces\openai-bundled-local\.agents\plugins\marketplace.json

PLUGIN                        STATUS              VERSION       PATH
computer-use@openai-bundled   installed, enabled  26.803.41515  $env:USERPROFILE\.codex\marketplaces\openai-bundled-local\plugins\computer-use
sites@openai-bundled          not installed                     $env:USERPROFILE\.codex\marketplaces\openai-bundled-local\plugins\sites
browser@openai-bundled        installed, enabled  26.803.41515  $env:USERPROFILE\.codex\marketplaces\openai-bundled-local\plugins\browser
chrome@openai-bundled         installed, enabled  26.803.41515  $env:USERPROFILE\.codex\marketplaces\openai-bundled-local\plugins\chrome
latex@openai-bundled          installed, enabled  0.2.4         $env:USERPROFILE\.codex\marketplaces\openai-bundled-local\plugins\latex
deep-research@openai-bundled  not installed                     $env:USERPROFILE\.codex\marketplaces\openai-bundled-local\plugins\deep-research
visualize@openai-bundled      not installed                     $env:USERPROFILE\.codex\marketplaces\openai-bundled-local\plugins\visualize
```
- Computer Use final strict verification:
```text
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] Chrome native messaging manifest verification ok: origins=2
[codex-computer-use-local] Chrome app-server host config verification ok: $env:USERPROFILE\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host-config.json
[codex-computer-use-local] Chrome native-host v2 state verification ok: entry=codex-runtime-9af64331750c5a8012115ed52d4de3e9 files=2
[codex-computer-use-local] using user-local Codex CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-computer-use-local] all bundled marketplace plugins are available without changing install state: browser,chrome,computer-use,deep-research,latex,sites,visualize
[codex-computer-use-local] runtime import ok: {"ok":true,"exports":["sky"],"method":"list_windows","resultType":"array","count":5}
[codex-computer-use-local] official lightweight cache verification ok: computer-use@26.803.41515 / runtime=$env:USERPROFILE\AppData\Local\OpenAI\Codex\runtimes\cua_node\package-fb5c760e14cf8fe8\bin\node_modules\@oai\sky
[codex-computer-use-local] verification ok
```
- Final live patch and Fast wire verification:
```text
[codex-msix-patch-win] source app: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0\app
[codex-msix-patch-win] source package: C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0
[codex-msix-patch-win] output root: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0
[codex-msix-patch-win] copying package layout to: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\package
[codex-msix-patch-win] Chrome localized registry parsing patch result: already-patched
[codex-msix-patch-win] extracting app.asar
[codex-msix-patch-win] plugin auth gate not found; treating current build as already open or migrated
[codex-msix-patch-win] goal composer gate not found; treating current build as already open or migrated
[codex-msix-patch-win] fast-mode patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] fast-mode UI patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] custom models patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] Power slider patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] Ultra slider local-fallback patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] locale i18n patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] GPT-5.6 model UI patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] plugin sidebar patch target:
[codex-msix-patch-win] plugin skills-page patch target:
[codex-msix-patch-win] plugin detail patch target:
[codex-msix-patch-win] plugin page auth patch target:
[codex-msix-patch-win] goal composer patch target:
[codex-msix-patch-win] goal slash-command patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] browser-use feature hook patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] browser-sidebar availability patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] desktop browser-use sender patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] desktop browser-use receiver patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\.vite\build\main-9TSQ_KaE.js
[codex-msix-patch-win] computer-use availability patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] computer-use install-flow patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\app-initial-CUcIZsiK.js
[codex-msix-patch-win] computer-use setup patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\webview\assets\codex-mobile-setup-dialog-qtLFZRnM.js
[codex-msix-patch-win] bundled marketplace copy patch target: D:\codex-msix-repack-fastctx\OpenAI.Codex_26.803.5235.0\work-45a82f689ad44c48b75e01a8696d24e2\asar-extracted\.vite\build\main-9TSQ_KaE.js
[codex-msix-patch-win] fast-mode patch result: already-patched
[codex-msix-patch-win] fast-mode UI patch result: already-patched
[codex-msix-patch-win] custom models patch result: already-patched (already-patched)
[codex-msix-patch-win] Power slider patch result: already-patched
[codex-msix-patch-win] Ultra slider local-fallback patch result: already-patched
[codex-msix-patch-win] locale i18n patch result: already-patched
[codex-msix-patch-win] GPT-5.6 model UI patch result: patched
[codex-msix-patch-win] plugin patch result: already-patched
[codex-msix-patch-win] goal patch result: already-patched
[codex-msix-patch-win] browser-use gate patch result: already-patched
[codex-msix-patch-win] computer-use gate patch result: already-patched
[codex-msix-patch-win] bundled marketplace copy patch result: already-patched
[codex-msix-patch-win] dry run: patch target validation completed; no package was changed
[codex-msix-patch-win] fast verification CLI: $env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\package-fb5c760e14cf8fe8\codex.exe
[codex-msix-patch-win] verifying Fast Mode by capturing Codex wire request service_tier
[codex-msix-patch-win] fast verification: request wire service_tier=priority (Codex Fast Mode)
[codex-msix-patch-win] done
```
- Sandbox smoke test:
```text
Command: codex sandbox "C:\Windows\System32\cmd.exe" /c echo OK
OK
```
- Desktop process summary:
```text
pid=12424 path=C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe
pid=13132 path=C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe
pid=15916 path=C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe
pid=26636 path=C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe
pid=30600 path=C:\Program Files\WindowsApps\OpenAI.Codex_26.803.5235.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe
```
- Local hardening output:
```text
[codex-local-hardening] local hardening overlay complete
```
- FastCtx verification:
```text
[fastctx-configure] binary: fastctx 0.2.4
[fastctx-configure] TOML valid: $env:USERPROFILE\.fastctx\config.toml
[fastctx-configure] TOML valid: $env:USERPROFILE\.codex\config.toml
[fastctx-configure] FastCtx MCP tables and stable paths are valid
[fastctx-configure] status passed: [PASS] Codex profile: Configuration root: C:/Users/wangjie/.codex (source: flag).
[fastctx-configure] MCP initialize/tools-list passed: glob, grep, job_kill, job_list, job_output, read, replace, run, run_background
[fastctx-configure] FastCtx chain is ready; restart Codex Desktop once to reload MCP configuration.
```
- Private archive output:
```text

```
