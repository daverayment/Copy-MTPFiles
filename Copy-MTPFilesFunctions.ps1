# Retrieve all the MTP-compatible devices.
function Get-MTPDevice {
	(Get-ShellApplication).NameSpace(17).Items() | Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }
}

# Find a matching device and initialise the script-level Device object with its properties.
function Initialize-DeviceInfo {
	$script:Device = $null
	$devices = Get-MTPDevice

	# There must be at least one device. If multiple devices are found, the device name must be supplied.
	# If the device name is given, it must match, even if only 1 device is present.
	if ($devices -and ($devices.Count -eq 1 -or $DeviceName)) {
		$script:Device = if ($DeviceName) {
			$devices | Where-Object { $_.Name -ieq $DeviceName }
		}
		else {
			$devices
		}
	}
}

# Returns whether the provided path is formatted like one from the host computer.
# Note: this does not check whether the directory exists.
function Test-IsHostDirectory {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath
	)

	return $DirectoryPath.StartsWith('.') -or [System.IO.Path]::IsPathRooted($DirectoryPath) -or $DirectoryPath.Contains('\')
}

# Converts a host path to an absolute path, correctly resolving relative paths.
function Convert-PathToAbsolute {
	param([string]$Path, [boolean]$IsSource)

	if ([System.IO.Path]::IsPathRooted($Path)) {
		return $Path
	}

	$absolutePath = [IO.Path]::GetFullPath((Join-Path -Path $PWD.Path -ChildPath $Path))

	# Check if the resolved path exists.
	if (-not (Test-Path $absolutePath)) {
		# If the path doesn't exist, the last segment is presumed to be a filename or wildcard pattern.
		$directoryPart = Split-Path -Path $absolutePath -Parent
		if (-not (Test-Path -Path $directoryPart -PathType Container)) {
			# For destination paths, we create non-existent directories.
			if ($IsSource) {
				Write-Error "The source directory ""$directoryPart"" does not exist." -ErrorAction Stop -Category ObjectNotFound
			}
		}
	}		

	return $absolutePath
}

# Confirm a directory exists.
function Test-DirectoryExists {
	[CmdletBinding(SupportsShouldProcess=$true)]
	param([string]$Path, [boolean]$IsSource)

	if (Test-Path -Path $Path -PathType Leaf) {
		Write-Error "$(if ($IsSource) { "Source" } else { "Destination" }) path ""$Path"" must be a folder, not a file." -ErrorAction Stop -Category InvalidArgument
	}

	if (-not (Test-Path -Path $Path)) {
		if ($IsSource) {
			Write-Error "Source path ""$Path"" does not exist." -ErrorAction Stop -Category ObjectNotFound
		}
	
		if ($PSCmdlet.ShouldProcess($Path, "Create directory")) {
			New-Item -ItemType Directory -Path $Path -Force | Out-Null
		}
	}
}

# Retrieves a COM reference to a local or device directory. If the directory does not exist,
# it is created. If a device is not specified and multiple MTP-compatible devices are found,
# an error is thrown.
function Get-COMFolder {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath,

		[bool]$IsSource,

		[switch]$IsFileListing
	)

	$maxAttempts = 3
	$currentAttempt = 1
	$retryDelay = 2		# seconds

	if (-not $IsSource -and -not $PSCmdlet.ShouldProcess($DirectoryPath, "Get folder")) {
		return $null
	}

	if (Test-IsHostDirectory -DirectoryPath $DirectoryPath) {
		if (-not (Test-Path -Path $DirectoryPath)) {
			do {
				try {
					New-Item -Type Directory -Path $DirectoryPath -Force | Out-Null

					break	# break out of the retry loop
				}
				catch {
					$retriesLeft = $maxAttempts - $currentAttempt
					Write-Error "Failed to create directory ""$DirectoryPath"". " +
						"$retriesLeft retr$(if ($retriesLeft -eq 1) { "y" } else { "ies" }) left."
						-Category InvalidOperation -TargetObject $DirectoryPath -ErrorVariable folderError
					$currentAttempt++

					Start-Sleep -Seconds $retryDelay
				}	
			} while ($currentAttempt -lt $maxAttempts)

			if ($currentAttempt -eq $numAttempts) {
				throw "Could not create directory ""$DirectoryPath"" after $maxAttempts attempts. Please check you have adequate permissions."
			}
		}
		return (Get-ShellApplication).NameSpace([IO.Path]::GetFullPath($DirectoryPath))
	}

	$devices = Get-MTPDevice

	if (-not $script:Device) {
		throw "No compatible devices found. Please connect a device in Transfer Files mode."
	}
	elseif ($devices.Count -gt 1 -and -not $DeviceName) {
		throw "Multiple MTP-compatible devices found. Please use the '-DeviceName' parameter to specify the " +
			"device to use. Use the '-ListDevices' switch to list connected compatible devices."
	}

	Write-Verbose "Using $($script:Device.Name) ($($script:Device.Type))."

	# Retrieve the root folder of the attached device.
	$deviceRoot = (Get-ShellApplication).Namespace($device.Path)

	# Return a reference to the requested path on the device. Creates folders if required (if the user is not just requesting to list files)
	return Get-MTPFolderByPath -ParentFolder $deviceRoot -FolderPath $DirectoryPath -IsSource $IsSource
		-IsFileListing:$IsFileListing
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
		[string]$FolderPath,

		[bool]$IsSource
	)

	$sections = $FolderPath.Split('/')
	$folderIndex = 0

	# Loop through each path subfolder in turn, creating folders if they don't already exist.
	foreach ($directory in $sections) {
		Write-Progress -Activity "Scanning Device Folders" -Status "Processing ""$directory""" -PercentComplete (($folderIndex / $sections.Count) * 100)
		$nextFolder = $ParentFolder.ParseName($directory)

		# The source folder must exist.
		if ($IsSource -and $null -eq $nextFolder) {
			Write-Error ("Source directory ""$directory"" not found. Check the provided source directory path " +
				"for errors and try again.") -Category ObjectNotFound -TargetObject $directory -ErrorAction Stop
		}

		# If the folder doesn't already exist, try to create it.
		if ($null -eq $nextFolder) {
			# If the user is just listing the folder contents, report error and exit.
			if ($ListFiles) {
				Write-Error "Folder ""$directory"" not found. Please verify the folder path and try again."
					-Category ObjectNotFound -TargetObject $directory -ErrorAction Stop
			}

			if (-not $PSCmdlet.ShouldProcess($directory, "Create directory")) {
				# In the -WhatIf scenario, we do not simulate the creation of missing directories.
				Write-Error "Cannot continue without creating new directory ""$directory"". Exiting."
					-TargetObject $directory -ErrorAction Stop
			}

			$ParentFolder.NewFolder($directory)
			$nextFolder = $ParentFolder.ParseName($directory)

			# If creation failed, write error and stop.
			if ($null -eq $nextFolder) {
				Write-Error ("Could not create new directory ""$directory"". Please confirm you have adequate " +
					"permissions on the device.") -Category PermissionDenied -TargetObject $directory -ErrorAction Stop
			}

			Write-Verbose "Created new directory ""$directory""."
		}
		# If the item was found but it isn't a folder, write error and stop.
		elseif (-not $nextFolder.IsFolder) {
			Write-Error "Cannot navigate to ""$FolderPath"". A file already exists called ""$directory""."
				-Category WriteError -TargetObject $directory -ErrorAction Stop
		}

		# Continue looping until all subfolders have been navigated.
		$ParentFolder = $nextFolder.GetFolder

		$folderIndex++
		Write-Progress -Activity "Scanning Device Folders" -Status "Completed processing ""$directory""" -PercentComplete (($folderIndex / $sections.Count) * 100)
	}

	Write-Progress -Activity "Scanning Device Folders" -Completed

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

# Generate a unique filename in the destination directory. If the passed-in filename already exists, a new
# filename is generated with a numeric suffix in parentheses. An upper-bound of 1000 files with the same
# basename is used. If this limit is exceeded, an exception is thrown.
function Get-UniqueFilename {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$Folder,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$Filename
	)

	# If the filename does not exist, simply return it.
	if (-not ($Folder.ParseName($Filename))) {
		return $Filename
	}

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
	} while ($Folder.ParseName($newName))

	return $newName
}

# Delete any pre-existing temporary directories we created.
function Reset-TemporaryDirectory {
	[CmdletBinding(SupportsShouldProcess=$true)]
	param()

	if ($PSCmdlet.ShouldProcess("Temporary folders", "Delete")) {
		Get-ChildItem -Path $Env:TEMP -Directory |
			Where-Object { $_.Name -like "CopyMTPFiles*" } |
			ForEach-Object { Remove-Item -Path $_.FullName -Recurse -Force }
	}
}

# Create a uniquely-named temporary directory for this run.
function New-TempDirectory {
	[CmdletBinding(SupportsShouldProcess=$true)]
	param()

	$rnd = Get-Random -Maximum 1000	# 0-999
	$tempDirectoryName = "CopyMTPFiles{0:D3}" -f $rnd
	$tempDirectoryPath = Join-Path -Path $Env:TEMP -ChildPath $tempDirectoryName
	if ($PSCmdlet.ShouldProcess($tempDirectoryPath, "Create temporary directory")) {
		New-Item -Path $tempDirectoryPath -ItemType Directory | Out-Null
	}

	$tempDirectoryPath
}

# Copy the file to be transferred into our temporary folder, renaming it if
# necessary to ensure there is no name conflict with a file in the destination.
# If a duplicate is detected, we append a unique numeric suffix.
function Copy-SourceFileToTemporaryDirectory {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$FileItem
	)

	$filename = $FileItem.Name

	# Always copy. If it's a move operation, the source file will be cleaned up post-transfer.
	$script:TempDetails.Folder.CopyHere($FileItem)

	# Does the file need to be renamed?
	if ($script:DestinationDetails.Folder.ParseName($filename))
	{
		$newName = Get-UniqueFilename -Folder $script:DestinationDetails.Folder -Filename $filename
		Write-Warning "A file with the same name already exists. The source file ""$filename"" will be transferred as ""$newName""."

		$tempFilePathOld = Join-Path -Path $script:TempDetails.Directory -ChildPath $filename
		$tempFilePathNew = Join-Path -Path $script:TempDetails.Directory -ChildPath $newName
		Rename-Item -Path $tempFilePathOld -NewName $tempFilePathNew -Force
		$filename = $newName
	}

	# Return the newly-transferred temp file.
	return $script:TempDetails.Folder.ParseName($filename)
}

# Remove a file from the host or an attached device, waiting for any activity on it to finish first.
function Remove-LockedFile {
	[CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [System.__ComObject]$FileItem,

		[System.__ComObject]$Folder,

		[bool]$IsOnHost = $true,

        [int]$TimeoutSeconds = 5 * 60
    )

	if ($PSCmdlet.ShouldProcess($FileItem.Path, "Remove file")) {
		Write-Debug "Removing file '$($FileItem.Path)'..."

		$start = Get-Date

		# First wait for the file to start transferring.
		$file = $script:DestinationDetails.Folder.ParseName($FileItem.Name)
		while ($null -eq $file) {
			Write-Debug "Waiting for file '$($FileItem.Path)' to start transferring..."

			if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
				Write-Error "Removal of file '$($FileItem.Path)' timed out after $TimeoutSeconds seconds."
					-Category ResourceUnavailable -ErrorAction Inquire

				# The user has chosen to wait for another timeout period to elapse.
				# (In non-interactive sessions, the script will have exited.)
				$start = Get-Date
			}

			Start-Sleep -Milliseconds 500

			$file = $script:DestinationDetails.Folder.ParseName($FileItem.Name)
		}

		do {
			try {
				if ($IsOnHost) {
					Remove-Item $FileItem.Path
				}
				else {
					$Folder.Delete($FileItem.Name)
				}

				$locked = $false
			}
			catch {
				# If we catch an exception, the file is locked.
				Write-Debug "File '$($FileItem.Path)' is locked."
				$locked = $true

				if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
					Write-Error -Message "Removal of file '$($FileItem.Path)' timed out after $TimeoutSeconds seconds."
						-Category ResourceUnavailable -ErrorAction Inquire

					# User chose to continue waiting.
					$start = Get-Date
				}

				Start-Sleep -Milliseconds 500
			}
		} while ($locked)

		Write-Debug "File '$($FileItem.Path)' removed."
	}
}

function Get-FileList {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath,

		[string]$RegexPattern
	)

	if (Test-IsHostDirectory -DirectoryPath $DirectoryPath) {
		if (-not (Test-Path -Path $DirectoryPath)) {
			Write-Error "Directory ""$DirectoryPath"" does not exist." -ErrorAction Stop
		}
		$items = Get-ChildItem -Path $DirectoryPath
		if ($RegexPattern) {
			$items = $items | Where-Object { $_.Name -match $RegexPattern }
		}
		return $items
	}

	$folder = Get-COMFolder -DirectoryPath $DirectoryPath -IsFileListing

	# 0..287 | Foreach-Object {
	# 	$propertyValue = $folder.GetDetailsOf($item, $_)
	# 	if ($propertyValue) {
	# 		$propertyName = $folder.GetDetailsOf($null, $_)
	# 		Write-Output "$_ > $propertyName : $propertyValue"
	# 	}
	# }

	foreach ($item in $folder.Items()) {
		if ($RegexPattern -and -not ($item.Name -match $RegexPattern)) {
			continue
		}
		Format-Item $item $folder
	}
}

# Format a folder item for output.
function Format-Item {
	param(
		[Parameter(Mandatory = $true)]
		[System.__ComObject]$Item,

		[Parameter(Mandatory = $true)]
		[System.__ComObject]$Folder
	)

	$fileObj = New-Object PSObject -Property @{
		Type = $Item.Type
		LastWriteTime = "{0:d}    {0:t}" -f [DateTime]::Parse($Folder.GetDetailsOf($Item, 3))
		Length = $Item.ExtendedProperty("Size")
		Name = $Item.Name
#		IsFolder = $Item.IsFolder
	}

	$fileObj.PSTypeNames.Insert(0, "MTP.File")

	return $fileObj
}