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

## Parameter Reference

|Parameter|Alias|Description|Example
|--|--|--|--|
|SourceDirectory|SourceFolder, Source, s|Sets the path to the source directory. Defaults to the current path if not specified. Paths may be absolute or relative host paths, or paths on the attached device.| `.\Copy-MTPFiles.ps1 -Destination "C:\SomeDir"`
|DestinationDirectory|DestinationFolder, Destination, Dest, d|Sets the path to the destination directory. Defaults to the current path if not specified. Paths may be absolute or relative host paths, or paths on the attached device.|`.\Copy-MTPFiles.ps1 -Source "Internal storage/WhatsApp/Media" -Destination "D:\Phone backup"`
|PreScan|Scan|This switch controls whether to scan the source directory before transfers begin. If selected, the script outputs the number of matching files after the scan, and allows cancelling before any transfers take place. Recommended in combination with the `-FilePatterns` parameter.|`.\Copy-MTPFiles.ps1 -Source "Internal storage/Downloads" -Destination "." -PreScan`
|Move||By default, files are copied. When this parameter is included, files are moved instead.|`.\Copy-MTPFiles.ps1 -Source "Internal storage/DCIM/Camera" -Destination "C:\Users\Me\Pictures" -Move`
|ListDevices|GetDevices, ld|Lists attached MTP-compatible devices. Use this option to get a name for the `-DeviceName` parameter. If this parameter is present, all other parameters will be ignored.|`.\Copy-MTPFiles.ps1 -ListDevices`
|DeviceName|Device, dn|Specifies the name of the attached device to use. This parameter must be used if more than one compatible device is attached. Use the `-List` switch to get the names of MTP-compatible devices. Note: there is no need to use `-DeviceName` if only one MTP device is attached.|`.\Copy-MTPFiles.ps1 -Source "C:\Users\Me\Documents" -Destination "Internal storage/Download" -DeviceName "My Phone"`
|ListFiles|GetFiles, lf, ls|Lists all files in the specified directory. For host directories, this returns a standard PowerShell file listing; for device directories, this returns objects with `Name`, `Length`, `LastWriteTime`, and `Type` properties.|`.\Copy-MTPFiles.ps1 -ListFiles "Internal storage/Download"`
|FilenamePatterns|Patterns, p|An array of filename patterns to search for. Separate multiple patterns with commas.|`.\Copy-MTPFiles.ps1 -Destination "Internal storage/PC Files" -FilenamePatterns "*.doc", "*.pdf"`

## Notes
Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.