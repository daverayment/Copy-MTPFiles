<#
.SYNOPSIS
	This script transfers files from a portable device to the caller's machine via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts four parameters:
	- Move: A switch which, when included, moves files instead of copying them.
	- DeviceName: The name of the attached device from which to transfer the files. Use the -List switch to get information about attached devices, including their names.
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
#>

param(
	[switch]$Move,

	[switch]$List,

	[Parameter()]
	[string]$DeviceName,

	[Parameter()]
	[string]$SourceDirectory,

	[Parameter()]
	[string]$DestinationDirectory = (Get-Location).Path,

	[Parameter()]
	[string[]]$FilenamePatterns = "*"
)

# Function to retrieve an MTP folder by path
function Get-FolderByPath {
	param(
		[Parameter(Mandatory = $true)]
		[Alias("Folder")]
		$ParentFolder,

		[Parameter(Mandatory = $true)]
		[Alias("Path")]
		$FolderPath
	)

	# Loop through each directory from the path
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

Write-Host "Copy-MTPFiles starting."

# Retrieve the portable devices connected to the computer via COM
$shell = New-Object -ComObject Shell.Application
$portableDevices = $shell.NameSpace(17).Items()
$mtpDevices = $portableDevices | Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }

if ($List) {
	Write-Host "Listing attached devices."
}

if ($mtpDevices.Count -eq 0) {
	Write-Host "No compatible devices found. Please connect a device in File Transfer mode. Exiting."
	exit 1
}

# Loop through the connected portable devices
foreach ($device in $mtpDevices) {
	$deviceName = $device.Name
	$deviceType = $device.Type

	if ($List) {
		Write-Host "Found device. Name: ""$deviceName"", Type: ""$deviceType"""
		continue
	}

	Write-Host "Found $deviceName ($deviceType)"

	# Retrieve the root folder of the attached device
	$deviceRoot = $shell.Namespace($device.Path)
	Write-Host "Found device root folder."

	# Retrieve the source folder on the device
	$sourceFolder = Get-FolderByPath -ParentFolder $deviceRoot -Path $SourceDirectory
	if ($null -eq $sourceFolder) {
		Write-Host "Could not find source folder. Please check you have selected File Transfer mode on the device. Exiting."
		exit 2
	}

	Write-Host "Found source folder ""$SourceDirectory"""

	# Retrieve the destination folder, creating it if it doesn't already exist
	if (-not (Test-Path -Path $DestinationDirectory)) {
		try {
			New-Item -Path $DestinationDirectory -ItemType Directory
		}
		catch {
			Write-Host "Destination directory ""$DestinationDirectory"" was not found and could not be created. Exiting."
			exit 3
		}
		Write-Host "Created new directory ""$DestinationDirectory"""
	}
	else {
		Write-Host "Found destination directory ""$DestinationDirectory"""
	}

	$destinationFolder = $shell.NameSpace($DestinationDirectory)

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
		Write-Host "No files to move. Exiting."
		exit 4
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
					Write-Host $item.Name " moved to destination"    
				}
				else {
					$destinationFolder.CopyHere($item)
					Write-Host $item.Name " copied to destination"
				}

				# Progress bar
				$i++
				Write-Progress -Activity "Transferring files" -Status "$i out of $totalItems transferred" -PercentComplete ($i / $totalItems * 100)
			}
		}
		else {
			Write-Host "Transfer cancelled."
		}
	}
	break
}

Write-Host "Finished."
