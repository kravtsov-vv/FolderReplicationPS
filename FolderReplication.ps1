<#
.SYNOPSIS
FolderReplication.ps1

.DESCRIPTION
Test task. This script performs one-way synchronization to create a fully identical copy of the source folder's contents in the replica folder. 
It includes:
- Copying files and folders from the source
- Verifying file integrity by comparing hashes
- Replicating file and folder attributes
- Copying NTFS permissions (if enabled)

.PARAMETERS 
-SourcePath
Specifies the path to the source folder.
-ReplicaPath
Specifies the path to the replica folder.
-LogFilePath
Specifies the path to the log file.
If only a folder is provided, the default log file name is 'FolderReplication.log'.
If left empty, operations will be logged to the console only.
-VerboseLog
Include in log additional info about Attributes /NTFS permissions replication
-MaxRetries
Specifies the number of retry attempts for copying an item.
Default: 5
-NTFSPermissions
If set, NTFS permissions will also be replicated.
-PauseAtEnd
If set, wait until 'Enter' keypressed at the end

.NOTES
Version:          1.0
Author:           Viktor Kravtsov
Creation Date:    2025-08-04
Purpose/Change:   Initial script development

.EXAMPLE
.\FolderReplication.ps1 -SourcePath "c:\TEMP\sources\" -ReplicaPath "\\localhost\d$\TEMP\replica" -LogFilePath 'c:\TEMP\' -MaxRetries 3 -NTFSPermissions
.\FolderReplication.ps1 -SourcePath "C:\TEMP\qweqwe\source" -ReplicaPath "C:\TEMP\qweqwe\replica" -LogFilePath 'c:\TEMP\qweqwe' -PauseAtEnd

#>

Param (
    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath = "C:\TEMP\qweqwe\source",

    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string]$ReplicaPath = "C:\TEMP\qweqwe\replica",

    [Parameter(Mandatory = $True)]
    [string]$LogFilePath = "C:\TEMP\qweqwe\",

    [Parameter(Mandatory = $False)]
    [ValidateNotNullOrEmpty()]
    [int]$MaxRetries = 5,

    [Parameter(Mandatory = $False)]
    [switch]$NTFSPermissions,

    [Parameter(Mandatory = $False)]
    [switch]$PauseAtEnd,

    [Parameter(Mandatory = $False)]
    [switch]$VerboseLog

)

function WriteLog {
    param(
        [string]$Message,
        [string]$Type = "Info"  # Info, Error, Warning, Success
    )
    $msg = ((Get-Date -Format "yyyy-MM-dd HH:mm:ss K") + "(UTC) : [$Type]   : $Message")
    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        Add-Content -Path $LogFilePath -Value $msg
    }
    switch ($Type) {
        "Error" { Write-Host $msg -ForegroundColor Red }
        "Warning" { Write-Host $msg -ForegroundColor Yellow }
        "Success" { Write-Host $msg -ForegroundColor Green }
        default { Write-Host $msg -ForegroundColor White }
    }
}

function ReplicateFolder {
    # Validate source and replica paths are not the same
    if ($SourcePath.TrimEnd('\') -ieq $ReplicaPath.TrimEnd('\')) {
        WriteLog "Source and replica paths must not be the same. Script terminated." "Error"
        $global:N_err++
        return
    }

    # check source 
    if (!(Test-Path -LiteralPath $SourcePath)) {
        WriteLog "Source path does not exist: $SourcePath. Script terminated." "Error"
        $global:N_err++
        return
    }

    # check replica
    if (Test-Path -LiteralPath $ReplicaPath) {
        WriteLog "Replica directory exist: $ReplicaPath" "Info"
        # replica cleanup
        Get-ChildItem -Path $ReplicaPath -Recurse -Force | ForEach-Object {
            try {
                If ($_.PSIsContainer) { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) }
                else { $_.IsReadOnly = $false }
                Remove-Item -Path $_.FullName -Recurse -Force
                WriteLog "Replica folder cleanup, deleted : $($_.FullName)" "Info"
            } catch {
                WriteLog "Failed to delete: $($_.FullName) - $($_.Exception.Message)" "Warning"
                $global:N_wrn++
            }
        }
    }
    else {
        WriteLog "Replica directory doesnt exist: $ReplicaPath, creating..." "Info" 
        New-Item -ItemType Directory -Path $ReplicaPath | Out-Null
        if (Test-Path -LiteralPath $ReplicaPath) { WriteLog "Created replica directory: $ReplicaPath" "Info" }
        else {
            WriteLog "Replica directory creating failed: $ReplicaPath. Script terminated." "Error"
            $global:N_err++
            return
        }    
    }

    WriteLog "Content copying started" "Info"

    $paths = @()
    Get-ChildItem -Path $SourcePath -Recurse -Force | ForEach-Object {
        $item = $_
        try {
            $relativePath = $item.FullName.Substring($SourcePath.Length).TrimStart('\')
            $targetPath = Join-Path $ReplicaPath $relativePath

            if ($item.PSIsContainer) {
                if (!(Test-Path -Path $targetPath)) { New-Item -ItemType Directory -Path $targetPath -Force | Out-Null }
                $paths += [PSCustomObject]@{
                    sourcepath = $item.FullName
                    targetpath = $targetPath
                }
            }
            else {
                $success = $false
                $attempt = 0
                while (-not $success -and $attempt -lt $MaxRetries) {
                    try {
                        Copy-Item -Path $item.FullName -Destination $targetPath -Force

                        $srcHash = Get-FileHash $item.FullName
                        $rplcHash = Get-FileHash $targetPath

                        if ($srcHash.Hash -eq $rplcHash.Hash) {
                            WriteLog "Copied and verified  : $($item.FullName) -> $targetPath" "Info"
                            $success = $true
                            ReplicateAttributes -src $item -dst $targetPath
                        }
                        else {
                            Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 4)
                            Remove-Item -Path $targetPath -Recurse -Force
                            WriteLog "HASH MISMATCH (Attempt $($attempt + 1)): $($item.FullName), replica deleted" "Warning"
                            $global:N_wrn++
                        }
                    }
                    catch {
                        WriteLog "ERROR copying (Attempt $($attempt + 1)): $($item.FullName) - $($_.Exception.Message)" "Error"
                        $global:N_err++
                    }
                    $attempt++

                }

                if (-not $success) {
                    WriteLog "FAILED after $MaxRetries attempts: $($item.FullName)" "Error"
                    $global:N_err++
                }
            }
        }
        catch {
            WriteLog "ERROR processing item: $($item.FullName) - $($_.Exception.Message)" "Error"
            $global:N_err++
        }
    }
    foreach ($path in $paths) {
        try {
            get-item $path.sourcepath -Force | ReplicateAttributes -dst $path.targetpath
        } catch {
            WriteLog "ERROR replicating attributes for: $($path.sourcepath) - $($_.Exception.Message)" "Warning"
            $global:N_wrn++
        }
    }

    WriteLog "Copy and verification completed" "Info"
}

function ReplicateAttributes {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true)]
        [PSCustomObject]$src,
        [string]$dst
    )

    try {
        $ro_Attr = $false
        $dstObj = Get-Item $dst -Force
        if ($src.PSIsContainer) {
            if ($src.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                $ro_Attr = $true
                $dstObj.Attributes = $dstObj.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            }

            $dstObj.CreationTime = $src.CreationTime
            $dstObj.LastWriteTime = $src.LastWriteTime
            $dstObj.LastAccessTime = $src.LastAccessTime
            $dstObj.Attributes = $src.Attributes   

            if ($ro_Attr) { $dstObj.Attributes = $dstObj.Attributes -bor [System.IO.FileAttributes]::ReadOnly }
        } 
        else {
            if ($src.IsReadOnly) {
                $ro_Attr = $true
                $dstObj.IsReadOnly = $false
            }
            $dstObj.CreationTime = $src.CreationTime
            $dstObj.LastWriteTime = $src.LastWriteTime
            $dstObj.LastAccessTime = $src.LastAccessTime
            if ($ro_Attr) { $dstObj.IsReadOnly = $true }
        }
        if ($VerboseLog) {WriteLog "Attributes replicated: $($src.FullName) -> $($dstObj.FullName)" "Info"}
        if ($NTFSPermissions) {
            try {
                $acl = Get-Acl $src.Fullname
                Set-Acl -Path $dstObj.Fullname -AclObject $acl
            if ($VerboseLog) {WriteLog "NTFS permissions replicated: $($src.FullName) -> $($dstObj.FullName)" "Info"}
            } catch {
                WriteLog "ERROR setting NTFS permissions: $($src.FullName) - $($_.Exception.Message)" "Warning"
                $global:N_wrn++
            }
        }
    }
    catch {
        WriteLog "ERROR attribs replication: $($src.FullName) - $($_.Exception.Message)" "Warning"
        $global:N_wrn++
    }
}

############# SET LOGS ########################################

if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
    # If LogFilePath is an existing directory
    if ((Test-Path $LogFilePath) -and ((Get-Item $LogFilePath).PSIsContainer)) {
        $LogFilePath = Join-Path $LogFilePath 'FolderReplication.log'
        if (-not (Test-Path $LogFilePath)) {
            New-Item -ItemType File -Path $LogFilePath | Out-Null
        }
    }
    # If LogFilePath is an non-existing directory
    elseif ($LogFilePath -notlike "*.*") {
        New-Item -ItemType Directory -Path $LogFilePath | Out-Null
        $LogFilePath = Join-Path $LogFilePath 'FolderReplication.log'
        if (-not (Test-Path $LogFilePath)) {
            New-Item -ItemType File -Path $LogFilePath | Out-Null
        }
    }
    # If LogFilePath looks like a file, ensure it exists
    elseif (-not (Test-Path $LogFilePath)) {
        $FolderPath = Split-Path $LogFilePath
        if (-not (Test-Path $FolderPath)) {New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null}
        New-Item -ItemType File -Path $LogFilePath | Out-Null
        }
    
}

############# MAIN EXECUTION ##################################

try {
    Clear-Host
    $global:N_err = 0
    $global:N_wrn = 0

    WriteLog "$env:COMPUTERNAME/$env:USERNAME" "Info"
    WriteLog "Source path: $SourcePath" "Info"
    WriteLog "Target path: $ReplicaPath" "Info"
    WriteLog "Log file: $LogFilePath" "Info"
    WriteLog "Verbose Logging: $VerboseLog" "Info"
    WriteLog "Max attempts to copy content: $MaxRetries" "Info"
    WriteLog "Copy NTFS permissions: $NTFSPermissions" "Info"
    WriteLog "Pause at the end: $PauseAtEnd" "Info"
    
    WriteLog "========================START========================" "Info"

    ReplicateFolder

    if (($N_err -eq 0) -and ($N_wrn -eq 0)) {
        WriteLog "Replication completed successfully with $global:N_err errors $global:N_wrn warnings." "Success"
    } else {
        WriteLog "Replication completed with $global:N_err errors $global:N_wrn warnings." "Warning"
    }
    WriteLog "========================END==========================" "Info"

    if ($PauseAtEnd) {
        $null = Read-Host 'Press ENTER for exit...'
    }
}
catch { WriteLog "$_" "Error"}