<#
.SYNOPSIS
	This script transfers files from a portable device to the caller's machine via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts the following parameters:
	- Confirm: A switch which controls whether to scan the source directory before transfers begin. Lists the number of matching files and allows cancelling before any transfers take place.
	- Move: A switch which, when included, moves files instead of the default of copying them.
	- List: A switch for listing the attached MTP-compatible devices. Use this option to get the names for the -DeviceName parameter. All other parameters will be ignored if this is present.
	- DeviceName: The name of the attached device from which to transfer the files. Must be used if more than one compatible device is attached. Use the -List switch to get the names of MTP-compatible devices.
	- SourceDirectory: The path to the source directory on the portable device.
	- DestinationDirectory: The path to the destination directory on the caller's machine. Defaults to the current directory.
	- FilenamePatterns: An array of filename patterns to search for. Defaults to matching all files.
.LINK
	https://github.com/daverayment/Copy-MTPFiles
.NOTES
	Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.
.EXAMPLE
	Move files with a .doc or .pdf extension from the Download directory on the device to a specified directory on the host:
	
	.\Copy-MTPFiles.ps1 -Move -SourceDirectory "Internal storage/Download" -DestinationDirectory "C:\Projects\Documents" -FilenamePatterns "*.doc", "*.pdf"
.EXAMPLE
	Copy files with a .jpg extension from the Download directory on the device to the current folder:

	.\Copy-MTPFiles.ps1 "Internal storage/Download" -FilenamePatterns "*.jpg"
.EXAMPLE
	List all compatible devices which are currently attached:

	.\Copy-MTPFiles.ps1 -List
#>

[CmdletBinding()]
param(
	[switch]$Confirm,

	[switch]$Move,

	[switch]$List,

	[string]$DeviceName,

	[ValidateNotNullOrEmpty()]
	[string]$SourceDirectory,

	[string]$DestinationDirectory = (Get-Location).Path,

	[string[]]$FilenamePatterns = "*"
)

# Ensure we have a script-level Shell Application object for COM interactions.
function New-ShellApplication {
	if ($null -eq $script.$ShellApp) {
		$script.$ShellApp = New-Object -ComObject Shell.Application
		if ($null -eq $script.$ShellApp) {
			throw "Failed to create a COM Shell Application object."
		}
	}
}

# Retrieve all the MTP-compatible devices.
function Get-MTPDevices {
	$portableDevices = $script.$ShellApp.NameSpace(17).Items()
	return $portableDevices | Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }
}

# Lists all the attached MTP-compatible devices.
function Write-MTPDevices {
	$devices = Get-MTPDevices

	if ($devices.Count -eq 0) {
		Write-Host "No MTP-compatible devices found."
	}
	elseif ($devices.Count -eq 1) {
		Write-Host "One MTP device found..."
		# Note: no need to use indexing when only a single value is present.
		# Note: use subexpressions for COM props so actual value is displayed.
		Write-Host "Device name: $($devices.Name), Type: $($devices.Type)"
	}
	else {
		Write-Host "Listing attached MTP devices..."
		foreach ($device in $devices) {
			Write-Host "Found device. Name: $($device.Name), Type: $($device.Type)"
		}
	}
}

# Ensure our transfers do not overwrite existing files in the destination directory. We append a unique numeric suffix like Windows' copy routine.
function Get-UniqueFilename {
	param(
		[Parameter(Mandatory = $true)]
		[Alias("Item")]
		$FileItem,

		[Parameter(Mandatory = $true)]
		[System.__ComObject]
		$DestinationFolder
	)

	$tempDirectory = Join-Path -Path $Env:TEMP -ChildPath "TempCopyMTPFiles"
	if (-not (Test-Path -Path $tempDirectory)) {
		New-Item -Path $tempDirectory -ItemType Directory | Out-Null
	}
	$tempFolder = $shell.NameSpace($tempDirectory)

	$destinationPath = Join-Path -Path $DestinationDirectory -ChildPath $FileItem.Name

    # Check if a file with the same name already exists in the destination directory
    if (Test-Path -Path $destinationPath) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($FileItem.Name)
        $extension = [IO.Path]::GetExtension($FileItem.Name)
        $counter = 1

        # Generate a new filename with a unique number suffix.
        do {
            $newName = "$baseName ($counter)$extension"
            $destinationPath = Join-Path -Path $DestinationDirectory -ChildPath $newName
            $counter++
        }
        while (Test-Path -Path $destinationPath)

        Write-Warning "A file with the same name already exists. Renaming to $newName."

		# Copy or move the file to our temporary directory so it can be renamed without altering the source directory.
		$tempFilePathOld = Join-Path -Path $tempDirectory -ChildPath $FileItem.Name
		$tempFilePathNew = Join-Path -Path $tempDirectory -ChildPath $newName
		if ($Move) {
			$tempFolder.MoveHere($FileItem)
		}
		else {
			$tempFolder.CopyHere($FileItem)
		}

		# Perform the rename and update the path of the item.
		Rename-Item -Path $tempFilePathOld -NewName $tempFilePathNew -Force
		$FileItem = $tempFolder.Items() | Where-Object { $_.Path -eq $tempFilePathNew }
    }

	return $FileItem
}

# Retrieve an MTP folder by path. Returns $null if part of the path is not found.
function Get-FolderByPath {
	param(
		[Parameter(Mandatory = $true)]
		[Alias("Folder")]
		$ParentFolder,

		[Parameter(Mandatory = $true)]
		[Alias("Path")]
		$FolderPath
	)

	# Loop through each path subfolder in turn.
	foreach ($directory in $FolderPath.Split('/')) {
		$ParentFolder = ($ParentFolder.Items() | Where-Object { $_.IsFolder -and $_.Name -eq $directory }).GetFolder
		if ($null -eq $ParentFolder) {
			break
		}
	}

	return $ParentFolder
}

Write-Output "Copy-MTPFiles started."

New-ShellApplication

if ($List) {
	Write-MTPDevices
	return
}

if (-not $PSBoundParameters.ContainsKey("SourceDirectory") -or [string]::IsNullOrEmpty($SourceDirectory)) {
	throw "No source directory provided. Please use the 'SourceDirectory' parameter to set the device folder from which to transfer files."
}

# Retrieve the portable devices connected to the computer via COM.
$devices = Get-MTPDevices

if ($devices.Count -eq 0) {
	throw "No compatible devices found. Please connect a device in Transfer Files mode."
}
elseif ($devices.Count -gt 1) {
	if ($DeviceName) {
		$device = $devices | Where-Object { $_.Name -ieq $DeviceName }

		if (-not $device) {
			throw "Device ""$DeviceName"" not found."
		}
	}
	else {
		throw "Multiple MTP-compatible devices found. Please use the 'DeviceName' parameter to specify the device to use. Use the 'List' switch to list all compatible device names."
	}
}
else {
	$device = $devices
}

$movedCopied = "copied"
if ($Move) {
	$movedCopied = "moved"
}

Write-Verbose "Using $($device.Name) ($($device.Type))."

# Retrieve the root folder of the attached device.
$deviceRoot = $shell.Namespace($device.Path)
Write-Debug "Found device root folder."

# Retrieve the source folder on the device.
$sourceFolder = Get-FolderByPath -ParentFolder $deviceRoot -Path $SourceDirectory
if ($null -eq $sourceFolder) {
	throw "Source folder ""$SourceDirectory"" not found. Please check you have selected the Transfer Files mode on the device and the folder is present."
}

Write-Debug "Found source folder ""$SourceDirectory""."

# Retrieve the destination folder, creating it if it doesn't already exist.
if (-not (Test-Path -Path $DestinationDirectory)) {
	try {
		New-Item -Path $DestinationDirectory -ItemType Directory
	}
	catch {
		throw "Destination directory ""$DestinationDirectory"" was not found and could not be created. Please check you have the necessary permissions."
	}
	Write-Output "Created new directory ""$DestinationDirectory""."
}
else {
	Write-Debug "Found destination directory ""$DestinationDirectory""."
}

$destinationFolder = $script.$ShellApp.NameSpace($DestinationDirectory)

if ($Confirm)
{
	# Holds all the files in the source directory which match the file pattern(s).
	$filesToTransfer = @()

	# For the scanned items progress bar.
	Write-Progress -Activity "Scanning files" -Status "Counting total files."
	$totalItems = $sourceFolder.Items().Count
	$i = 0

	# Scan the source folder for items which match the filename pattern(s).
	foreach ($item in $sourceFolder.Items()) {
		foreach ($p in $FilenamePatterns) {
			if ($item.Name -like $p) {
				$filesToTransfer += $item
				break
			}
		}

		# Progress bar.
		$i++
		Write-Progress -Activity "Scanning files" -Status "$i out of $totalItems processed" -PercentComplete ($i / $totalItems * 100)
	}
	if ($filesToTransfer.Count -eq 0) {
		Write-Output "No files to transfer."
		return
	}
	else {
		$confirmation = Read-Host "$($filesToTransfer.Count) files will be moved from ""$SourceDirectory"" to ""$DestinationDirectory"". Proceed (Y/N)?"
		if ($confirmation -eq "Y") {
			# For the moved items progress bar.
			$totalItems = $filesToTransfer.Count
			$i = 0

			foreach ($item in $filesToTransfer) {
				$item = Get-UniqueFilename -Item $item -DestinationFolder $destinationFolder
	
				if ($Move) {
					$destinationFolder.MoveHere($item)
				}
				else {
					$destinationFolder.CopyHere($item)
				}

				Write-Output "$item.Name $movedCopied to destination."

				# Progress bar.
				$i++
				Write-Progress -Activity "Transferring files" -Status "$i out of $totalItems transferred" -PercentComplete ($i / $totalItems * 100)
			}
		}
		else {
			Write-Output "Transfer cancelled."
		}
	}
}
else {
	# Transfer files immediately, without scanning or confirmation.
	$i = 0
	foreach ($item in $sourceFolder.Items()) {
		foreach ($p in $FilenamePatterns) {
			if ($item.Name -like $p) {
				$i++
				$item = Get-UniqueFilename -Item $item -DestinationFolder $destinationFolder
				if ($Move) {
					$destinationFolder.MoveHere($item)
				}
				else {
					$destinationFolder.CopyHere($item)
				}

				Write-Progress -Activity "Transferring files" -Status "$item.Name $movedCopied to destination."
				break
			}
		}
	}
	if ($i -eq 0) {
		Write-Output "No matching files found."
	}
	else {
		Write-Output "$i file(s) $movedCopied."
	}
}

Write-Output "Finished."
