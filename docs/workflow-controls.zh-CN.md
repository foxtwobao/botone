# Workflow 开关与手动镜像构建

保留上游 workflow 文件，通过 GitHub **Actions → 对应 workflow → 菜单 → Disable workflow** 暂停不使用的服务。禁用设置保存在 GitHub，不出现在 Git diff 中；恢复时选择 **Enable workflow**。禁用不删除历史记录，也不取消已经开始的运行。

## 暂停的可选流程

| Workflow 文件 | 暂停原因 |
| --- | --- |
| `preview-build.yml`、`preview-deploy.yml`、`preview-cleanup.yml` | 暂不使用 PR 临时预览站，避免额外构建预览镜像；以后恢复预览前先配置服务和清理流程 |
| `issue-triage.yml` | 暂不使用 AI Issue 分类 |
| `release-mobile.yml`、`release-google-play.yml`、`release-android-apk.yml`、`release-desktop.yml` | 尚未接入自己的正式签名、商店及发布配置，测试包使用单独的手动流程 |
| `publish-playwright-report.yml` | 暂不使用外部截图报告发布；CI 的测试及截图 Artifact 保留 |
| `weekly-dependencies.yml`、`model-catalog-bump.yml` | 暂不使用自动依赖更新 |
| `nightly-verification.yml` | 暂不运行每日扩展验证 |
| `review-bot.yml` | 暂不使用评审机器人的切换逻辑；不控制独立安装的 GitHub App |

以上共 13 个 workflow。恢复前同时核对所需凭据和 Repository variables；workflow 的启用状态与 `*_ENABLED` 变量是不同的开关。不要为恢复一项服务开启所有发布变量。

## 保留的检查和工具

保留 `ci.yml`、`playwright.yml`、`computer-replay.yml` 和 `publish-server-image.yml`。其中 `publish-server-image.yml` 在相关 PR 上验证镜像，不应因名称包含 publish 就关闭；它的 GHCR 正式发布继续受 `GHCR_PUBLISH_ENABLED` 限制。

保留翻译目录同步及手动 macOS 截图、Android 截图、拓扑验证。`pr-screenshots.yml` 是被调用的流程，没有独立自动触发入口。

核心 CI 仍可编译应用、构建用于验证的容器并保留诊断产物；“手动镜像发布”指下面两个 Docker Hub 发布流程，不关闭这些自动检查。

## 手动发布镜像

在镜像 workflow 修改尚未合并期间，先在 GitHub 暂停 `publish-dockerhub.yml` 和 `publish-execution.yml`，防止旧触发条件继续自动发布。确认默认分支中的两个文件都只保留 `workflow_dispatch` 后，再启用它们。不要在旧版本上提前恢复。

1. 打开 Actions，选择 **Publish Docker Hub amd64** 或 **Publish prepared computer image**。
2. 如仍显示禁用，按上一段确认默认分支配置后选择 **Enable workflow**。
3. 点击 **Run workflow**，选择 `main`；其他分支会跳过发布任务。
4. 等待检查、构建和推送完成，再部署对应镜像。发布镜像本身不部署服务器。

| Workflow | 产物 |
| --- | --- |
| `publish-dockerhub.yml` | `linux/amd64` 应用镜像，包含 `sha-<commit>` 标签和当前主分支的 `latest` |
| `publish-execution.yml` | 配套的预制电脑环境镜像，仓库名带 `_computer` 后缀，包含 `sha-<commit>` 和 `latest` |

需要应用与电脑环境配套更新时，在同一个 `main` 提交上分别运行两个 workflow，记录各自的提交标签；不要在两个运行之间合并新提交。四端安装包是另一条手动构建流程，不由这里的镜像发布触发。

命令行示例，先替换 `OWNER/REPO`：

```sh
gh workflow run publish-dockerhub.yml --repo OWNER/REPO --ref main
gh workflow run publish-execution.yml --repo OWNER/REPO --ref main
```

这些命令会实际构建并推送镜像，只在准备发布时执行。使用已有的 `DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN` Secrets 和可选的 `DOCKERHUB_IMAGE` variable，不把真实值写入仓库。
