# Copy-MTPFiles

This PowerShell script allows you to transfer files to or from a portable device using MTP - the Media Transfer Protocol. MTP is a widely supported standard for transferring files over USB, particularly for media devices like phones, tablets, cameras, and digital audio players.

The script relies on COM and so only works on Windows machines.

## Quick Start

By default the script will copy all files in the source folder to the destination. This is not a recursive copy operation - any files in child folders will not be copied.

```powershell
# Copy all files from the phone's camera roll to the host.
.\Copy-MTPFiles.ps1 "Internal storage/DCIM/Camera" "C:\Users\Me\Pictures\Holiday"
```
Source and destination may both be on the host Windows machine, both on the device, or any combination of the two.

```powershell
# Copy all files in the current directory to a backup directory.
.\Copy-MTPFiles.ps1 "." "D:\My backup"
```
Use the `FilePatterns` parameter to select only the files you want to transfer. You may include more than one pattern, separated by commas.

```powershell
# Copy images in the current directory to a backup.
.\Copy-MTPFiles.ps1 "." "D:\My backup" -FilePatterns "*.jp*g", "*.gif", "*.png", "*.bmp"
```
The full list of parameters are below.

## Parameter Reference

### SourceDirectory (Aliases: SourceFolder, Source, s)
Sets the path to the source directory. Defaults to the current path if not specified. Paths may be absolute or relative host paths, or paths on the attached device.

```powershell
# Copy all files from the current directory to the destination.
.\Copy-MTPFiles.ps1 -Destination "C:\SomeDir"
```

### DestinationDirectory (Aliases: DestinationFolder, Destination, Dest, d)
Sets the path to the destination directory. Defaults to the current path if not specified. Paths may be absolute or relative host paths, or paths on the attached device.

```powershell
.\Copy-MTPFiles.ps1 -Source "Internal storage/WhatsApp/Media" -Destination "D:\Phone backup"
```

### PreScan (Alias: Scan)
This switch controls whether to scan the source directory before transfers begin. If selected, the script outputs the number of matching files after the scan, and allows cancelling before any transfers take place. Recommended in combination with the `-FilePatterns` parameter.

```powershell
.\Copy-MTPFiles.ps1 -Source "Internal storage/Downloads" -Destination "." -PreScan
```

### Move
By default, files are copied. When this parameter is included, files are moved instead.

```powershell
.\Copy-MTPFiles.ps1 -Source "Internal storage/DCIM/Camera" -Destination "C:\Users\Me\Pictures" -Move
```

### ListDevices (Aliases: GetDevices, ld)
Lists attached MTP-compatible devices. Use this option to get a name for the `-DeviceName` parameter. If this parameter is present, all other parameters will be ignored.

```powershell
.\Copy-MTPFiles.ps1 -ListDevices
```

### DeviceName (Aliases: Device, dn)
Specifies the name of the attached device to use. This parameter must be used if more than one compatible device is attached. Use the `-List` switch to get the names of MTP-compatible devices.

```powershell
.\Copy-MTPFiles.ps1 -Source "C:\Users\Me\Documents" -Destination "Internal storage/Download" -DeviceName "My Phone"
```
There is no need to use `-DeviceName` if only one MTP device is attached.

### ListFiles (Aliases: GetFiles, lf)
Lists all files in the specified directory. For host directories, this returns a standard PowerShell file listing; for device directories, this returns objects with `Name`, `Length`, `LastWriteTime`, and `Type` properties.

```powershell
.\Copy-MTPFiles.ps1 -ListFiles "Internal storage/Download"
```

### FilenamePatterns (Aliases: Patterns, p)
An array of filename patterns to search for. Separate multiple patterns with commas.

```powershell
# Copy all PDF and DOC files from the current directory to the specified directory on the device.
.\Copy-MTPFiles.ps1 -Destination "Internal storage/PC Files" -FilenamePatterns "*.doc", "*.pdf"
```

## Notes
Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.