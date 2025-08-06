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

.EXITCODES
0 : Replication completed successfully with no errors no warnings.
1 : Replication completed but with some warnings.
100 : Source and replica paths are the same
101 : Source path does not exist
102 : Replica directory creating failed
110 : General error

.NOTES
Version	: 1.1  
Author	: Viktor Kravtsov  
Date	: 2025-08-06  
Purpose	: Minor fixes & optimizations

Version	: 1.0  
Author	: Viktor Kravtsov  
Date	: 2025-08-04  
Purpose	: Initial script development

.EXAMPLE
.\FolderReplication.ps1 -SourcePath "C:\TEMP\source" -ReplicaPath "\\localhost\C$\TEMP\replica" -LogFilePath 'c:\TEMP' -VerboseLog -MaxRetries 3 -NTFSPermissions

#>

Param (
    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string]$ReplicaPath,

    [Parameter(Mandatory = $False)]
    [string]$LogFilePath,

    [Parameter(Mandatory = $False)]
    [ValidateNotNullOrEmpty()]
    [int]$MaxRetries = 5,

    [Parameter(Mandatory = $False)]
    [switch]$NTFSPermissions,

    [Parameter(Mandatory = $False)]
    [switch]$VerboseLog

)

############# VARIABLES #######################################
    $global:N_err = 0
    $global:N_wrn = 0


function SetLogging {
    param (
        [string]$LogFilePath,
        [string]$LogFileName
    )

    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        # If LogFilePath is an existing directory
        if ((Test-Path $LogFilePath) -and ((Get-Item $LogFilePath).PSIsContainer)) {
            $LogFilePath = Join-Path $LogFilePath $LogFileName
            if (-not (Test-Path $LogFilePath)) {
                New-Item -ItemType File -Path $LogFilePath | Out-Null
            }
        }
        # If LogFilePath is an non-existing directory
        elseif ($LogFilePath -notlike "*.*") {
            New-Item -ItemType Directory -Path $LogFilePath | Out-Null
            $LogFilePath = Join-Path $LogFilePath $LogFileName
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
    return $LogFilePath
}

############# FUNCTIONS #######################################
function WriteLog {
    param(
        [string]$Message,
        [string]$Type = "Info"  # Info, Error, Warning, Success
    )
    $msg = ((Get-Date -Format "yyyy-MM-dd HH:mm:ss K") + "(UTC) | [$Type] | $Message")
    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        Add-Content -Path $LogFilePath -Value $msg
    }
    switch ($Type) {
        "Fail" { Write-Host $msg -ForegroundColor Red }
        "Warn" { Write-Host $msg -ForegroundColor Yellow }
        "Done" { Write-Host $msg -ForegroundColor Green }
        default { Write-Host $msg -ForegroundColor White }
    }
}

function FoldersCheck {
    # Validate source and replica paths are not the same
    if ($SourcePath.TrimEnd('\') -ieq $ReplicaPath.TrimEnd('\')) {
        WriteLog "Source and replica paths must not be the same. Script terminated." "Fail"
        $global:N_err++
        exit 100
    }

    # check source 
    if (!(Test-Path -LiteralPath $SourcePath)) {
        WriteLog "Source path does not exist: $SourcePath. Script terminated." "Fail"
        $global:N_err++
        exit 101
    }

    # check replica
    if (Test-Path -LiteralPath $ReplicaPath) {
        if ($VerboseLog) {WriteLog "Replica folder exist: $ReplicaPath" "Info"}
        # replica cleanup
        Get-ChildItem -Path $ReplicaPath -Recurse -Force | ForEach-Object {
            try {
                If ($_.PSIsContainer) { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) }
                else { $_.IsReadOnly = $false }
                Remove-Item -Path $_.FullName -Recurse -Force
                WriteLog "Replica folder cleanup, deleted : $($_.FullName)" "Info"
            } catch {
				try{
					Start-Sleep -Seconds (2)
					Remove-Item -Path $_.FullName -Recurse -Force
				}
                catch {
					WriteLog "Failed to delete: $($_.FullName) - $($_.Exception.Message)" "Warn"
					$global:N_wrn++
				}	
            }
        }
    }
    else {
        WriteLog "Replica folder doesnt exist: $ReplicaPath, creating..." "Info"
        New-Item -ItemType Directory -Path $ReplicaPath | Out-Null
        if (Test-Path -LiteralPath $ReplicaPath) { if ($VerboseLog) {WriteLog "Created replica directory: $ReplicaPath" "Info" }}
        else {
            WriteLog "Replica directory creating failed: $ReplicaPath. Script terminated." "Fail"
            $global:N_err++
            exit 102
        }    
    }

}



function ReplicateFolder {
    $paths = @()
    if ($VerboseLog) {WriteLog "Content copying started" "Info"}

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
                            WriteLog "HASH MISMATCH (Attempt $($attempt + 1)): $($targetPath), replica deleted" "Warn"
                            $global:N_wrn++
                        }
                    }
                    catch {
                        WriteLog "ERROR copying (Attempt $($attempt + 1)): $($item.FullName) - $($_.Exception.Message)" "Fail"
                        $global:N_err++
                         Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 4)
                    }
                    $attempt++

                }

                if (-not $success) {
                    WriteLog "FAILED after $MaxRetries attempts: $($item.FullName)" "Fail"
                    $global:N_err++
					
                }
            }
        }
        catch {
            WriteLog "ERROR processing item: $($item.FullName) - $($_.Exception.Message)" "Fail"
            $global:N_err++

        }
    }
    if ($VerboseLog) {WriteLog "Copy and verification completed" "Info"}
    if ($VerboseLog) {WriteLog "Folders attributes replication started" "Info"}
    foreach ($path in $paths) {
        try {
            get-item $path.sourcepath -Force | ReplicateAttributes -dst $path.targetpath
        } catch {
            WriteLog "ERROR replicating attributes for: $($path.sourcepath) - $($_.Exception.Message)" "Warn"
            $global:N_wrn++
        }
		
    }
	if ($VerboseLog) {WriteLog "Folders attributes replication completed." "Info"}

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
                WriteLog "ERROR setting NTFS permissions: $($src.FullName) - $($_.Exception.Message)" "Warn"
                $global:N_wrn++
            }
        }
    }
    catch {
        WriteLog "ERROR attribs replication: $($src.FullName) - $($_.Exception.Message)" "Warn"
        $global:N_wrn++
    }
}


############# MAIN EXECUTION ##################################

try {
    Clear-Host
	
	$LogFilePath = SetLogging $LogFilePath 'FolderReplication.log'

if ($VerboseLog) {
    WriteLog "========================START========================" "Info"
    WriteLog "$env:COMPUTERNAME/$env:USERNAME" "Info"
    WriteLog "Source path: $SourcePath" "Info"
    WriteLog "Target path: $ReplicaPath" "Info"
    WriteLog "Log file: $LogFilePath" "Info"
    WriteLog "Verbose Logging: $VerboseLog" "Info"
    WriteLog "Max attempts to copy content: $MaxRetries" "Info"
    WriteLog "Copy NTFS permissions: $NTFSPermissions" "Info"
}
    FoldersCheck

    ReplicateFolder

    if (($N_err -eq 0) -and ($N_wrn -eq 0)) {
		if ($VerboseLog) {
			WriteLog "Replication completed successfully with $global:N_err errors $global:N_wrn warnings." "Done"
			WriteLog "========================END==========================" "Info"
		}
		Exit 0
    } else {
        if ($VerboseLog) {
			WriteLog "Replication completed with $global:N_err errors $global:N_wrn warnings." "Warn"
			WriteLog "========================END==========================" "Info"
		}
		Exit 1
    }


}
catch { 
	WriteLog "$_" "Fail"
	Exit 110
}