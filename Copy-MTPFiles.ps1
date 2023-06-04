<#
.SYNOPSIS
	This script transfers files to or from a portable device via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts the following parameters:
	- Confirm: A switch which controls whether to scan the source directory before transfers begin. Lists the number of matching files and allows cancelling before any transfers take place.
	- Move: A switch which, when included, moves files instead of the default of copying them.
	- List: A switch for listing the attached MTP-compatible devices. Use this option to get the names for the -DeviceName parameter. All other parameters will be ignored if this is present.
	- DeviceName: The name of the attached device. Must be used if more than one compatible device is attached. Use the -List switch to get the names of MTP-compatible devices.
	- SourceDirectory: The path to the source directory.
	- DestinationDirectory: The path to the destination directory.
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
	Move all files from the current directory on the host computer to the Download directory on the portable device:

	.\Copy-MTPFiles.ps1 -Move -SourceDirectory "." -DestinationDirectory "Internal storage/Download"
.EXAMPLE
	List all compatible devices which are currently attached:

	.\Copy-MTPFiles.ps1 -List
#>

[CmdletBinding(SupportsShouldProcess)]
param(
	# NB: not required - we inherit this from the Cmdlet common parameters.
	# [switch]$Confirm,

	[switch]$Move,

	[switch]$List,

	[string]$DeviceName,

	[ValidateNotNullOrEmpty()]
	[string]$SourceDirectory = (Get-Location).Path,

	[ValidateNotNullOrEmpty()]
	[string]$DestinationDirectory = (Get-Location).Path,

	[string[]]$FilenamePatterns = "*"
)

# Ensure we have a script-level Shell Application object for COM interactions.
function New-ShellApplication {
	if ($null -eq $script:ShellApp) {
		$script:ShellApp = New-Object -ComObject Shell.Application
		if ($null -eq $script:ShellApp) {
			throw "Failed to create a COM Shell Application object."
		}
	}
}

# Retrieve all the MTP-compatible devices.
function Get-MTPDevices {
	$portableDevices = $script:ShellApp.NameSpace(17).Items()
	return $portableDevices | Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }
}

# Lists all the attached MTP-compatible devices.
function Write-MTPDevices {
	$devices = Get-MTPDevices

	if ($devices.Count -eq 0) {
		Write-Host "No MTP-compatible devices found."
	}
	elseif ($devices.Count -eq 1) {
		Write-Host "One MTP device found."
		# Note: no need to use indexing when only a single value is present.
		# Note: use subexpressions for COM props so actual value is displayed.
		Write-Host "  Device name: $($devices.Name), Type: $($devices.Type)"
	}
	else {
		Write-Host "Listing attached MTP devices."
		foreach ($device in $devices) {
			Write-Host "  Device name: $($device.Name), Type: $($device.Type)"
		}
	}
}

# For more efficient processing, create a single regular expression to represent the filename patterns.
function Convert-WildcardsToRegex {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Patterns
    )
    
    # Convert each pattern to a regex, and join them with "|".
	$regex = $($Patterns | ForEach-Object {
        "^$([Regex]::Escape($_).Replace('\*', '.*').Replace('\?', '.'))$"
    }) -join "|"
	Write-Debug "Filename matching regex: $regex"

	# We could potentially be using the same regex thousands of times, so compile it. Also ensure matching is case-insensitive.
	$options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled
    return New-Object System.Text.RegularExpressions.Regex ($regex, $options)
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
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory = $true)]
		[System.__ComObject]
		$ParentFolder,

		[Parameter(Mandatory = $true)]
		$FolderPath
	)

	# Loop through each path subfolder in turn, creating folders if they don't already exist.
	foreach ($directory in $FolderPath.Split('/')) {
		$nextFolder = $ParentFolder.ParseName($directory)
		if (-not $nextFolder.IsFolder) {
			throw "Cannot navigate to ""$FolderPath"". A file already exists called ""$directory""."
		}
		# Create a new directory if it doesn't already exist.
		if ($null -eq $nextFolder) {
			if ($PSCmdlet.ShouldProcess($directory, "Create directory")) {
			$ParentFolder.NewFolder($directory)
				$nextFolder = $ParentFolder.ParseName($directory)
		}
			else {
				# In the -WhatIf scenario, we do not simulate the creation of missing directories, for now.
				throw "Cannot continue without creating new directory ""$directory"". Exiting."
			}
		}
		if ($null -eq $nextFolder) {
			throw "Could not create new directory ""$directory"". Please confirm you have adequate permissions on the device."
	}

		# Continue looping until all subfolders have been navigated.
		$ParentFolder = $nextFolder.GetFolder
	}

	return $ParentFolder
}

# Get a COM reference to the directory on the host device.
function Get-HostDirectory {
	param(
		[Parameter(Mandatory = $true)]
		[string]$DirectoryPath
	)

	if (-not (Test-Path -Path $DirectoryPath)) {
		throw "Host directory ""$DirectoryPath"" not found. Please check you have supplied a valid directory path."
	}

	return $script:ShellApp.NameSpace($DirectoryPath)
}


Write-Output "Copy-MTPFiles started."

New-ShellApplication

$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

if ($List) {
	Write-MTPDevices
	return
}

if (-not $PSBoundParameters.ContainsKey("SourceDirectory") -or [string]::IsNullOrEmpty($SourceDirectory)) {
	throw "No source directory provided. Please use the 'SourceDirectory' parameter to set the folder from which to transfer files."
}

if (-not $PSBoundParameters.ContainsKey("DestinationDirectory") -or [string]::IsNullOrEmpty($DestinationDirectory)) {
	throw "No destination directory provided. Please use the 'DestinationDirectory' parameter to set the folder where the files will be transferred."
}

if (($SourceDirectory -eq $DestinationDirectory) -or
	([IO.Path]::GetFullPath($SourceDirectory) -eq [IO.Path]::GetFullPath($DestinationDirectory))) {
	throw "Source and Destination directories cannot be the same."
}

# Retrieve the portable devices connected to the computer.
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
$deviceRoot = $script:ShellApp.Namespace($device.Path)
Write-Debug "Found device root folder."

# Retrieve the source folder on the device.
$sourceFolder = Get-FolderByPath -ParentFolder $deviceRoot -FolderPath $SourceDirectory
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

$destinationFolder = $script:ShellApp.NameSpace($DestinationDirectory)

if ($PSBoundParameters.ContainsKey("Confirm")) {
	# Holds all the files in the source directory which match the file pattern(s).
	$filesToTransfer = @()

	# For the scanned items progress bar.
	Write-Progress -Activity "Scanning files" -Status "Counting total files."
	$totalItems = $sourceFolder.Items().Count
	$i = 0

	# Scan the source folder for items which match the filename pattern(s).
	foreach ($item in $sourceFolder.Items()) {
		if ($item.Name -match $regexPattern) {
			$filesToTransfer += $item
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
		$confirmation = Read-Host "$($filesToTransfer.Count) files will be moved from ""$SourceDirectory"" to ""$DestinationDirectory"". Type 'Y' to proceed, any other input to cancel."
		if ($confirmation -eq "Y") {
			# For the moved items progress bar.
			$totalItems = $filesToTransfer.Count
			$i = 0

			foreach ($item in $filesToTransfer) {
				$i++

				if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
					$item = Get-UniqueFilename -Item $item -DestinationFolder $destinationFolder
		
					if ($Move) {
						$destinationFolder.MoveHere($item)
					}
					else {
						$destinationFolder.CopyHere($item)
					}

					Write-Progress -Activity "Transferring files" -Status "$i out of $totalItems $movedCopied." -PercentComplete ($i / $totalItems * 100)
				}
				else {
					# For -WhatIf, just indicate that the file would have been transferred.
					Write-Output "$($item.Name) $movedCopied to destination."
				}
			}

			Write-Output "$i file(s) $movedCopied."
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
		$i++
		if ($item.Name -match $regexPattern) {
			if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
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
			else {
				Write-Output """$($item.Name)"" $movedCopied to destination."
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
