# Retrieve all the MTP-compatible devices.
function Get-MTPDevices {
	(Get-ShellApplication).NameSpace(17).Items() | Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }
}

# Lists all the attached MTP-compatible devices.
function Show-MTPDevices {
	$devices = Get-MTPDevices

	if ($devices.Count -eq 0) {
		Write-Host "No MTP-compatible devices found."
	}
	elseif ($devices.Count -eq 1) {
		Write-Host "One MTP device found."
		Write-Host "  Device name: $($devices.Name), Type: $($devices.Type)"
	}
	else {
		Write-Host "Listing attached MTP devices."
		foreach ($device in $devices) {
			Write-Host "  Device name: $($device.Name), Type: $($device.Type)"
		}
	}
}

# Returns whether the provided path is formatted like one from the host
# computer. Note: this does not check whether the directory exists.
function Test-IsHostDirectory {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath
	)

	return $DirectoryPath.StartsWith('.') -or [System.IO.Path]::IsPathRooted($DirectoryPath)
}

function Convert-PathToAbsolute {
	param([string]$Path)

	if ([System.IO.Path]::IsPathRooted($Path)) {
		return $Path
	}
	else {
		# How many times can I write Path on a single line?
		return (Resolve-Path -Path (Join-Path -Path $PWD.Path -ChildPath $Path)).Path
	}
}

function Get-COMFolder {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath
	)

	if (Test-IsHostDirectory($DirectoryPath)) {
		if (-not (Test-Path -Path $DirectoryPath)) {
			try {
				New-Item -Type Directory -Path $DirectoryPath -Force
			}
			catch {
				throw "Could not create directory ""$DirectoryPath"". Please check you have adequate permissions."
			}				
		}
		return (Get-ShellApplication).NameSpace([IO.Path]::GetFullPath($DirectoryPath))
	}
	else {
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
				throw "Multiple MTP-compatible devices found. Please use the '-DeviceName' parameter to " +
					"specify the device to use. Use the '-List' switch to list all compatible device names."
			}
		}
		else {
			$device = $devices
		}

		Write-Verbose "Using $($device.Name) ($($device.Type))."
		
		# Retrieve the root folder of the attached device.
		$deviceRoot = (Get-ShellApplication).Namespace($device.Path)

		# Return a reference to the requested path on the device.
		return Get-MTPFolderByPath -ParentFolder $deviceRoot -FolderPath $DirectoryPath
	}
}

# Retrieve an MTP folder by path. Returns $null if part of the path is not found.
function Get-MTPFolderByPath {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$ParentFolder,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$FolderPath
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
				# In the -WhatIf scenario, we do not simulate the creation of missing directories.
				throw "Cannot continue without creating new directory ""$directory"". Exiting."
			}
		}
		if ($null -eq $nextFolder) {
			throw "Could not create new directory ""$directory"". Please confirm you have adequate " +
				"permissions on the device."
		}

		# Continue looping until all subfolders have been navigated.
		$ParentFolder = $nextFolder.GetFolder
	}

	return $ParentFolder
}

# For more efficient processing, create a single regular expression to represent the filename patterns.
function Convert-WildcardsToRegex {
    param(
        [Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
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

# Generate a new filename with a unique number suffix.
# Note: this function does not currently have an upper bound for the numeric suffix.
function Get-UniqueFilename {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$Folder,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$Filename
	)

	$baseName = [IO.Path]::GetFileNameWithoutExtension($Filename)
	$extension = [IO.Path]::GetExtension($Filename)
	$counter = 1
	$limit = 999

	do {
		$newName = "$baseName ($counter)$extension"
		$counter++
		if ($counter -gt $limit) {
			throw "Reached iteration limit ($limit) while trying to generate a unique filename."
		}
	}
	while ($Folder.ParseName($newName))

	return $newName
}

function Get-TempFolderPath {
	return Join-Path -Path $Env:TEMP -ChildPath "TempCopyMTPFiles"
}

function Clear-TempFolder {
	$tempPath = Get-TempFolderPath

	if (-not (Test-Path -Path $tempPath)) {
		New-Item -Path $tempPath -ItemType Directory | Out-Null
	}

	# Remove all files (including hidden and system files) from our temp folder.
	Get-ChildItem -Path $tempPath -Recurse -Force | Remove-Item -Force -Recurse
}

# Copy the file to be transferred into our temporary folder, renaming it if 
# necessary to ensure there is no name conflict with a file in the destination.
# If a duplicate is detected, we append a unique numeric suffix.
function New-TemporaryFile {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$FileItem,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$DestinationFolder,

		[string]$TempDirectory,

		[System.__ComObject]$TempFolder
	)

	$filename = $FileItem.Name

	# TODO: is -Force necessary here to account for the possibility of a file with the same name already existing?
	Write-Debug "Transferring $filename to temporary folder..."
	if ($Move) {
		$tempFolder.MoveHere($FileItem)
	}
	else {
		$tempFolder.CopyHere($FileItem)
	}
	Write-Debug "Done"

	# Does the file need to be renamed?
	if ($DestinationFolder.ParseName($filename))
	{
		$newName = Get-UniqueFilename -Folder $DestinationFolder -Filename $filename
		Write-Warning "A file with the same name already exists. Renaming to $newName."

		$tempFilePathOld = Join-Path -Path $tempDirectory -ChildPath $filename
		$tempFilePathNew = Join-Path -Path $tempDirectory -ChildPath $newName
		Rename-Item -Path $tempFilePathOld -NewName $tempFilePathNew -Force
		$filename = $newName
	}

	# Return the newly-transferred temp file.
	return $tempFolder.ParseName($filename)
}

function Remove-LockedFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,

        [int]$TimeoutSeconds = 5 * 60
    )

    # Wait for the file to be released.
    $start = Get-Date

    do {
		try {
			Remove-Item $FilePath
			$locked = $false
		}
        catch {
            # If we catch an exception, the file is locked
            Write-Debug "File '$FilePath' is locked."
            $locked = $true

			if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
				throw "Removal of file '$FilePath' timed out."
			}

            Start-Sleep -Milliseconds 500
        }
    } while ($locked)
}
