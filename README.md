# Copy-MTPFiles
This PowerShell script allows you to transfer files to or from a portable device using MTP - the Media Transfer Protocol. MTP is a widely supported standard for transferring files over USB, particularly for media devices like phones, tablets, cameras and digital audio players. The script also supports the listing of folder contents on both the host and the device.

![Build badge](https://img.shields.io/github/actions/workflow/status/daverayment/copy-mtpfiles/build-and-upload.yml?logo=github)

## Table of Contents
- [Introduction](#copy-mtpfiles)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [A Note on Filename Conflicts](#a-note-on-filename-conflicts)
- [Parameter Reference](#parameter-reference)
- [Notes](#notes)
- [Contributions](#contributions)
- [License](#license)

## Prerequisites
The script relies on COM and so only works on Windows machines. PowerShell 5.1 (included in Windows 10) or later is required to run the script.

## Installation
To install the `Copy-MTPFiles` PowerShell module, follow these steps:

1. Download the latest ZIP archive of the module from the [Releases](https://github.com/daverayment/Copy-MTPFiles/releases) page.

2. Extract the ZIP archive. It should contain three files: `Copy-MTPFiles.psm1`, `Copy-MTPFiles.psd1` and `MTPFileFormat.ps1xml`.

3. Open PowerShell and check the value of the `$env:PSModulePath` variable. This variable contains a list of directories where PowerShell looks for modules. In PowerShell, write:

    ```powershell
    Write-Host $env:PSModulePath
    ```

    This will output something like this:

    ```
    C:\Users\YourUsername\Documents\WindowsPowerShell\Modules;C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules
    ```

    The directories are separated by semicolons (`;`). You can choose any of these directories to install your module, but the first one (which points to your Documents directory) is typically used for user-installed modules.

    Note: you may have more entries in the list, corresponding to different versions of PowerShell installed on your PC.

4. Copy the extracted `Copy-MTPFiles.psm1`, `Copy-MTPFiles.psd1` and `MTPFileFormat.ps1xml` files into a new directory named `Copy-MTPFiles` inside your chosen modules directory. For example, if you chose the first directory from the previous step, the path would be `C:\Users\YourUsername\Documents\WindowsPowerShell\Modules\Copy-MTPFiles`.

5. After copying the files, close and reopen PowerShell to refresh the module list. You should now be able to import the module using the following command:

```powershell
Import-Module Copy-MTPFiles
```

If this command does not produce any errors, the module has been installed correctly and is ready to use.

## Quick Start
By default the script copies all files in the source folder to the destination folder. This is not a recursive copy operation; child folders and their contents are ignored.

```powershell
# Copies all files from the attached device's Download folder to the folder on the host machine.
Copy-MTPFiles -Source "Internal storage/Download" -Destination "C:\PhoneDownloads"
```

Note: the `-Source` and `-Destination` parameter names are optional, so the following is equivalent to the above:


```powershell
Copy-MTPFiles "Internal storage/Download" "C:\PhoneDownloads"
```

Source and destination may both be on the host Windows machine:

```powershell
# Copy all files in the current directory to a backup directory.
# Note: the current directory is assumed for Source or Destination if the parameter is omitted.
Copy-MTPFiles -Destination "D:\My backup"
```
or both on the portable device:

```powershell
# Copy all files in the camera roll folder to a subfolder of Download.
Copy-MTPFiles -Source "Internal storage/DCIM/Camera" -Destination "Internal storage/Download/CameraPix"
```
or any mix of host and device folders:

```powershell
# Copy all files from a host machine folder to a folder on the device.
Copy-MTPFiles -Source "C:\Work\Files" -Destination "Internal storage/My App/Support"
```

Relative paths are supported for host machine folders:

```powershell
Copy-MTPFiles -Source "..\..\source\AnotherProject" -Destination "..\Documents\ProjectBackup"
```

Use the `FilePatterns` parameter to select a subset of files for transfer. You may include more than one pattern, separated by commas. Use the `*` wildcard to match any number of any character (including no matches), and `?` to match exactly one occurrence of any character.

For instance, in the following example, `*.jp*g` matches `apic.jpg`, `pic.jpeg`, `picture.jppppg`, `.jpg` and so on:

```powershell
# Copy images in the current directory to a backup.
Copy-MTPFiles -Destination "D:\My backup" -FilePatterns "*.jp*g", "*.gif", "*.png", "*.bmp"
```

## A Note on Filename Conflicts
Files will *not* be overwritten in the destination. A warning will be raised and the file will be renamed with a non-conflicting suffix. For example:

```powershell
# Copy the same file twice to the destination.
Copy-MTPFiles -Destination ".\TestFolder" -FilePatterns "SomeFile.txt"
Copy-MTPFiles -Destination ".\TestFolder" -FilePatterns "SomeFile.txt"

# Warning shown and listing "TestFolder" now shows these files:
#     SomeFile (1).txt
#     SomeFile.txt
```

## Parameter Reference
|Parameter|Aliases|Description|Example
|--|--|--|--
|`Directory`|`SourceFolder`<br/>`Source`<br/>`s`|Sets the path to the source directory. Defaults to the current directory if not specified. Paths may be absolute or relative host paths, or paths on the attached device.| `Copy-MTPFiles -Source "SDCard/MyProject" -Destination "C:\ProjectBackup"`
|`DestinationDirectory`|`DestinationFolder`<br/>`Destination`<br/>`d`|Sets the path to the destination directory. Defaults to the current directory if not specified. Paths may be absolute or relative host paths, or paths on the attached device.|`Copy-MTPFiles -Source "Internal storage/WhatsApp/Media" -Destination "D:\Phone backup"`
|`Move`||When this parameter is included, files are moved instead of copied.|`Copy-MTPFiles -Source "Internal storage/DCIM/Camera" -Destination "C:\Users\Me\Pictures" -Move`
|`ListDevices`|`GetDevices`<br/>`ld`|Lists attached MTP-compatible devices. Use this option to obtain a device name for use with the `-DeviceName` parameter. If this parameter is present, all other parameters will be ignored.|`Copy-MTPFiles -ListDevices`
|`DeviceName`|`Device`<br/>`dn`|Specifies the name of the attached device to use. This parameter must be used if more than one compatible device is attached. Use the `-ListDevices` switch to get the names of MTP-compatible devices. Note: `-DeviceName` is optional if only one MTP device is attached.|`Copy-MTPFiles -Source "C:\Users\Me\Documents" -Destination "Internal storage/Download" -DeviceName "My Phone"`
|`ListFiles`|`GetFiles`<br/>`lf`<br/>`ls`|Lists the contents of the specified directory. For directories on the host PC, this returns a standard PowerShell file listing; for directories on an attached device, this returns objects with `Name`, `Length`, `LastWriteTime`, and `Type` properties. `ListFiles` may be used in combination with `-FilenamePatterns` to filter the listing.|`Copy-MTPFiles -ListFiles "Internal storage/Download"`
|`FilenamePatterns`|`Patterns`<br/>`p`|An array of one or more filename patterns to search for. Separate multiple patterns with commas.|`Copy-MTPFiles -Destination "Internal storage/PC Files" -FilenamePatterns "*.doc", "*.pdf"`

## Notes
Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.

## Contributions
Contributions to `Copy-MTPFiles` are very welcome! Here are ways to contribute:

- **Raise an issue:** If you find a bug, have a feature request, or even have a question about using the module, please [raise an issue](https://github.com/daverayment/copy-mtpfiles/issues) on the GitHub repo. This helps to track the discussion and resolution of your request. 

- **Submit a Pull Request:** If you have a fix or improvement, and are willing to contribute it back, I'd love to incorporate it! Please first [raise an issue](https://github.com/daverayment/copy-mtpfiles/issues) as described above. This prevents duplication of effort and allows others to discuss the potential change.

Before you submit your Pull Request, please ensure the following:

1. Your code is well commented and adheres to the PowerShell [best practice guidelines](https://docs.microsoft.com/powershell/scripting/developer/cmdlet/best-practices-for-cmdlet-development).
2. Your changes have been thoroughly tested.
3. You have updated any relevant documentation, including adding comments in your code and potentially updating the [README](https://github.com/daverayment/Copy-MTPFiles/blob/main/README.md) or other documents.

Thank you for your help!

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.