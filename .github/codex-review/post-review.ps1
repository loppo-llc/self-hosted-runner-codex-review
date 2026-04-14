#!/usr/bin/env pwsh
# post-review.ps1 — Codex の JSON 出力をパースして PR にインラインコメントを投稿する
$ErrorActionPreference = 'Stop'

$OutputFile = if ($env:CODEX_REVIEW_OUTPUT_FILE) { $env:CODEX_REVIEW_OUTPUT_FILE } else { Join-Path ([System.IO.Path]::GetTempPath()) "codex-review-output.txt" }
$MaxCommentSize = 60000

try {
    # ---------------------------------------------------------------------------
    # 検証
    # ---------------------------------------------------------------------------
    if (-not (Test-Path $OutputFile) -or (Get-Item $OutputFile).Length -eq 0) {
        Write-Host "レビュー出力がありません。スキップします。"
        exit 0
    }

    # ---------------------------------------------------------------------------
    # 過去のレビューコメントを削除
    # ---------------------------------------------------------------------------
    Write-Host "過去のレビューコメントを削除中..."

    # Issue コメント
    $existingComments = gh api --paginate "repos/$($env:REPO)/issues/$($env:PR_NUMBER)/comments" `
        --jq '.[] | select(.body // "" | startswith("<!-- codex-review -->")) | .id' 2>$null
    if ($existingComments) {
        foreach ($cid in ($existingComments -split '\r?\n' | Where-Object { $_ })) {
            gh api --method DELETE "repos/$($env:REPO)/issues/comments/$cid" 2>$null | Out-Null
        }
    }

    # 正式レビューに紐づくインラインコメントを削除
    $existingReviews = gh api --paginate "repos/$($env:REPO)/pulls/$($env:PR_NUMBER)/reviews" `
        --jq '.[] | select(.body // "" | startswith("<!-- codex-review -->")) | .id' 2>$null
    if ($existingReviews) {
        foreach ($rid in ($existingReviews -split '\r?\n' | Where-Object { $_ })) {
            $reviewComments = gh api --paginate "repos/$($env:REPO)/pulls/$($env:PR_NUMBER)/reviews/$rid/comments" `
                --jq '.[].id' 2>$null
            if ($reviewComments) {
                foreach ($rcid in ($reviewComments -split '\r?\n' | Where-Object { $_ })) {
                    gh api --method DELETE "repos/$($env:REPO)/pulls/comments/$rcid" 2>$null | Out-Null
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # JSON パース（スキーマ検証付き）
    # ---------------------------------------------------------------------------
    $rawOutput = Get-Content $OutputFile -Raw -Encoding utf8
    $parsed = $null

    # 生出力をそのまま試す
    try {
        $candidate = $rawOutput | ConvertFrom-Json -ErrorAction Stop
        if ($candidate.PSObject.Properties.Name -contains 'findings' -and $null -ne $candidate.findings -and $candidate.findings -is [array]) {
            $parsed = $candidate
        }
    } catch {}

    # マークダウンのコードフェンスを除去して再試行
    if (-not $parsed -and $rawOutput -match '(?ms)```(?:json)?\s*\r?\n(.+?)\r?\n```') {
        try {
            $candidate = $Matches[1] | ConvertFrom-Json -ErrorAction Stop
            if ($candidate.PSObject.Properties.Name -contains 'findings' -and $null -ne $candidate.findings -and $candidate.findings -is [array]) {
                $parsed = $candidate
            }
        } catch {}
    }

    $shortSha = if ($env:HEAD_SHA -and $env:HEAD_SHA.Length -ge 7) { $env:HEAD_SHA.Substring(0, 7) } else { "unknown" }

    # JSON パース失敗時はプレーンテキストとして投稿
    if (-not $parsed) {
        Write-Host "::warning::JSON パースに失敗しました。プレーンコメントとして投稿します。"
        $truncated = if ($rawOutput.Length -gt $MaxCommentSize) { $rawOutput.Substring(0, $MaxCommentSize) } else { $rawOutput }
        $body = @"
<!-- codex-review -->
## Codex PR Review

$truncated

---
<sub>🤖 Reviewed by Codex CLI (self-hosted) · $shortSha</sub>
"@
        $bodyFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $bodyFile -Value $body -Encoding utf8
            gh pr comment $env:PR_NUMBER --body-file $bodyFile
        } finally {
            Remove-Item $bodyFile -ErrorAction SilentlyContinue
        }
        exit 0
    }

    # ---------------------------------------------------------------------------
    # 指摘事項の集計
    # ---------------------------------------------------------------------------
    $verdict  = if ($parsed.verdict) { $parsed.verdict } else { "UNKNOWN" }
    $summary  = if ($parsed.summary) { $parsed.summary } else { "" }
    $findings = @($parsed.findings)
    $findingCount  = $findings.Count
    $criticalCount = @($findings | Where-Object { $_.severity -eq "CRITICAL" }).Count
    $warningCount  = @($findings | Where-Object { $_.severity -eq "WARNING" }).Count
    $infoCount     = @($findings | Where-Object { $_.severity -eq "INFO" }).Count

    Write-Host "判定: $verdict"
    Write-Host "指摘: $findingCount 件（Critical: $criticalCount, Warning: $warningCount, Info: $infoCount）"

    # ---------------------------------------------------------------------------
    # エラー時の処理
    # ---------------------------------------------------------------------------
    if ($verdict -eq "ERROR") {
        $errorMsg = if ($parsed.error) { $parsed.error } else { "不明なエラー" }
        $codeBlock = '```'
        $body = @"
<!-- codex-review -->
## ⚠️ Codex PR Review — エラー

$summary

$codeBlock
$errorMsg
$codeBlock

---
<sub>🤖 Reviewed by Codex CLI (self-hosted) · $shortSha</sub>
"@
        $bodyFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $bodyFile -Value $body -Encoding utf8
            gh pr comment $env:PR_NUMBER --body-file $bodyFile
        } finally {
            Remove-Item $bodyFile -ErrorAction SilentlyContinue
        }
        exit 0
    }

    # ---------------------------------------------------------------------------
    # ヘッダー構築
    # ---------------------------------------------------------------------------
    $header = "## Codex PR Review"
    if ($criticalCount -gt 0 -or $warningCount -gt 0 -or $infoCount -gt 0) {
        $parts = @()
        if ($criticalCount -gt 0) { $parts += "🔴 $criticalCount critical" }
        if ($warningCount -gt 0)  { $parts += "🟡 $warningCount warning(s)" }
        if ($infoCount -gt 0)     { $parts += "💡 $infoCount info" }
        $header += " — $($parts -join ', ')"
    } else {
        $header += " — ✅ 問題なし"
    }

    # ---------------------------------------------------------------------------
    # diff の取得（インラインコメント用）
    # ---------------------------------------------------------------------------
    $diffBase = if ($env:BASE_SHA) { $env:BASE_SHA } else { "origin/$($env:BASE_REF)" }
    $diffContent = ""

    $null = git merge-base $diffBase HEAD 2>&1
    if ($LASTEXITCODE -eq 0) {
        $diffContent = git diff "${diffBase}...HEAD" 2>&1 | Out-String
    } else {
        Write-Host "::warning::merge-base を解決できません。two-dot diff にフォールバックします。"
        $diffContent = git diff "${diffBase}..HEAD" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "::warning::two-dot diff も失敗しました。インラインコメントは投稿されません。"
            $diffContent = ""
        }
    }

    # ---------------------------------------------------------------------------
    # diff position 算出関数
    # GitHub API の position は diff 本文内の 1 ベースのオフセット
    # ---------------------------------------------------------------------------
    function Get-DiffPosition {
        param([string]$TargetFile, [int]$TargetLine, [string]$DiffText)

        if (-not $DiffText) { return $null }

        $inFile = $false; $inHunk = $false; $position = 0; $currentLine = 0
        $diffPath = "b/$TargetFile"

        foreach ($line in $DiffText -split '\r?\n') {
            if ($line.StartsWith("diff --git ")) {
                if ($line.EndsWith(" $diffPath")) {
                    $inFile = $true; $inHunk = $false; $position = 0
                } elseif ($inFile) {
                    break
                }
            } elseif ($line.StartsWith("@@") -and $inFile) {
                $inHunk = $true
                if ($line -match '\+(\d+)') {
                    $currentLine = [int]$Matches[1] - 1
                }
            } elseif ($line -match '^(index |--- |\+\+\+ )') {
                # ヘッダー行はカウントしない
            } elseif ($inFile -and $inHunk) {
                $position++
                if (-not $line.StartsWith("-")) {
                    $currentLine++
                    if ($currentLine -eq $TargetLine) {
                        return $position
                    }
                }
            }
        }
        return $null
    }

    # ---------------------------------------------------------------------------
    # フォールバックコメント関数
    # ---------------------------------------------------------------------------
    function Post-FallbackComment {
        param([array]$Findings, [string]$BodyText)

        foreach ($f in $Findings) {
            $emoji = switch ($f.severity) { "CRITICAL" { "🔴" } "INFO" { "💡" } default { "🟡" } }
            $fLine = if ($f.line) { [int]$f.line } else { 0 }
            $BodyText += "`n`n$emoji **$($f.severity)** | ``$($f.file):${fLine}`` — $($f.title)`n`n> $($f.body)`n>`n> **修正案**: $($f.suggestion)"
        }

        # GitHub コメント上限対策
        $truncationMsg = "`n`n---`n⚠️ コメントが長すぎるため切り詰めました。"
        $maxBody = $MaxCommentSize - $truncationMsg.Length
        if ($BodyText.Length -gt $MaxCommentSize) {
            $BodyText = $BodyText.Substring(0, $maxBody) + $truncationMsg
        }

        $tmpFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmpFile -Value $BodyText -Encoding utf8
            gh pr comment $env:PR_NUMBER --body-file $tmpFile
        } finally {
            Remove-Item $tmpFile -ErrorAction SilentlyContinue
        }
        Write-Host "フォールバックコメントを投稿しました。"
    }

    # ---------------------------------------------------------------------------
    # インラインコメント付きの正式レビューを投稿
    # ---------------------------------------------------------------------------
    $inlineCount = 0

    if ($findingCount -gt 0) {
        $comments = @()

        foreach ($f in $findings) {
            $fFile     = if ($f.file) { $f.file } else { "" }
            $fLine     = if ($f.line) { [int]$f.line } else { 0 }
            $fSeverity = if ($f.severity) { $f.severity } else { "WARNING" }
            $emoji = switch ($fSeverity) { "CRITICAL" { "🔴" } "INFO" { "💡" } default { "🟡" } }

            $commentBody = @"
$emoji **${fSeverity}**: $($f.title)

$($f.body)

**修正案**: $($f.suggestion)
"@

            if ($fFile -and $fLine -gt 0 -and $diffContent) {
                $pos = Get-DiffPosition -TargetFile $fFile -TargetLine $fLine -DiffText $diffContent
                if ($pos -and $pos -gt 0) {
                    $comments += @{ path = $fFile; position = $pos; body = $commentBody }
                }
            }
        }

        $inlineCount = $comments.Count
        Write-Host "インラインコメント: $inlineCount / $findingCount"

        $reviewBody = @"
<!-- codex-review -->
$header

$summary

---
<sub>🤖 Reviewed by Codex CLI (self-hosted) · $shortSha</sub>
"@

        if ($inlineCount -gt 0) {
            $reviewPayload = @{
                body      = $reviewBody
                commit_id = $env:HEAD_SHA
                event     = "COMMENT"
                comments  = $comments
            } | ConvertTo-Json -Depth 3 -Compress

            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -Path $tmpFile -Value $reviewPayload -Encoding utf8
                $null = gh api --method POST "repos/$($env:REPO)/pulls/$($env:PR_NUMBER)/reviews" --input $tmpFile 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "正式レビュー（インラインコメント $inlineCount 件）を投稿しました。"
                } else {
                    Write-Host "::warning::正式レビューの投稿に失敗。フォールバックコメントを投稿します。"
                    Post-FallbackComment -Findings $findings -BodyText $reviewBody
                }
            } finally {
                Remove-Item $tmpFile -ErrorAction SilentlyContinue
            }
        } else {
            Post-FallbackComment -Findings $findings -BodyText $reviewBody
        }
    } else {
        # 指摘なし — LGTM
        $defaultSummary = if ($summary) { $summary } else { "この差分に重大な問題は見つかりませんでした。" }
        $body = @"
<!-- codex-review -->
$header

✅ $defaultSummary

---
<sub>🤖 Reviewed by Codex CLI (self-hosted) · $shortSha</sub>
"@
        $bodyFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $bodyFile -Value $body -Encoding utf8
            gh pr comment $env:PR_NUMBER --body-file $bodyFile
        } finally {
            Remove-Item $bodyFile -ErrorAction SilentlyContinue
        }
        Write-Host "LGTM コメントを投稿しました。"
    }

    Write-Host ""
    Write-Host "=== PR #$($env:PR_NUMBER) にレビューを投稿しました ==="
    Write-Host "    Critical: $criticalCount | Warning: $warningCount | Info: $infoCount | Inline: $inlineCount"

} finally {
    Remove-Item $OutputFile -ErrorAction SilentlyContinue
}
