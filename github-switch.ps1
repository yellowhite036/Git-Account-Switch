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
    # Initial defaults
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
    
    # Ensure .ssh directory exists
    $sshDir = Split-Path $sshConfigPath
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force }
    if (-not (Test-Path $sshConfigPath)) { New-Item -ItemType File -Path $sshConfigPath -Force }

    $configContent = Get-Content $sshConfigPath -Raw
    $entry = "`nHost $hostAlias`n    HostName github.com`n    User git`n    IdentityFile `"$fullKeyPath`"`n    IdentitiesOnly yes`n"

    if ($configContent -match "Host $hostAlias(\s|$)") {
        # Update existing entry
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
    # Use -o ConnectTimeout to avoid hanging
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
        
        # -a 100 for enhanced security
        ssh-keygen -t ed25519 -a 100 -C "$Email" -f "$fullPath" -N '""'
        
        $pubKey = (Get-Content "$fullPath.pub" -Raw).Trim()
        Write-Host "`nSuccessfully generated key and copied public key to clipboard." -ForegroundColor Green
        $pubKey | Set-Clipboard
        return $true
    }
    return $false
}

# --- Main Switch Logic ---
function Switch-GitAccount {
    param ($ProfileName, $Profiles)
    $selected = $Profiles[$ProfileName]
    
    # Choice: Local or Global
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

    # 2. SSH Agent (V1 fallback/complement)
    $agentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($agentService -and $agentService.Status -eq "Running") {
        ssh-add -D 2>$null
        $fullSSHPath = [System.IO.Path]::GetFullPath($selected.ssh.Replace("~", $env:USERPROFILE))
        if (-not (Test-Path $fullSSHPath)) { New-SSHKey -Path $selected.ssh -Email $selected.email }
        if (Test-Path $fullSSHPath) { ssh-add $fullSSHPath 2>$null }
    }

    # 3. SSH Config Alias (The stable V2 way)
    Update-SSHConfig -ProfileName $ProfileName -SSHPath $selected.ssh

    # 4. Show Result & Verify
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
            # Add Logic
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
            # Delete Logic
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
