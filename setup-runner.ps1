#!/usr/bin/env pwsh
# setup-runner.ps1 — セルフホストランナーのセットアップ確認ツール
# 対象リポジトリにコピーする必要はない。ランナーマシンで1回だけ実行する。

Write-Host "=== Codex PR Review — ランナーセットアップ ==="
Write-Host ""
Write-Host "OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"

function Test-Tool {
    param([string]$Name, [string]$Command, [string]$InstallHint)

    Write-Host ""
    Write-Host "--- $Name ---"
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "✅ インストール済み"
    } else {
        Write-Host "❌ 未インストール"
        Write-Host "   $InstallHint"
    }
}

Test-Tool "Codex CLI" "codex" `
    "https://github.com/openai/codex#install を参照"

Test-Tool "GitHub CLI (gh)" "gh" `
    "macOS: brew install gh / Windows: winget install GitHub.cli / Linux: https://cli.github.com"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Codex 認証 ---"
if ($env:OPENAI_API_KEY) {
    Write-Host "✅ OPENAI_API_KEY が設定されています（$($env:OPENAI_API_KEY.Length) 文字）"
} elseif (Test-Path (Join-Path $HOME ".codex/config.toml")) {
    Write-Host "✅ Codex 設定ファイルあり（codex login 済みの可能性）"
} else {
    Write-Host "⚠️  OPENAI_API_KEY 未設定、codex 設定ファイルなし"
    Write-Host "   'codex login' を実行するか、OPENAI_API_KEY を環境変数に設定してください"
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== セットアップ確認完了 ==="
Write-Host ""
Write-Host "次のステップ:"
Write-Host "  1. 上記で ❌ のツールをインストール"
Write-Host "  2. 'codex login' で Codex CLI を認証"
Write-Host "  3. GitHub Actions セルフホストランナーを登録:"
Write-Host "     https://docs.github.com/en/actions/hosting-your-own-runners"
Write-Host "  4. ランナーラベルに self-hosted, codex-review を設定"
Write-Host ""
Write-Host "⚠️  セキュリティ注意:"
Write-Host "  信頼できるリポジトリでのみ使用してください。"
Write-Host "  セルフホストランナーは PR のコードをチェックアウトするため、"
Write-Host "  悪意のある PR がランナーマシン上でコードを実行する可能性があります。"
