# Daymark

iOS 日记应用（Xcode 工程 `daymark.xcodeproj`，scheme `daymark`），个人项目。

开工前先读 `docs/STATE.md`（做到哪、下一步）；需要背景时读 `docs/DECISIONS.md`。构建细节见 `README.md`。

## 构建与发布

- 用 `scripts/build.sh` 构建和测试（`test`、`install`、`all`）。它面向配对的 iPhone，不用模拟器，退出时总会关闭模拟器、删除构建中间文件。
- 用 `scripts/release.sh` 发布到 App Store（归档、上传、经 App Store Connect API 提交审核；`check`、`archive`、`--dry-run` 是安全的）。版本号 1.x.y：每次发布自动加 y；只有 Aaron 要求大版本时才用 `--minor` 加 x。密钥和 issuer ID 在 `~/.appstoreconnect/`，绝不进 git。

## 规则

- 新分支命名 `feature/attopos/<简短描述>`；不开 PR，在 Mac 上构建、测试通过后合进 `main` 并 push。
- 绝不提交 `posters/`。
- 不用模拟器，直接装真机测试；每次 build 或测试后立即关闭模拟器、删除构建中间文件。
- commit 和 PR 里不加 Co-Authored-By、Claude-Session 等署名行。
- 代码里尽量不写注释，除非是特别关键的功能。

## 文档同步

- 每次修改在同一个提交里更新 `docs/STATE.md`；做了取舍就在 `docs/DECISIONS.md` 末尾追加一条。纯格式化、依赖升级等可在提交说明里写 `[skip-state]`。
- `docs/STATE.md` 每次整份重写，不往后追加：只写现在、下一步、注意三节，保持在 25 行以内（超出时 commit-msg hook 会提醒）。做完的细节写进提交说明，取舍写进 `docs/DECISIONS.md`（只追加，每条不超过四行）。测试记录这类越积越多的文件只留最近几个版本，更早的移到 `docs/archive/`。
- 这三份文档会自动同步到 Atlas（`~/Developer/atlas-ac`，github.com/Attopos/atlas-ac）和 ACdian 的 Atlas 模块，那边只读，只在这里改。
- 出了错或被纠正，把教训补进本文件的规则。
