# Git Account Switcher for Windows (V2)
# Handles Git config, SSH Config Aliases, and Profile Persistence.

# --- Global Configurations ---
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$profilesPath = Join-Path $scriptDir "github-profiles.json"
$sshConfigPath = Join-Path $env:USERPROFILE ".ssh\config"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Persistence Logic ---
function Get-Profiles {
    if (Test-Path $profilesPath) {
        try {
            return Get-Content $profilesPath | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Host "Warning: Failed to load profiles from JSON. Using defaults." -ForegroundColor Yellow
        }
    }
    return @{
        "personal" = @{ "name" = "personal"; "email" = "personal@gmail.com"; "ssh" = "~/.ssh/id_rsa_personal" }
        "work"     = @{ "name" = "work"; "email" = "worke@gmail.com"; "ssh" = "~/.ssh/id_rsa_work" }
    }
}

function Save-Profiles {
    param($Profiles)
    $Profiles | ConvertTo-Json | Set-Content $profilesPath
}

# --- SSH Config Management ---
function Update-SSHConfig {
    param ($ProfileName, $SSHPath)
    $fullKeyPath = [System.IO.Path]::GetFullPath($SSHPath.Replace("~", $env:USERPROFILE))
    $hostAlias = "github.com-$ProfileName"
    
    $sshDir = Split-Path $sshConfigPath
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force }
    if (-not (Test-Path $sshConfigPath)) { New-Item -ItemType File -Path $sshConfigPath -Force }

    $configContent = Get-Content $sshConfigPath -Raw
    $entry = "`nHost $hostAlias`n    HostName github.com`n    User git`n    IdentityFile `"$fullKeyPath`"`n    IdentitiesOnly yes`n"

    if ($configContent -match "Host $hostAlias(\s|$)") {
        $escapedPath = [regex]::Escape($fullKeyPath)
        if ($configContent -notmatch "IdentityFile\s+`"$escapedPath`"") {
            Write-Host "Note: SSH config entry for $hostAlias exists but may have a different key." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Adding New SSH Config Alias: $hostAlias" -ForegroundColor Cyan
        Add-Content -Path $sshConfigPath -Value $entry
    }
}

# --- Identity Verification ---
function Test-GitHubIdentity {
    param ($HostAlias)
    Write-Host "`nVerifying Identity for $HostAlias..." -ForegroundColor Cyan
    $testResult = ssh -T -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" $HostAlias 2>&1 | Out-String
    if ($testResult -match "Hi (.*)!") {
        $username = $matches[1]
        Write-Host "Verified! You are authenticated as: [$username]" -ForegroundColor Green
    } else {
        Write-Host "Verification Failed. Result:" -ForegroundColor Yellow
        Write-Host $testResult -ForegroundColor Gray
    }
}

# --- Key Generation ---
function New-SSHKey {
    param ($Path, $Email)
    $fullPath = [System.IO.Path]::GetFullPath($Path.Replace("~", $env:USERPROFILE))
    Write-Host "SSH key not found at $fullPath" -ForegroundColor Yellow
    $confirm = Read-Host "Generate new Ed25519 key? (a=100 rounds) (y/n)"
    if ($confirm -eq 'y') {
        $dir = Split-Path $fullPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force }
        ssh-keygen -t ed25519 -a 100 -C "$Email" -f "$fullPath" -N '""'
        $pubKey = (Get-Content "$fullPath.pub" -Raw).Trim()
        Write-Host "`nSuccessfully generated key and copied public key to clipboard." -ForegroundColor Green
        $pubKey | Set-Clipboard
        return $true
    }
    return $false
}

# --- Update Remote URLs in a Repo ---
function Update-RepoRemotes {
    param ($RepoDir, $ProfileName)
    $prevLocation = Get-Location
    Set-Location $RepoDir
    $remotes = git remote 2>$null
    $updated = 0
    foreach ($remote in $remotes) {
        $currentUrl = git remote get-url $remote 2>$null
        if ($currentUrl -match "https://github\.com/(.+)" -or $currentUrl -match "git@github\.com:(.+)") {
            $repoPath = $matches[1]
            $newUrl = "git@github.com-" + $ProfileName + ":" + $repoPath
            git remote set-url $remote $newUrl
            Write-Host "  [Updated] $remote" -ForegroundColor Green
            Write-Host "    Before: $currentUrl" -ForegroundColor Gray
            Write-Host "    After:  $newUrl" -ForegroundColor Cyan
            $updated++
        }
    }
    Set-Location $prevLocation
    return $updated
}

# --- Main Switch Logic ---
function Switch-GitAccount {
    param ($ProfileName, $Profiles)
    $selected = $Profiles[$ProfileName]
    
    Write-Host "`nSwitching to [$ProfileName] ($($selected.email))" -ForegroundColor Magenta
    $scopeChoice = Read-Host "Apply to: (1) Global (Full PC)  (2) Local (Current Repo only)"
    $scope = if ($scopeChoice -eq "2") { "--local" } else { "--global" }

    if ($scope -eq "--local" -and -not (git rev-parse --is-inside-work-tree 2>$null)) {
        Write-Host "Error: Not inside a Git repository. Cannot apply local config." -ForegroundColor Red
        return
    }

    # 1. Git Config
    git config $scope user.name $selected.name
    git config $scope user.email $selected.email

    # 2. SSH Agent
    $agentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($agentService -and $agentService.Status -eq "Running") {
        ssh-add -D 2>$null
        $fullSSHPath = [System.IO.Path]::GetFullPath($selected.ssh.Replace("~", $env:USERPROFILE))
        if (-not (Test-Path $fullSSHPath)) { New-SSHKey -Path $selected.ssh -Email $selected.email }
        if (Test-Path $fullSSHPath) { ssh-add $fullSSHPath 2>$null }
    }

    # 3. SSH Config Alias
    Update-SSHConfig -ProfileName $ProfileName -SSHPath $selected.ssh

    # 4. Remote URL Update
    Write-Host "`n[Remote URL Update]" -ForegroundColor Cyan
    Write-Host "Enter the repo path(s) to update remote URLs to SSH alias." -ForegroundColor White
    Write-Host "  - Separate multiple paths with ';'" -ForegroundColor Gray
    Write-Host "  - You can drag & drop a folder into this window" -ForegroundColor Gray
    Write-Host "  - Press Enter to skip" -ForegroundColor Gray
    $repoPaths = Read-Host "Repo path(s)"

    if (-not [string]::IsNullOrWhiteSpace($repoPaths)) {
        $paths = $repoPaths -split ";" | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
        foreach ($repoDir in $paths) {
            if (Test-Path $repoDir) {
                $prevLocation = Get-Location
                Set-Location $repoDir
                if (git rev-parse --is-inside-work-tree 2>$null) {
                    Write-Host "`nRepo: $repoDir" -ForegroundColor Yellow
                    $count = Update-RepoRemotes -RepoDir $repoDir -ProfileName $ProfileName
                    if ($count -eq 0) {
                        Write-Host "  No remotes needed updating." -ForegroundColor Gray
                    }
                } else {
                    Write-Host "  Not a Git repository: $repoDir" -ForegroundColor Red
                }
                Set-Location $prevLocation
            } else {
                Write-Host "  Path not found: $repoDir" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  Skipped remote URL update." -ForegroundColor Gray
    }

    # 5. Show Result
    Write-Host "`nSettings Applied ($scope):" -ForegroundColor Green
    Write-Host "  Name:  $($selected.name)"
    Write-Host "  Email: $($selected.email)"
    Write-Host "  SSH Alias: github.com-$ProfileName" -ForegroundColor Gray
    
    Test-GitHubIdentity -HostAlias "github.com-$ProfileName"
    
    Write-Host "`n[Note] For new clones, use the alias:" -ForegroundColor Cyan
    Write-Host "git clone git@github.com-$ProfileName:user/repo.git" -ForegroundColor White
}

# --- Status Check ---
function Show-CurrentStatus {
    Write-Host "`n=== Current Git & SSH Status ===" -ForegroundColor Cyan
    
    Write-Host "[Local Config] (Current Repo)" -ForegroundColor Yellow
    if (git rev-parse --is-inside-work-tree 2>$null) {
        Write-Host "  Name:  $(git config --local user.name)"
        Write-Host "  Email: $(git config --local user.email)"
    } else {
        Write-Host "  (Not inside a Git repository)" -ForegroundColor Gray
    }

    Write-Host "`n[Global Config] (System Wide)" -ForegroundColor Yellow
    Write-Host "  Name:  $(git config --global user.name)"
    Write-Host "  Email: $(git config --global user.email)"

    Write-Host "`n[Effective Config] (What Git uses now)" -ForegroundColor Yellow
    Write-Host "  Name:  $(git config user.name)"
    Write-Host "  Email: $(git config user.email)"

    Write-Host "`n[SSH Identity] (Default: github.com)" -ForegroundColor Yellow
    $testResult = ssh -T -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" git@github.com 2>&1 | Out-String
    Write-Host "  $($testResult.Trim())" -ForegroundColor White

    Write-Host "`n[Active Identities in Agent]" -ForegroundColor Yellow
    ssh-add -l 2>$null | ForEach-Object { Write-Host "  $_" }
}

# --- Program Entry ---
$allProfiles = Get-Profiles

if ($args.Count -eq 0) {
    while ($true) {
        Clear-Host
        Write-Host "=== Git Account Switcher V2 ===" -ForegroundColor Cyan
        $i = 1
        $keys = $allProfiles.Keys | Sort-Object
        foreach ($k in $keys) {
            Write-Host "$i. $k ($($allProfiles[$k].email))"
            $i++
        }
        Write-Host "$i. [ADD NEW PROFILE]"
        Write-Host "$($i+1). [DELETE PROFILE]"
        Write-Host "$($i+2). [CHECK CURRENT STATUS]"
        Write-Host "$($i+3). [EXIT]"
        
        $choice = Read-Host "`nSelect (Number or Name)"
        
        if ($choice -eq ($i+3)) { break }
        
        if ($choice -eq $i) {
            $newName = Read-Host "Profile Label (e.g. freelance)"
            $userName = Read-Host "Git user.name"
            $userEmail = Read-Host "Git user.email"
            $sshPath = Read-Host "SSH Key Path (Default: ~/.ssh/id_ed25519_$newName)"
            if ([string]::IsNullOrWhiteSpace($sshPath)) { $sshPath = "~/.ssh/id_ed25519_$newName" }
            
            $allProfiles[$newName] = @{ "name" = $userName; "email" = $userEmail; "ssh" = $sshPath }
            Save-Profiles -Profiles $allProfiles
            Switch-GitAccount -ProfileName $newName -Profiles $allProfiles
            Read-Host "`nDone. Press Enter to return to menu..."
        } elseif ($choice -eq ($i+1)) {
            $target = Read-Host "Enter Profile Name or Number to DELETE"
            $deleteKey = $null
            if ($target -match '^\d+$' -and [int]$target -le $keys.Count) {
                $deleteKey = $keys[[int]$target-1]
            } elseif ($allProfiles.ContainsKey($target)) {
                $deleteKey = $target
            }

            if ($deleteKey) {
                $confirm = Read-Host "Are you sure you want to delete profile '$deleteKey'? (y/n)"
                if ($confirm -eq 'y') {
                    $allProfiles.Remove($deleteKey)
                    Save-Profiles -Profiles $allProfiles
                    Write-Host "Profile '$deleteKey' deleted." -ForegroundColor Green
                }
            } else {
                Write-Host "Profile not found." -ForegroundColor Red
            }
            Read-Host "`nPress Enter to return to menu..."
        } elseif ($choice -eq ($i+2)) {
            Show-CurrentStatus
            Read-Host "`nPress Enter to return to menu..."
        } elseif ($choice -match '^\d+$' -and [int]$choice -le $keys.Count) {
            Switch-GitAccount -ProfileName $keys[[int]$choice-1] -Profiles $allProfiles
            Read-Host "`nDone. Press Enter to return to menu..."
        } elseif ($allProfiles.ContainsKey($choice)) {
            Switch-GitAccount -ProfileName $choice -Profiles $allProfiles
            Read-Host "`nDone. Press Enter to return to menu..."
        }
    }
} else {
    if ($allProfiles.ContainsKey($args[0])) {
        Switch-GitAccount -ProfileName $args[0] -Profiles $allProfiles
    } else {
        Write-Host "Profile '$($args[0])' not found." -ForegroundColor Red
    }
}