<#
.SYNOPSIS
	This script transfers files from a portable device to the caller's machine via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts four parameters:
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

param(
	[switch]$Confirm,

	[switch]$Move,

	[switch]$List,

	[string]$DeviceName,

	[string]$SourceDirectory,

	[string]$DestinationDirectory = (Get-Location).Path,

	[string[]]$FilenamePatterns = "*"
)

# List all the MTP-compatible devices.
function Write-Devices {
	param(
		[Parameter(Mandatory = $true)]
		$MTPDevices
	)

	if ($MTPDevices.Count -eq 0) {
		Write-Host "No MTP-compatible devices found."
	}
	elseif ($MTPDevices.Count -eq 1) {
		Write-Host "One MTP device found..."
		# Note: no need to use indexing when only a single value is present.
		$deviceName = $MTPDevices.Name
		$deviceType = $MTPDevices.Type
		Write-Host "Device name: $deviceName, Type: $deviceType"
	}
	else {
		Write-Host "Listing attached MTP devices..."
		foreach ($device in $MTPDevices) {
			$deviceName = $device.Name
			$deviceType = $device.Type
			Write-Host "Found device. Name: $deviceName, Type: $deviceType"
		}
	}
}

# Retrieve an MTP folder by path.
function Get-FolderByPath {
	param(
		[Parameter(Mandatory = $true)]
		[Alias("Folder")]
		$ParentFolder,

		[Parameter(Mandatory = $true)]
		[Alias("Path")]
		$FolderPath
	)

	# Loop through each folder in turn
	$directories = $FolderPath.Split("/")
	foreach ($directory in $directories) {
		# Look for the child folder in the parent folder
		$folderFound = $false
		foreach ($item in $ParentFolder.Items() | Where-Object { $_.IsFolder }) {
			if ($item.Name -eq $directory) {
				# Found a match. Set the parent folder as the found folder then
				# continue with the next
				$ParentFolder = $item.GetFolder
				$folderFound = $true
				break
			}
		}

		if (-not $folderFound) {
			Write-Error "Failed to navigate to folder: $directory"
			return $null
		}
	}

	return $ParentFolder
}

Write-Host "Copy-MTPFiles started."

# Retrieve the portable devices connected to the computer via COM.
$shell = New-Object -ComObject Shell.Application
if ($null -eq $shell) {
	Write-Error "Failed to create a COM Shell Application object."
	exit
}
$portableDevices = $shell.NameSpace(17).Items()
$mtpDevices = $portableDevices | Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }

if ($List) {
	Write-Devices -MTPDevices $mtpDevices
	exit
}

if (-not $PSBoundParameters.ContainsKey("SourceDirectory") -or [string]::IsNullOrEmpty($SourceDirectory)) {
	Write-Error "No source directory provided. Please use the -SourceDirectory parameter to set the device folder from which to transfer files."
	exit
}

if ($mtpDevices.Count -eq 0) {
	Write-Error "No compatible devices found. Please connect a device in Transfer Files mode."
	exit
}
elseif ($mtpDevices.Count -gt 1) {
	if ($DeviceName) {
		$device = $mtpDevices | Where-Object { $_.Name -ieq $DeviceName }

		if (-not $device) {
			Write-Error "Device ""$DeviceName"" not found."
			exit
		}
	}
	else {
		Write-Error "Multiple MTP-compatible devices found. Please use the -DeviceName parameter to specify the device to use. Use the -List switch to list all compatible device names."
		exit
	}
}
else {
	$device = $mtpDevices[0]
}

$movedCopied = "copied"
if ($Move) {
	$movedCopied = "moved"
}

$deviceName = $device.Name
$deviceType = $device.Type

Write-Host "Using $deviceName ($deviceType)."

# Retrieve the root folder of the attached device
$deviceRoot = $shell.Namespace($device.Path)
Write-Host "Found device root folder."

# Retrieve the source folder on the device
$sourceFolder = Get-FolderByPath -ParentFolder $deviceRoot -Path $SourceDirectory
if ($null -eq $sourceFolder) {
	Write-Error "Source folder ""$SourceDirectory"" not found. Please check you have selected the Transfer Files mode on the device and the folder is present."
	exit
}

Write-Host "Found source folder ""$SourceDirectory""."

# Retrieve the destination folder, creating it if it doesn't already exist
if (-not (Test-Path -Path $DestinationDirectory)) {
	try {
		New-Item -Path $DestinationDirectory -ItemType Directory
	}
	catch {
		Write-Error "Destination directory ""$DestinationDirectory"" was not found and could not be created. Please check you have the necessary permissions."
		exit
	}
	Write-Host "Created new directory ""$DestinationDirectory""."
}
else {
	Write-Host "Found destination directory ""$DestinationDirectory""."
}

$destinationFolder = $shell.NameSpace($DestinationDirectory)

if ($Confirm)
{
	# Holds all the files in the source directory which match the file pattern(s)
	$filesToTransfer = @()

	# For the scanned items progress bar
	$totalItems = $sourceFolder.Items().Count
	$i = 0

	# Scan the source folder for items which match the filename pattern(s)
	foreach ($item in $sourceFolder.Items()) {
		foreach ($p in $FilenamePatterns) {
			if ($item.Name -like $p) {
				$filesToTransfer += $item
				break
			}
		}

		# Progress bar
		$i++
		Write-Progress -Activity "Scanning files" -Status "$i out of $totalItems processed" -PercentComplete ($i / $totalItems * 100)
	}
	if ($filesToTransfer.Count -eq 0) {
		Write-Host "No files to transfer."
		exit
	}
	else {
		$confirmation = Read-Host "$($filesToTransfer.Count) files will be moved from ""$SourceDirectory"" to ""$DestinationDirectory"". Proceed (Y/N)?"
		if ($confirmation -eq "Y") {
			# For the moved items progress bar
			$totalItems = $filesToTransfer.Count
			$i = 0

			foreach ($item in $filesToTransfer) {
				if ($Move) {
					$destinationFolder.MoveHere($item)
				}
				else {
					$destinationFolder.CopyHere($item)
				}

				Write-Host $item.Name $movedCopied "to destination."

				# Progress bar
				$i++
				Write-Progress -Activity "Transferring files" -Status "$i out of $totalItems transferred" -PercentComplete ($i / $totalItems * 100)
			}
		}
		else {
			Write-Host "Transfer cancelled."
		}
	}
}
else {
	$i = 0
	# Transfer files immediately, without scanning or confirmation.
	foreach ($item in $sourceFolder.Items()) {
		foreach ($p in $FilenamePatterns) {
			if ($item.Name -like $p) {
				$i++
				if ($Move) {
					$destinationFolder.MoveHere($item)
				}
				else {
					$destinationFolder.CopyHere($item)
				}

				Write-Host $item.Name $movedCopied "to destination."
				break
			}
		}
	}
	if ($i -eq 0) {
		Write-Host "No matching files found."
	}
	else {
		Write-Host $i "files" $movedCopied "."
	}
}

Write-Host "Finished."
