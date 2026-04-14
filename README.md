# self-hosted-runner-codex-review

**Codex CLI でPRを自動レビューする GitHub Actions ワークフロー。**

セルフホストランナーで実行するため、クラウドの API クレジットを消費せずサブスクリプション定額の範囲で運用できる。

## 導入方法

### 1. ランナーマシンの準備

以下のツールをインストールし、認証を済ませる:

| ツール | 用途 |
|--------|------|
| [Codex CLI](https://github.com/openai/codex) | レビュー実行（`codex login` で認証） |
| [GitHub CLI](https://cli.github.com) | PR コメント投稿（Actions では `GITHUB_TOKEN` を使用） |
| [PowerShell](https://github.com/PowerShell/PowerShell) | スクリプト実行（GitHub Actions ランナーにプリインストール） |

確認用スクリプト:

```bash
pwsh setup-runner.ps1
```

### 2. セルフホストランナーの登録

対象リポジトリの **Settings → Actions → Runners** からランナーを登録する。ラベルは `self-hosted` と `codex-review` を付与する。

```bash
./config.sh --url https://github.com/OWNER/REPO --token TOKEN --labels self-hosted,codex-review
```

### 3. 対象リポジトリに `.github/` をコピー

このリポジトリの `.github/` ディレクトリをそのまま対象リポジトリにコピーする:

```bash
cp -r .github/codex-review/ TARGET_REPO/.github/codex-review/
cp .github/workflows/codex-review.yml TARGET_REPO/.github/workflows/
```

これだけで動く。

## 設定 (.github/codex-review/config.yml)

プロジェクト固有の設定を追加できる。すべてのフィールドはオプション。

```yaml
# 使用モデル
model: gpt-5.4

# プロジェクト固有のレビュー指示
extra_prompt: |
  このプロジェクトは Go 1.24 + gRPC を使用。
  並行処理のデータ競合とコネクションリークに特に注意すること。
```

> **Note:** セキュリティ上、設定ファイルは PR ブランチではなく**デフォルトブランチの内容**が使用される。

## 動作

1. main/master への PR が作成・更新されるとワークフローが起動
2. セルフホストランナー上で `codex exec review --base <base-sha>` を read-only サンドボックスで実行
3. JSON 出力をパースし、**差分の該当行にインラインコメント**を投稿
4. インラインコメントが投稿できない指摘はサマリーコメントにフォールバック
5. 再レビュー時に古いコメントとインラインコメントを自動削除
6. 同一 PR の古いレビュー実行を自動キャンセル

重要度は **CRITICAL**、**WARNING**、**INFO** の3段階。INFO が不要な場合は `extra_prompt` で抑制できる。

## セキュリティモデル

セルフホストランナーで安全に運用するために、以下の多層防御を組み込んでいる。

| レイヤー | 仕組み |
|---------|--------|
| fork PR ブロック | fork からの PR は自動スキップ — 外部コードがランナー上で実行されない |
| ブランチ制限 | main/master への PR のみで起動 |
| スクリプト分離 | レビュースクリプトと設定はデフォルトブランチ（base SHA 固定）から取得。PR 側の改竄が効かない |
| read-only サンドボックス | Codex CLI は `-s read-only` で実行。ファイルの読み取りのみ（bash 不要、全スクリプト pwsh） |
| プロンプトインジェクション防止 | PR 内の AGENTS.md 等の指示ファイルは読み込まない |

> **推奨**: 信頼できるコラボレーターのみがアクセスできるプライベートリポジトリでの利用を想定している。不特定多数が PR を送れるパブリックリポジトリでの利用は推奨しない。

## ファイル構成

```
.github/
  workflows/
    codex-review.yml             # ワークフロー定義
  codex-review/
    config.yml                   # プロジェクト設定（オプション）
    review.ps1                   # Codex CLI 実行 + プロンプト構築
    post-review.ps1              # JSON パース + インラインコメント投稿
setup-runner.ps1                 # ランナーセットアップ確認（コピー不要）
```

対象リポジトリにコピーするのは `.github/` 以下のみ。

## 対応環境

| OS | ランナー | 備考 |
|----|---------|------|
| macOS | ✅ | pwsh |
| Linux | ✅ | pwsh |
| Windows | ✅ | pwsh |

## ライセンス

MIT
