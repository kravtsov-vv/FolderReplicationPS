# FolderReplication.ps1

## Synopsis
FolderReplication.ps1

## Description
Test task. This script performs one-way synchronization to create a fully identical copy of the source folder's contents in the replica folder.  
It includes:
- Copying files and folders from the source
- Verifying file integrity by comparing hashes
- Replicating file and folder attributes
- Copying NTFS permissions (if enabled)

## Parameters

- **SourcePath**  
  Specifies the path to the source folder.

- **ReplicaPath**  
  Specifies the path to the replica folder.

- **LogFilePath**  
  Specifies the path to the log file.  
  If only a folder is provided, the default log file name is 'FolderReplication.log'.  
  If left empty, operations will be logged to the console only.

- **VerboseLog**  
  Include in log additional info about Attributes /NTFS permissions replication.

- **MaxRetries**  
  Specifies the number of retry attempts for copying an item.  
  Default: 5

- **NTFSPermissions**  
  If set, NTFS permissions will also be replicated.

- **PauseAtEnd**  
  If set, wait until 'Enter' key is pressed at the end.

## Notes

- **Version:** 1.0  
- **Author:** Viktor Kravtsov  
- **Creation Date:** 2025-08-04  
- **Purpose/Change:** Initial script development

## Examples

```powershell
.\FolderReplication.ps1 -SourcePath "c:\TEMP\sources\" -ReplicaPath "\\localhost\d$\TEMP\replica" -LogFilePath 'c:\TEMP\' -MaxRetries 3 -NTFSPermissions

.\FolderReplication.ps1 -SourcePath "C:\TEMP\qweqwe\source" -ReplicaPath "C:\TEMP\qweqwe\replica" -LogFilePath 'c:\TEMP\qweqwe' -PauseAtEnd