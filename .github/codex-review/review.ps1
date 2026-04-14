#!/usr/bin/env pwsh
# review.ps1 — Codex CLI (exec) で PR の差分をレビューする
#
# exec review ではなく exec を使う理由:
# - exec review --base は [PROMPT] と併用不可（排他的引数）
# - exec review のビルトイン出力は Markdown 形式で post-review.ps1 の JSON パーサーと非互換
# - exec なら -o でファイル出力 + カスタムプロンプトで JSON スキーマを強制できる
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 一時ファイル
# ---------------------------------------------------------------------------
$OutputFile = Join-Path ([System.IO.Path]::GetTempPath()) "codex-review-output-$([guid]::NewGuid()).txt"
$PromptFile = Join-Path ([System.IO.Path]::GetTempPath()) "codex-review-prompt-$([guid]::NewGuid()).txt"

# post-review.ps1 と共有するために GITHUB_ENV 経由で渡す
if ($env:GITHUB_ENV) {
    "CODEX_REVIEW_OUTPUT_FILE=$OutputFile" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
} else {
    $env:CODEX_REVIEW_OUTPUT_FILE = $OutputFile
}

try {
    # ---------------------------------------------------------------------------
    # 必須環境変数の検証
    # ---------------------------------------------------------------------------
    if (-not $env:BASE_SHA -and -not $env:BASE_REF) {
        throw "BASE_SHA または BASE_REF のいずれかが必要です"
    }

    # ---------------------------------------------------------------------------
    # 設定読み込み（セキュリティ: デフォルトブランチ側から読む）
    # ---------------------------------------------------------------------------
    $ConfigFile = if ($env:TRUSTED_CONFIG) { $env:TRUSTED_CONFIG } else { ".github/codex-review/config.yml" }
    $ConfigModel = ""
    $ConfigExtraPrompt = ""

    if (Test-Path $ConfigFile) {
        $configContent = Get-Content $ConfigFile -Raw -ErrorAction SilentlyContinue
        if ($configContent -and $configContent -match '(?m)^model:\s*(\S+)') {
            $ConfigModel = $Matches[1]
        }
        if ($configContent -and $configContent -match '(?ms)^extra_prompt:\s*\|\s*\r?\n((?:  .+\r?\n?)+)') {
            $ConfigExtraPrompt = ($Matches[1] -replace '(?m)^  ', '').Trim()
        }
    }

    # ---------------------------------------------------------------------------
    # 基本変数
    # ---------------------------------------------------------------------------
    $base = if ($env:BASE_SHA) { $env:BASE_SHA } else { "origin/$($env:BASE_REF)" }
    $title = if ($env:PR_TITLE) { $env:PR_TITLE } else { "PR Review" }

    # ---------------------------------------------------------------------------
    # レビュープロンプト構築
    # ---------------------------------------------------------------------------
    $prompt = @"
Review the changes between $base and HEAD (git diff ${base}...HEAD).
Report only actionable issues introduced by these changes, not pre-existing problems.

Focus on:
- Correctness: logic errors, off-by-one, null/undefined, race conditions
- Security: injection, auth bypass, secret exposure
- Performance: O(n²) or worse in hot paths, memory leaks
- Maintainability: unreachable code, broken contracts, missing error handling

Do NOT report: style/formatting, pre-existing issues, nit-level suggestions.
"@

    if ($ConfigExtraPrompt) {
        $prompt += "`n`nAdditional project-specific instructions:`n$ConfigExtraPrompt"
    }

    if ($env:PR_TITLE) {
        $prompt += "`n`nPR Title: $($env:PR_TITLE)"
        if ($env:PR_BODY) { $prompt += "`nPR Description: $($env:PR_BODY)" }
    }

    $prompt += @'


Output ONLY valid JSON in this exact format (no markdown fences, no text outside the JSON):
{"findings":[{"severity":"CRITICAL","file":"path/to/file","line":42,"title":"One line summary","body":"Description of the issue and its impact.","suggestion":"Concrete fix suggestion."}],"verdict":"PASS","summary":"One line overall verdict"}

severity levels:
- CRITICAL: Must fix before merge. Bugs, security, data loss.
- WARNING: Should fix. Performance, error handling, maintainability risks.
- INFO: Suggestion. Style, naming, test additions, refactoring.

If no issues found, use empty findings array and verdict PASS.
findings body and suggestion must be in Japanese.
'@

    Set-Content -Path $PromptFile -Value $prompt -Encoding utf8

    # ---------------------------------------------------------------------------
    # Codex CLI 実行
    # ---------------------------------------------------------------------------
    Write-Host "=== Codex PR Review ==="
    Write-Host "Base: $base"
    Write-Host "Head: $(if ($env:HEAD_SHA) { $env:HEAD_SHA } else { 'HEAD' })"
    Write-Host "Model: $(if ($ConfigModel) { $ConfigModel } else { 'default' })"
    Write-Host ""

    # codex exec（exec review ではない）: カスタムプロンプト + -o でファイル出力
    $codexArgs = @(
        '-s', 'read-only'
        'exec'
        '--skip-git-repo-check'
        '-o', $OutputFile
    )
    if ($ConfigModel) { $codexArgs += @('-m', $ConfigModel) }
    # PROMPT='-' は最後（stdin から読む指定）
    $codexArgs += '-'

    $codexFailed = $false
    $codexError = ""

    try {
        # stdin からプロンプトを渡す（-）
        Get-Content $PromptFile -Raw | & codex @codexArgs
        if ($LASTEXITCODE -ne 0) {
            $codexFailed = $true
            $codexError = "Codex CLI が非ゼロ終了コード ($LASTEXITCODE) で終了しました"
        }
    } catch {
        $codexFailed = $true
        $codexError = $_.Exception.Message
    }

    if ($codexFailed) {
        Write-Host "::error::Codex CLI の実行に失敗しました: $codexError"
        @{
            findings = @()
            verdict  = "ERROR"
            summary  = "Codex CLI の実行に失敗しました"
            error    = $codexError
        } | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputFile -Encoding utf8
        exit 1
    }

    # -o でファイルに書き出し済みなので、存在確認だけ
    if (-not (Test-Path $OutputFile) -or (Get-Item $OutputFile).Length -eq 0) {
        Write-Host "::warning::Codex CLI の出力が空です"
        @{
            findings = @()
            verdict  = "ERROR"
            summary  = "Codex CLI の出力が空でした"
            error    = "出力ファイルが空または存在しません"
        } | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputFile -Encoding utf8
        exit 1
    }

    Write-Host ""
    Write-Host "=== レビュー完了 ==="
} catch {
    # 未処理例外（環境変数検証失敗等）
    Write-Host "::error::$($_.Exception.Message)"
    @{
        findings = @()
        verdict  = "ERROR"
        summary  = $_.Exception.Message
        error    = $_.Exception.Message
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputFile -Encoding utf8
    exit 1
} finally {
    Remove-Item -Path $PromptFile -ErrorAction SilentlyContinue
}
