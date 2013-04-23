# Inspired by Mark Embling
# http://www.markembling.info/view/my-ideal-powershell-prompt-with-git-integration

function Get-GitDirectory {
    $gitDir = git rev-parse --git-dir 2>$null
    if ($LastExitCode -ne 0) {
        return
    }
    (Resolve-Path $gitDir).Path
}

function Get-GitWorkingDirectory {
    $cdup = git rev-parse --show-cdup
    if ($LastExitCode -ne 0) {
        return
    }
    if (!$cdup) {
        $cdup = "."
    }
    (Resolve-Path $cdup).Path
}

function Get-GitBranch($gitDir = $(Get-GitDirectory), [Diagnostics.Stopwatch]$sw) {
    if ($gitDir) {
        dbg 'Finding branch' $sw
        $r = ''; $b = ''; $c = ''
        if (Test-Path $gitDir\rebase-merge\interactive) {
            dbg 'Found rebase-merge\interactive' $sw
            $r = '|REBASE-i'
            $b = "$(Get-Content $gitDir\rebase-merge\head-name)"
        } elseif (Test-Path $gitDir\rebase-merge) {
            dbg 'Found rebase-merge' $sw
            $r = '|REBASE-m'
            $b = "$(Get-Content $gitDir\rebase-merge\head-name)"
        } else {
            if (Test-Path $gitDir\rebase-apply) {
                dbg 'Found rebase-apply' $sw
                if (Test-Path $gitDir\rebase-apply\rebasing) {
                    dbg 'Found rebase-apply\rebasing' $sw
                    $r = '|REBASE'
                } elseif (Test-Path $gitDir\rebase-apply\applying) {
                    dbg 'Found rebase-apply\applying' $sw
                    $r = '|AM'
                } else {
                    dbg 'Found rebase-apply' $sw
                    $r = '|AM/REBASE'
                }
            } elseif (Test-Path $gitDir\MERGE_HEAD) {
                dbg 'Found MERGE_HEAD' $sw
                $r = '|MERGING'
            } elseif (Test-Path $gitDir\CHERRY_PICK_HEAD) {
                dbg 'Found CHERRY_PICK_HEAD' $sw
                $r = '|CHERRY-PICKING'
            } elseif (Test-Path $gitDir\BISECT_LOG) {
                dbg 'Found BISECT_LOG' $sw
                $r = '|BISECTING'
            }

            $b = Invoke-NullCoalescing `
                { dbg 'Trying symbolic-ref' $sw; git symbolic-ref HEAD 2>$null } `
                { '({0})' -f (Invoke-NullCoalescing `
                    { dbg 'Trying describe' $sw; git describe --exact-match HEAD 2>$null } `
                    {
                        dbg 'Falling back on parsing HEAD' $sw
                        $ref = $null

                        if (Test-Path $gitDir\HEAD) {
                            dbg 'Reading from .git\HEAD' $sw
                            $ref = Get-Content $gitDir\HEAD 2>$null
                        } else {
                            dbg 'Trying rev-parse' $sw
                            $ref = git rev-parse HEAD 2>$null
                        }

                        if ($ref -match 'ref: (?<ref>.+)') {
                            return $Matches['ref']
                        } elseif ($ref -and $ref.Length -ge 7) {
                            return $ref.Substring(0,7)+'...'
                        } else {
                            return 'unknown'
                        }
                    }
                ) }
        }

        dbg 'Inside git directory?' $sw
        if ('true' -eq $(git rev-parse --is-inside-git-dir 2>$null)) {
            dbg 'Inside git directory' $sw
            if ('true' -eq $(git rev-parse --is-bare-repository 2>$null)) {
                $c = 'BARE:'
            } else {
                $b = 'GIT_DIR!'
            }
        }

        "$c$($b -replace 'refs/heads/','')$r"
    }
}

$Global:GitStatusCache = @{
    GitDirectory = $null
    Status = $null
    Watchers = $null
    Events = "Changed", "Created", "Deleted", "Renamed"
    NextSubscriberId = 0
}

function Get-GitStatus($gitDir = (Get-GitDirectory)) {
    $settings = $Global:GitPromptSettings
    $enabled = (-not $settings) -or $settings.EnablePromptStatus
    if ($enabled -and $gitDir)
    {
        if($settings.Debug) {
            $sw = [Diagnostics.Stopwatch]::StartNew(); Write-Host ''
        } else {
            $sw = $null
        }

        @(Get-Event | ?{ $_.SourceIdentifier -like "GitStatusEvent*" }) |
            Tee-Object -Variable events | Remove-Event

        dbg "Found $($events.Count) status events" $sw
        if ($Global:GitStatusCache.Status `
                -and ($gitDir -eq $Global:GitStatusCache.GitDirectory) `
                -and !(Get-Location).Path.StartsWith($gitDir)) {
            if (!$events) {
                dbg 'Reusing old status' $sw
                return $Global:GitStatusCache.Status
            }
        }

        # Stop listening for changes before running git-status so we don't pick
        # up changes from that command.
        if ($Global:GitStatusCache.Watchers) {
            foreach ($watcher in $Global:GitStatusCache.Watchers) {
                $watcher.Dispose()
            }
            foreach ($event in (Get-EventSubscriber | ?{ $_.SourceIdentifier -like "GitStatusEvent*" })) {
                Unregister-Event $event.SourceIdentifier
            }
        }

        $branch = $null
        $aheadBy = 0
        $behindBy = 0
        $indexAdded = @()
        $indexModified = @()
        $indexDeleted = @()
        $indexUnmerged = @()
        $filesAdded = @()
        $filesModified = @()
        $filesDeleted = @()
        $filesUnmerged = @()

        if($settings.EnableFileStatus -and !$(InDisabledRepository)) {
            dbg 'Getting status' $sw
            $status = git -c color.status=false status --short --branch 2>$null
        } else {
            $status = @()
        }

        dbg 'Parsing status' $sw
        $status | foreach {
            dbg "Status: $_" $sw
            if($_) {
                switch -regex ($_) {
                    '^(?<index>[^#])(?<working>.) (?<path1>.*?)(?: -> (?<path2>.*))?$' {
                        switch ($matches['index']) {
                            'A' { $indexAdded += $matches['path1'] }
                            'M' { $indexModified += $matches['path1'] }
                            'R' { $indexModified += $matches['path1'] }
                            'C' { $indexModified += $matches['path1'] }
                            'D' { $indexDeleted += $matches['path1'] }
                            'U' { $indexUnmerged += $matches['path1'] }
                        }
                        switch ($matches['working']) {
                            '?' { $filesAdded += $matches['path1'] }
                            'A' { $filesAdded += $matches['path1'] }
                            'M' { $filesModified += $matches['path1'] }
                            'D' { $filesDeleted += $matches['path1'] }
                            'U' { $filesUnmerged += $matches['path1'] }
                        }
                    }

                    '^## (?<branch>\S+)(?:\.\.\.(?<upstream>\S+) \[(?:ahead (?<ahead>\d+))?(?:, )?(?:behind (?<behind>\d+))?\])?$' {
                        $branch = $matches['branch']
                        $upstream = $matches['upstream']
                        $aheadBy = [int]$matches['ahead']
                        $behindBy = [int]$matches['behind']
                    }

                    '^## Initial commit on (?<branch>\S+)$' {
                        $branch = $matches['branch']
                    }
                }
            }
        }

        if(!$branch) { $branch = Get-GitBranch $gitDir $sw }
        dbg 'Building status object' $sw
        $indexPaths = $indexAdded + $indexModified + $indexDeleted + $indexUnmerged
        $workingPaths = $filesAdded + $filesModified + $filesDeleted + $filesUnmerged
        $index = New-Object PSObject @(,@($indexPaths | ?{ $_ } | Select -Unique)) |
            Add-Member -PassThru NoteProperty Added    $indexAdded |
            Add-Member -PassThru NoteProperty Modified $indexModified |
            Add-Member -PassThru NoteProperty Deleted  $indexDeleted |
            Add-Member -PassThru NoteProperty Unmerged $indexUnmerged
        $working = New-Object PSObject @(,@($workingPaths | ?{ $_ } | Select -Unique)) |
            Add-Member -PassThru NoteProperty Added    $filesAdded |
            Add-Member -PassThru NoteProperty Modified $filesModified |
            Add-Member -PassThru NoteProperty Deleted  $filesDeleted |
            Add-Member -PassThru NoteProperty Unmerged $filesUnmerged

        $result = New-Object PSObject -Property @{
            GitDir          = $gitDir
            Branch          = $branch
            AheadBy         = $aheadBy
            BehindBy        = $behindBy
            HasIndex        = [bool]$index
            Index           = $index
            HasWorking      = [bool]$working
            Working         = $working
            HasUntracked    = [bool]$filesAdded
        }

        $workingDirectory = Get-GitWorkingDirectory

        if ($workingDirectory.StartsWith($gitDir)) {
            dbg 'Disable cache inside GIT_DIR' $sw
            $Global:GitStatusCache.GitDirectory = $null
            $Global:GitStatusCache.Status = $null
        } else {
            $Global:GitStatusCache.GitDirectory = $gitDir
            $directoriesToWatch = @($workingDirectory)
            # Submodules' .git directories are not contained within their working
            # directory, so we have to watch them separately.
            if ((Split-Path $gitDir) -ne $workingDirectory) {
                $directoriesToWatch += $gitDir
            }
            $Global:GitStatusCache.Watchers = $directoriesToWatch | %{
                dbg "Watching for changes in $_" $sw
                $watcher = New-Object IO.FileSystemWatcher $_ -Property @{
                    IncludeSubdirectories = $true
                    EnableRaisingEvents = $true
                }
                foreach ($event in $Global:GitStatusCache.Events) {
                    $id = $Global:GitStatusCache.NextSubscriberId++
                    Register-ObjectEvent $watcher $event -SourceIdentifier "GitStatusEvent$id"
                }
                $watcher
            }
            $Global:GitStatusCache.Status = $result
        }

        dbg 'Finished' $sw
        if($sw) { $sw.Stop() }
        return $result
    }
}

function InDisabledRepository {
    $currentLocation = Get-Location

    foreach ($repo in $Global:GitPromptSettings.RepositoriesInWhichToDisableFileStatus)
    {
        if ($currentLocation -like "$repo*") {
            return $true
        }
    }

    return $false
}

function Enable-GitColors {
    $env:TERM = 'cygwin'
}

function Get-AliasPattern($exe) {
   $aliases = @($exe) + @(Get-Alias | where { $_.Definition -eq $exe } | select -Exp Name)
   "($($aliases -join '|'))"
}

function setenv($key, $value) {
    [void][Environment]::SetEnvironmentVariable($key, $value, [EnvironmentVariableTarget]::Process)
    Set-TempEnv $key $value
}

function Get-TempEnv($key) {
    $path = Join-Path ($Env:TEMP) ".ssh\$key.env"
    if (Test-Path $path) {
        $value =  Get-Content $path
        [void][Environment]::SetEnvironmentVariable($key, $value, [EnvironmentVariableTarget]::Process)
    }
}

function Set-TempEnv($key, $value) {
    $path = Join-Path ($Env:TEMP) ".ssh\$key.env"
    if ($value -eq $null) {
        if (Test-Path $path) {
            Remove-Item $path
        }
    } else {
        New-Item $path -Force -ItemType File > $null
        $value > $path
    }
}

# Retrieve the current SSH agent PID (or zero). Can be used to determine if there
# is a running agent.
function Get-SshAgent() {
    $agentPid = $Env:SSH_AGENT_PID
    if ($agentPid) {
        $sshAgentProcess = Get-Process -Id $agentPid -ErrorAction SilentlyContinue
        if ($sshAgentProcess -and ($sshAgentProcess.Name -eq 'ssh-agent')) {
            return $agentPid
        } else {
            setenv 'SSH_AGENT_PID', $null
            setenv 'SSH_AUTH_SOCK', $null
        }
    }

    return 0
}

# Loosely based on bash script from http://help.github.com/ssh-key-passphrases/
function Start-SshAgent([switch]$Quiet) {
    [int]$agentPid = Get-SshAgent
    if ($agentPid -gt 0) {
        if (!$Quiet) { Write-Host "ssh-agent is already running (pid $($agentPid))" }
        return
    }

    $sshAgent = Get-Command ssh-agent -TotalCount 1 -ErrorAction SilentlyContinue
    if (!$sshAgent) { Write-Warning 'Could not find ssh-agent'; return }

    & $sshAgent | foreach {
        if($_ -match '(?<key>[^=]+)=(?<value>[^;]+);') {
            setenv $Matches['key'] $Matches['value']
        }
    }

    Add-SshKey
}

function Get-SshPath($File = 'id_rsa')
{
    $home = Resolve-Path (Invoke-NullCoalescing $Env:HOME ~)
    Resolve-Path (Join-Path $home ".ssh\$File") -ErrorAction SilentlyContinue 2> $null
}

# Add a key to the SSH agent
function Add-SshKey() {
    $sshAdd = Get-Command ssh-add -TotalCount 1 -ErrorAction SilentlyContinue
    if (!$sshAdd) { Write-Warning 'Could not find ssh-add'; return }

    if ($args.Count -eq 0) {
        $sshPath = Get-SshPath
        if ($sshPath) { & $sshAdd $sshPath }
    } else {
        foreach ($value in $args) {
            & $sshAdd $value
        }
    }
}

# Stop a running SSH agent
function Stop-SshAgent() {
    [int]$agentPid = Get-SshAgent
    if ($agentPid -gt 0) {
        # Stop agent process
        $proc = Get-Process -Id $agentPid
        if ($proc -ne $null) {
            Stop-Process $agentPid
        }

        setenv 'SSH_AGENT_PID', $null
        setenv 'SSH_AUTH_SOCK', $null
    }
}

function Update-AllBranches($Upstream = 'master', [switch]$Quiet) {
    $head = git rev-parse --abbrev-ref HEAD
    git checkout -q $Upstream
    $branches = (git branch --no-color --no-merged) | where { $_ -notmatch '^\* ' }
    foreach ($line in $branches) {
        $branch = $line.SubString(2)
        if (!$Quiet) { Write-Host "Rebasing $branch onto $Upstream..." }
        git rebase -q $Upstream $branch > $null 2> $null
        if ($LASTEXITCODE) {
            git rebase --abort
            Write-Warning "Rebase failed for $branch"
        }
    }
    git checkout -q $head
}
