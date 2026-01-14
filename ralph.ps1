#!/usr/bin/env pwsh
# Ralph Wiggum - Long-running AI agent loop (Windows + Claude Code)
# Usage: .\ralph.ps1 [-ProjectDir <path>] [-MaxIterations <n>]
#
# PowerShell port of ralph.sh for Windows users.
# Uses Claude Code CLI instead of Amp.
#
# IMPORTANT: This script runs Claude Code in the target project directory.
# The project must have:
#   - CLAUDE.md: Instructions for Claude (read automatically by Claude Code)
#   - prd.json: Task definitions with user stories
#
# Claude must output <promise>COMPLETE</promise> when all tasks pass.

param(
    [string]$ProjectDir = ".",
    [int]$MaxIterations = 10
)

$ErrorActionPreference = "Stop"

# Resolve project directory to absolute path
$ProjectDir = Resolve-Path $ProjectDir -ErrorAction Stop

# File paths (all relative to project directory)
$PrdFile = Join-Path $ProjectDir "prd.json"
$ProgressFile = Join-Path $ProjectDir "ralph-progress.txt"
$ArchiveDir = Join-Path $ProjectDir ".ralph-archive"
$LastBranchFile = Join-Path $ProjectDir ".ralph-last-branch"
$PromptFile = Join-Path $ProjectDir "CLAUDE.md"

# Check for required tools
try {
    $null = Get-Command git -ErrorAction Stop
} catch {
    Write-Error "Git not found. Install Git and ensure it's in your PATH."
    exit 1
}

try {
    $null = Get-Command claude -ErrorAction Stop
} catch {
    Write-Error "Claude Code CLI not found. Install from: https://claude.ai/code"
    exit 1
}

# Check for required files
if (-not (Test-Path $PrdFile)) {
    Write-Error "prd.json not found in $ProjectDir. Create it with your task definitions."
    exit 1
}

if (-not (Test-Path $PromptFile)) {
    Write-Error "CLAUDE.md not found in $ProjectDir. This file contains instructions for Claude."
    exit 1
}

# Verify CLAUDE.md contains completion signal instructions
$claudeMdContent = Get-Content $PromptFile -Raw
if ($claudeMdContent -notmatch "<promise>COMPLETE</promise>") {
    Write-Warning "CLAUDE.md does not mention '<promise>COMPLETE</promise>'. Claude may not signal completion correctly."
    Write-Warning "Add instructions telling Claude to output <promise>COMPLETE</promise> when all stories pass."
}

# Archive previous run if branch changed
if ((Test-Path $PrdFile) -and (Test-Path $LastBranchFile)) {
    try {
        $prd = Get-Content $PrdFile -Raw | ConvertFrom-Json
        $currentBranch = $prd.branchName
        $lastBranch = (Get-Content $LastBranchFile -Raw).Trim()

        if ($currentBranch -and $lastBranch -and ($currentBranch -ne $lastBranch)) {
            $date = Get-Date -Format "yyyy-MM-dd"
            $folderName = $lastBranch -replace "^ralph/", ""
            $archiveFolder = Join-Path $ArchiveDir "$date-$folderName"

            Write-Host "Archiving previous run: $lastBranch"
            New-Item -ItemType Directory -Path $archiveFolder -Force | Out-Null
            if (Test-Path $PrdFile) { Copy-Item $PrdFile $archiveFolder }
            if (Test-Path $ProgressFile) { Copy-Item $ProgressFile $archiveFolder }
            Write-Host "   Archived to: $archiveFolder"
        }
    } catch {
        Write-Warning "Could not check branch change: $_"
    }
}

# Track current branch
if (Test-Path $PrdFile) {
    try {
        $prd = Get-Content $PrdFile -Raw | ConvertFrom-Json
        if ($prd.branchName) {
            $prd.branchName | Set-Content $LastBranchFile -NoNewline
        }
    } catch {
        Write-Warning "Could not read PRD: $_"
    }
}

# Initialize or append to progress file
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
if (-not (Test-Path $ProgressFile)) {
    @"
# Ralph Progress Log
Started: $timestamp
Project: $ProjectDir
---

"@ | Set-Content $ProgressFile
} else {
    "`n---`nResumed: $timestamp`n" | Add-Content $ProgressFile
}

Write-Host ""
Write-Host "Starting Ralph (Claude Code)"
Write-Host "  Project: $ProjectDir"
Write-Host "  Max iterations: $MaxIterations"
Write-Host ""

# The prompt sent to Claude each iteration
$iterationPrompt = @"
You are Ralph, an autonomous coding agent. Read these files for context:
- prd.json: User stories and their status
- progress.txt: Learnings from previous iterations (if exists)
- CLAUDE.md: Project-specific instructions

Find the highest-priority user story where passes is false. Implement it fully:
1. Write the code
2. Run quality checks (typecheck, lint, tests)
3. Update progress.txt with what you did and learnings
4. Commit with message format: [STORY-ID] Description
5. Update prd.json to set passes: true

If ALL user stories have passes: true, output exactly: <promise>COMPLETE</promise>
"@

for ($i = 1; $i -le $MaxIterations; $i++) {
    Write-Host ("=" * 60)
    Write-Host "  Ralph Iteration $i of $MaxIterations"
    Write-Host ("=" * 60)
    Write-Host ""

    # Log iteration start (fresh timestamp each iteration)
    $iterationTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$iterationTime] Iteration $i started" | Add-Content $ProgressFile

    # Run Claude Code in the project directory
    # Note: Claude reads CLAUDE.md automatically as project context
    Push-Location $ProjectDir
    try {
        $process = Start-Process -FilePath "claude" `
            -ArgumentList "--dangerously-skip-permissions", "-p", "`"$iterationPrompt`"" `
            -NoNewWindow -Wait -PassThru

        $exitCode = $process.ExitCode

        if ($exitCode -ne 0) {
            $errorMsg = "Claude exited with code $exitCode"
            Write-Warning $errorMsg
            "[$iterationTime] Iteration $i failed: $errorMsg" | Add-Content $ProgressFile
        }
    } catch {
        Write-Warning "Claude Code iteration failed: $_"
        "[$iterationTime] Iteration $i error: $_" | Add-Content $ProgressFile
    } finally {
        Pop-Location
    }

    # Check if all stories are complete by reading prd.json
    try {
        $prd = Get-Content $PrdFile -Raw | ConvertFrom-Json
        $allPassing = $true
        $passCount = 0
        $totalCount = 0

        foreach ($story in $prd.userStories) {
            $totalCount++
            if ($story.passes -eq $true) {
                $passCount++
            } else {
                $allPassing = $false
            }
        }

        Write-Host ""
        Write-Host "Progress: $passCount / $totalCount stories passing"
        "[$iterationTime] Iteration $i complete: $passCount / $totalCount stories passing" | Add-Content $ProgressFile

        if ($allPassing) {
            Write-Host ""
            Write-Host ("=" * 60)
            Write-Host "  Ralph completed all tasks!"
            Write-Host "  Finished at iteration $i of $MaxIterations"
            Write-Host ("=" * 60)
            "[$iterationTime] ALL TASKS COMPLETE" | Add-Content $ProgressFile
            exit 0
        }
    } catch {
        Write-Warning "Could not check completion status: $_"
    }

    Write-Host ""
    Write-Host "Continuing to next iteration..."
    Write-Host ""
}

Write-Host ""
Write-Host ("=" * 60)
Write-Host "  Ralph reached max iterations ($MaxIterations)"
Write-Host "  Not all tasks completed. Check ralph-progress.txt for status."
Write-Host ("=" * 60)
$finalTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"[$finalTime] Reached max iterations without completing all tasks" | Add-Content $ProgressFile
exit 1
