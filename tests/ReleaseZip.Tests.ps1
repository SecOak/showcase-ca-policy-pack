#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
<#
.SYNOPSIS
    Tests tools\New-ReleaseZip.ps1.
.DESCRIPTION
    Dot-sources the script itself after mocking git, pwsh, and Invoke-ScriptAnalyzer, against a
    small, self-contained copy of the repository shape the script expects, built fresh under
    TestDrive for every test. Covers the version-versus-CHANGELOG.md check, the
    version-versus-tag check, a dirty working tree failing preflight, -DryRun writing nothing,
    and that a real build writes a zip that never contains an excluded path and a
    SHA256SUMS.txt that matches every file actually included.

    The git and pwsh mocks read from $script:-scoped variables (GitBranch, GitTags,
    GitDirtyStatusLines) that each test sets before dot-sourcing the script under test,
    rather than from parameters on a wrapper function: Pester invokes a mocked command's
    scriptblock outside the lexical scope of whatever function registered it, so a closure
    over that function's own parameters silently loses them, while script-scoped variables
    are always reachable.

    The script under test resolves its own repository root from $PSScriptRoot (its own file
    location), not from git or the current directory, so every test dot-sources a copy of the
    real script placed inside the TestDrive fixture's own tools\ folder, never the real
    repository's copy; dot-sourcing the real repository's script would make $PSScriptRoot (and
    so the resolved repository root) point at the real repository instead of the fixture.
.NOTES
    Author: Sec Oak
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RealScriptPath = Join-Path $script:RepoRoot 'tools\New-ReleaseZip.ps1'

    # Builds a minimal, self-contained copy of the repository shape New-ReleaseZip.ps1
    # expects, under TestDrive, so tests exercise the real file-collection and zip-building
    # logic without touching the real repository or its real dist folder. Deliberately
    # includes a file under every path the script promises to exclude (tests\, tools\,
    # .github\, a CaBaseline-* folder), so the exclusion tests fail loudly if the allow list
    # in the script ever regresses into an exclude list that misses one of them.
    function New-CaPackReleaseTestRepo {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        foreach ($folder in 'src', 'templates', 'schema', 'tests', 'tools', '.github', 'CaBaseline-20260101-0000') {
            New-Item -ItemType Directory -Path (Join-Path $Path $folder) -Force | Out-Null
        }

        Set-Content -Path (Join-Path $Path 'Import-CaPolicyPack.ps1') -Value '# import' -NoNewline
        Set-Content -Path (Join-Path $Path 'Export-CaBaseline.ps1') -Value '# export' -NoNewline
        Set-Content -Path (Join-Path $Path 'Compare-CaBaseline.ps1') -Value '# compare' -NoNewline
        Set-Content -Path (Join-Path $Path 'src\CaPack.Common.ps1') -Value '# common' -NoNewline
        Set-Content -Path (Join-Path $Path 'templates\CA001.json') -Value '{"id":"CA001"}' -NoNewline
        Set-Content -Path (Join-Path $Path 'templates\CA002.json') -Value '{"id":"CA002"}' -NoNewline
        Set-Content -Path (Join-Path $Path 'manifest.json') -Value '{"schemaVersion":"1.0"}' -NoNewline
        Set-Content -Path (Join-Path $Path 'schema\conditionalAccessTemplate.schema.json') -Value '{}' -NoNewline
        Set-Content -Path (Join-Path $Path 'README.md') -Value '# Readme' -NoNewline
        Set-Content -Path (Join-Path $Path 'DEPLOYMENT-ORDER.md') -Value '# Deployment order' -NoNewline
        Set-Content -Path (Join-Path $Path 'CHANGELOG.md') -Value "# Changelog`n`n## [1.0.0] - 2026-10-01`n`n- First release.`n" -NoNewline
        Set-Content -Path (Join-Path $Path 'LICENSE.md') -Value 'Draft licence.' -NoNewline

        # Must never appear in a built zip.
        Set-Content -Path (Join-Path $Path 'tests\ReleaseZip.Tests.ps1') -Value '# a test file' -NoNewline
        # A real copy of the script under test, not placeholder text: the script resolves its
        # own repository root from $PSScriptRoot, so dot-sourcing a copy that lives inside
        # this fixture's own tools\ folder is what makes it resolve this fixture as the
        # repository root instead of the real repository.
        Copy-Item -Path $script:RealScriptPath -Destination (Join-Path $Path 'tools\New-ReleaseZip.ps1') -Force
        Set-Content -Path (Join-Path $Path '.github\workflow.yml') -Value 'name: ci' -NoNewline
        Set-Content -Path (Join-Path $Path '.gitignore') -Value 'dist/' -NoNewline
        Set-Content -Path (Join-Path $Path 'CaBaseline-20260101-0000\export.json') -Value '{}' -NoNewline
    }
}

Describe 'New-ReleaseZip.ps1' {

    BeforeEach {
        $script:TestRepoRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-CaPackReleaseTestRepo -Path $script:TestRepoRoot
        $script:ScriptPath = Join-Path $script:TestRepoRoot 'tools\New-ReleaseZip.ps1'
        $script:OutputPath = Join-Path $script:TestRepoRoot 'dist'

        $script:GitBranch = 'main'
        $script:GitTags = @()
        $script:GitDirtyStatusLines = @()

        Mock Invoke-ScriptAnalyzer { @() }

        # A single switch over the exact argument shapes New-ReleaseZip.ps1 calls
        # (is-inside-work-tree, status --porcelain, abbrev-ref HEAD, tag --list, rev-parse
        # --short HEAD), every one of them prefixed with "-C <repoRoot>" by the script; each
        # test sets the $script:Git* variables above before dot-sourcing the script under test.
        Mock git {
            $joined = $args -join ' '
            switch -Regex ($joined) {
                'is-inside-work-tree' { return 'true' }
                'status --porcelain' { return $script:GitDirtyStatusLines }
                'rev-parse --abbrev-ref HEAD' { return $script:GitBranch }
                'tag --list' { return $script:GitTags }
                'rev-parse --short HEAD' { return 'abc1234' }
                default { return $null }
            }
        }

        # Simulates "Pester passed in the fresh process" without spawning a real child
        # pwsh. Exits via a genuine tiny external process (cmd.exe) rather than assigning
        # $LASTEXITCODE directly, so the mock behaves exactly like a real external command.
        Mock pwsh {
            & $env:ComSpec /c exit 0
        }
    }

    Context 'version versus CHANGELOG.md' {
        It 'throws when -Version does not match the newest CHANGELOG.md heading' {
            { . $script:ScriptPath -Version '9.9.9' -OutputPath $script:OutputPath } |
                Should -Throw '*CHANGELOG.md*'
        }

        It 'passes preflight when -Version matches the newest CHANGELOG.md heading' {
            $result = . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath -DryRun
            $result.Created | Should -BeFalse
        }
    }

    Context 'version versus existing tags' {
        It 'throws when -Version does not exceed an existing tag (git tag mocked)' {
            $script:GitTags = @('v1.0.0')

            { . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath } |
                Should -Throw '*exceed*'
        }

        It 'passes when -Version exceeds every existing tag (git tag mocked)' {
            $script:GitTags = @('v0.9.0')

            $result = . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath -DryRun
            $result.Created | Should -BeFalse
            $result.SuggestedTag | Should -Be 'v1.0.0'
        }
    }

    Context 'dirty working tree' {
        It 'throws when the working tree has uncommitted changes' {
            $script:GitDirtyStatusLines = @(' M README.md')

            { . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath } |
                Should -Throw '*uncommitted*'
        }
    }

    Context 'repository root resolution' {
        It 'resolves the repository root from the script location, not the current folder' {
            $unrelatedFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $unrelatedFolder -Force | Out-Null

            Push-Location -Path $unrelatedFolder
            try {
                $result = . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath -DryRun
            }
            finally {
                Pop-Location
            }

            $result.RepoRoot | Should -Be ([System.IO.Path]::GetFullPath($script:TestRepoRoot))
        }
    }

    Context 'DRAFT markers' {
        It 'throws when a shipped document still contains DRAFT' {
            Set-Content -Path (Join-Path $script:TestRepoRoot 'README.md') -Value '# Readme (DRAFT)' -NoNewline

            { . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath } |
                Should -Throw '*DRAFT*'
        }


        It 'reports the same failure under -DryRun' {
            Set-Content -Path (Join-Path $script:TestRepoRoot 'LICENSE.md') -Value 'DRAFT licence text.' -NoNewline

            { . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath -DryRun } |
                Should -Throw '*DRAFT*'
        }

        It 'does not flag the lowercase word draft' {
            Set-Content -Path (Join-Path $script:TestRepoRoot 'README.md') -Value '# Readme (a draft idea, not the marker)' -NoNewline

            $result = . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath -DryRun
            $result.Created | Should -BeFalse
        }
    }

    Context '-DryRun' {
        It 'creates no zip and no dist folder' {
            $result = . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath -DryRun

            $result.Created | Should -BeFalse
            $result.Sha256 | Should -BeNullOrEmpty
            Test-Path -Path $script:OutputPath | Should -BeFalse
        }
    }

    Context 'the built zip' {
        BeforeEach {
            $script:Result = . $script:ScriptPath -Version '1.0.0' -OutputPath $script:OutputPath
        }

        It 'reports Created and a zip file that exists' {
            $script:Result.Created | Should -BeTrue
            Test-Path -Path $script:Result.ZipPath | Should -BeTrue
        }

        It 'never includes an excluded path' {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($script:Result.ZipPath)
            try {
                $entryNames = @($zip.Entries.FullName)
            }
            finally {
                $zip.Dispose()
            }

            $entryNames.Count | Should -BeGreaterThan 0
            foreach ($entry in $entryNames) {
                $entry | Should -Not -Match '(^|/)(tests|tools|\.github|dist)(/|$)'
                $entry | Should -Not -Match '(^|/)CaBaseline-'
                $entry | Should -Not -Match '(^|/)\.git'
            }
        }

        It 'writes a SHA256SUMS.txt that matches every other file in the zip' {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($script:Result.ZipPath)
            try {
                $sumsEntry = $zip.GetEntry('SHA256SUMS.txt')
                $sumsEntry | Should -Not -BeNullOrEmpty

                $reader = [System.IO.StreamReader]::new($sumsEntry.Open())
                try {
                    $sumsContent = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }

                $expectedHashes = @{}
                foreach ($line in ($sumsContent -split "`n" | Where-Object { $_ })) {
                    $parts = $line -split '  ', 2
                    $expectedHashes[$parts[1].Trim()] = $parts[0].Trim()
                }

                $otherEntries = @($zip.Entries | Where-Object { $_.FullName -ne 'SHA256SUMS.txt' })
                $expectedHashes.Count | Should -Be $otherEntries.Count

                foreach ($entry in $otherEntries) {
                    $expectedHashes.ContainsKey($entry.FullName) | Should -BeTrue -Because "SHA256SUMS.txt should list $($entry.FullName)"

                    $memoryStream = [System.IO.MemoryStream]::new()
                    try {
                        $entryStream = $entry.Open()
                        try {
                            $entryStream.CopyTo($memoryStream)
                        }
                        finally {
                            $entryStream.Dispose()
                        }
                        $memoryStream.Position = 0
                        $actualHash = (Get-FileHash -InputStream $memoryStream -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                    finally {
                        $memoryStream.Dispose()
                    }

                    $actualHash | Should -Be $expectedHashes[$entry.FullName]
                }
            }
            finally {
                $zip.Dispose()
            }
        }

        It 'writes a .sha256 sidecar file matching the returned hash of the zip itself' {
            $sidecarPath = "$($script:Result.ZipPath).sha256"
            Test-Path -Path $sidecarPath | Should -BeTrue

            $sidecarContent = (Get-Content -Path $sidecarPath -Raw).Trim()
            $sidecarContent | Should -Match ([regex]::Escape($script:Result.Sha256))

            $actualZipHash = (Get-FileHash -Path $script:Result.ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $script:Result.Sha256 | Should -Be $actualZipHash
        }
    }
}
