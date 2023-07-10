# Copy-MTPFiles

This PowerShell script allows you to transfer files to or from a portable device using MTP - the Media Transfer Protocol. MTP is a widely supported standard for transferring files over USB, particularly for media devices like phones, tablets, cameras and digital audio players.

## Prerequisites

The script relies on COM and so only works on Windows machines. PowerShell 5.1 (included in Windows 10) or later is required to run the script. It may work on earlier versions, but has not been tested on them.

## Quick Start

By default the script copies all files in the source folder to the destination folder. This is not a recursive copy operation; child folders and their contents are ignored.

```powershell
# Copies all files from the attached device's Download folder to the folder on the host machine.
.\Copy-MTPFiles.ps1 -Source "Internal storage/Download" -Destination "C:\PhoneDownloads"
```

Note: the `-Source` and `-Destination` parameter names are optional, so the following is equivalent to the above:


```powershell
.\Copy-MTPFiles.ps1 "Internal storage/Download" "C:\PhoneDownloads"
```

Source and destination may both be on the host Windows machine:

```powershell
# Copy all files in the current directory to a backup directory.
.\Copy-MTPFiles.ps1 "." "D:\My backup"
```
or both on the portable device:

```powershell
# Copy all files in the camera roll folder to a subfolder of Download.
.\Copy-MTPFiles.ps1 "Internal storage/DCIM/Camera" "Internal storage/Download/CameraPix"
```
or any mix of host and device folders:

```powershell
# Copy all files from a host machine folder to a folder on the device.
.\Copy-MTPFiles.ps1 "C:\Work\Files" "Internal storage/My App/Support"
```

Relative folder paths are supported for source and/or destination folders on the host machine.

```powershell
.\Copy-MTPFiles.ps1 "..\..\source\AnotherProject" "..\Documents\ProjectBackup"
```

Use the `FilePatterns` parameter to select only the files you want to transfer. You may include more than one pattern, separated by commas. Use the `*` wildcard to match any number of any character, and `?` to match any 1 character.

```powershell
# Copy images in the current directory to a backup.
.\Copy-MTPFiles.ps1 "." "D:\My backup" -FilePatterns "*.jp*g", "*.gif", "*.png", "*.bmp"
```

The complete list of parameters are below.

## Filename Conflicts
Files will not be overwritten in the destination. A warning will be raised and the file will be renamed with a non-conflicting suffix. For example:

```powershell
# Copy the same file twice to the destination.
.\Copy-MTPFiles.ps1 "." ".\TestFolder" -Patterns "Copy-MTPFiles.ps1"
.\Copy-MTPFiles.ps1 "." ".\TestFolder" -Patterns "Copy-MTPFiles.ps1"

# Warning shown and listing "TestFolder" now shows these files:
#     Copy-MTPFiles (1).ps1
#     Copy-MTPFiles.ps1
```

## Parameter Reference

|Parameter|Alias|Description|Example
|--|--|--|--|
|SourceDirectory|SourceFolder, Source, s|Sets the path to the source directory. Defaults to the current path if not specified. Paths may be absolute or relative host paths, or paths on the attached device.| `.\Copy-MTPFiles.ps1 -Source "SDCard/MyProject" -Destination "C:\ProjectBackup"`
|DestinationDirectory|DestinationFolder, Destination, d|Sets the path to the destination directory. Defaults to the current path if not specified. Paths may be absolute or relative host paths, or paths on the attached device.|`.\Copy-MTPFiles.ps1 -Source "Internal storage/WhatsApp/Media" -Destination "D:\Phone backup"`
|Move||By default, files are copied. When this parameter is included, files are moved instead.|`.\Copy-MTPFiles.ps1 -Source "Internal storage/DCIM/Camera" -Destination "C:\Users\Me\Pictures" -Move`
|ListDevices|GetDevices, ld|Lists attached MTP-compatible devices. Use this option to get a name for the `-DeviceName` parameter. If this parameter is present, all other parameters will be ignored.|`.\Copy-MTPFiles.ps1 -ListDevices`
|DeviceName|Device, dn|Specifies the name of the attached device to use. This parameter must be used if more than one compatible device is attached. Use the `-ListDevices` switch to get the names of MTP-compatible devices. Note: `-DeviceName` is optional if only one MTP device is attached.|`.\Copy-MTPFiles.ps1 -Source "C:\Users\Me\Documents" -Destination "Internal storage/Download" -DeviceName "My Phone"`
|ListFiles|GetFiles, lf, ls|Lists the contents of the specified directory. For directories on the host PC, this returns a standard PowerShell file listing; for directories on an attached device, this returns objects with `Name`, `Length`, `LastWriteTime`, and `Type` properties. `ListFiles` may be used in combination with `-FilenamePatterns` to filter the listing.|`.\Copy-MTPFiles.ps1 -ListFiles "Internal storage/Download"`
|FilenamePatterns|Patterns, p|An array of one or more filename patterns to search for. Separate multiple patterns with commas.|`.\Copy-MTPFiles.ps1 -Destination "Internal storage/PC Files" -FilenamePatterns "*.doc", "*.pdf"`

## Notes
Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.