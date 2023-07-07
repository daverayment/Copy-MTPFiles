# Retrieve all the MTP-compatible devices.
function Get-MTPDevices {
	(Get-ShellApplication).NameSpace(17).Items() | Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }
}

# Find a matching device and initialise the script-level Device object with its properties.
function Set-DeviceInfo {
	$script:Device = $null
	$devices = Get-MTPDevices

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

# Converts a path to an absolute path, correctly resolving relative paths.
function Convert-PathToAbsolute {
	[CmdletBinding(SupportsShouldProcess=$true)]
	param([string]$Path)

	if ([System.IO.Path]::IsPathRooted($Path)) {
		return $Path
	}
	else {
		$absPath = Join-Path -Path $PWD.Path -ChildPath $Path
		if (-not (Test-Path $absPath) -and $PSCmdlet.ShouldProcess($absPath, "Create directory")) {
			New-Item -ItemType Directory -Path $absPath -Force | Out-Null
		}

		if (Test-Path $absPath) {
			return (Resolve-Path -Path $absPath).Path
		}
		else {
			return $absPath
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

		[string]$DeviceName,

		[bool]$IsSource
	)

	if (-not $IsSource -and -not $PSCmdlet.ShouldProcess($DirectoryPath, "Get folder")) {
		return $null
	}

	if (Test-IsHostDirectory -DirectoryPath $DirectoryPath) {
		if (-not (Test-Path -Path $DirectoryPath)) {
			try {
				New-Item -Type Directory -Path $DirectoryPath -Force | Out-Null
			}
			catch {
				Write-Error "Failed to create directory ""$DirectoryPath"". Exception: $($_.Exception.Message)"
				if ($_.Exception.InnerException) {
					Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
				}
				throw "Could not create directory ""$DirectoryPath"". Please check you have adequate permissions."
			}				
		}
		return (Get-ShellApplication).NameSpace([IO.Path]::GetFullPath($DirectoryPath))
	}

	# Retrieve the portable devices connected to the computer.
	$devices = Get-MTPDevices

	if ($null -eq $devices) {
		throw "No compatible devices found. Please connect a device in Transfer Files mode."
	}
	elseif ($devices.Count -gt 1 -and -not $DeviceName) {
		throw "Multiple MTP-compatible devices found. Please use the '-DeviceName' parameter to specify the device to use. Use the '-ListDevices' switch to list connected compatible devices."
	}

	$device = if ($DeviceName) {
		$devices | Where-Object { $_.Name -ieq $DeviceName }
	}
	else {
		$devices
	}
	
	if (-not $device) {
		throw "Device ""$DeviceName"" not found."
	}

	Write-Verbose "Using $($device.Name) ($($device.Type))."
	
	# Retrieve the root folder of the attached device.
	$deviceRoot = (Get-ShellApplication).Namespace($device.Path)

	# Return a reference to the requested path on the device. Creates folders if required.
	return Get-MTPFolderByPath -ParentFolder $deviceRoot -FolderPath $DirectoryPath -IsSource $IsSource
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
	foreach ($directory in $FolderPath.Split('/')) {
		Write-Progress -Activity "Scanning Device Folders" -Status "Processing ""$directory""" -PercentComplete (($folderIndex / $sections.Count) * 100)
		$nextFolder = $ParentFolder.ParseName($directory)

		# The source folder must exist.
		if ($IsSource -and $null -eq $nextFolder) {
			Write-Error "Source directory ""$directory"" not found." -ErrorAction Stop
		}

		# If the folder doesn't already exist, try to create it.
		if ($null -eq $nextFolder) {
			if ($ListFiles -or $ScanOnly) {
				Write-Error "Folder ""$directory"" not found. Exiting." -ErrorAction Stop
			}

			if (-not $PSCmdlet.ShouldProcess($directory, "Create directory")) {
				# In the -WhatIf scenario, we do not simulate the creation of missing directories.
				Write-Error "Cannot continue without creating new directory ""$directory"". Exiting." -ErrorAction Stop
			}

			$ParentFolder.NewFolder($directory)
			$nextFolder = $ParentFolder.ParseName($directory)

			# If creation failed, write error and stop.
			if ($null -eq $nextFolder) {
				Write-Error ("Could not create new directory ""$directory"". Please confirm you have adequate " +
					"permissions on the device.") -ErrorAction Stop
			}

			Write-Host "created."
		}
		# If the item was found but it isn't a folder, write 
		elseif (-not $nextFolder.IsFolder) {
			Write-Error "Cannot navigate to ""$FolderPath"". A file already exists called ""$directory""." -ErrorAction Stop
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

# Delete any pre-existing temporary directories.
function Remove-TempDirectories {
	Get-ChildItem -Path $Env:TEMP -Directory |
		Where-Object { $_.Name -like "CopyMTPFiles*" } |
		ForEach-Object { Remove-Item -Path $_.FullName -Recurse -Force }
}

# Create a uniquely-named temporary directory for this run.
function New-TempDirectory {
	$rnd = Get-Random -Maximum 1000	# 0-999
	$tempDirectoryName = "CopyMTPFiles{0:D3}" -f $rnd
	$tempDirectoryPath = Join-Path -Path $Env:TEMP -ChildPath $tempDirectoryName
	New-Item -Path $tempDirectoryPath -ItemType Directory | Out-Null

	$tempDirectoryPath
}

# Copy the file to be transferred into our temporary folder, renaming it if 
# necessary to ensure there is no name conflict with a file in the destination.
# If a duplicate is detected, we append a unique numeric suffix.
function New-TemporaryFile {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$FileItem
	)

	$filename = $FileItem.Name

	# Always copy. If it's a move operation, the source file will be cleaned up post-transfer.
	$script:Temp.Folder.CopyHere($FileItem)

	# Does the file need to be renamed?
	if ($script:Destination.Folder.ParseName($filename))
	{
		$newName = Get-UniqueFilename -Folder $script:Destination.Folder -Filename $filename
		Write-Warning "A file with the same name already exists. The source file '$filename' will be transferred as '$newName'."

		$tempFilePathOld = Join-Path -Path $script:Temp.Directory -ChildPath $filename
		$tempFilePathNew = Join-Path -Path $script:Temp.Directory -ChildPath $newName
		Rename-Item -Path $tempFilePathOld -NewName $tempFilePathNew -Force
		$filename = $newName
	}

	# Return the newly-transferred temp file.
	return $script:Temp.Folder.ParseName($filename)
}

# Remove a file from the host or an attached device, waiting for any activity on it to finish first.
function Remove-LockedFile {
    param(
        [Parameter(Mandatory=$true)]
        [System.__ComObject]$FileItem,

		[System.__ComObject]$Folder,

		[bool]$IsOnHost = $true,

        [int]$TimeoutSeconds = 5 * 60
    )

	Write-Debug "Removing file '$($FileItem.Path)'..."

    $start = Get-Date

	# First wait for the file to start transferring.
	$file = $script:Destination.Folder.ParseName($FileItem.Name)
	while ($null -eq $file) {
		Write-Debug "Waiting for file '$($FileItem.Path)' to start transferring..."

		if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
			throw "Removal of file '$($FileItem.Path)' timed out."
		}

		Start-Sleep -Milliseconds 500
		
		$file = $script:Destination.Folder.ParseName($FileItem.Name)
		# TODO: timeout
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
				throw "Removal of file '$($FileItem.Path)' timed out."
			}

			Start-Sleep -Milliseconds 500
		}
	} while ($locked)

	Write-Debug "File '$($FileItem.Path)' removed."
}

function List-Files {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath,

		[string]$DeviceName
	)

	if (Test-IsHostDirectory -DirectoryPath $DirectoryPath) {
		return Get-ChildItem -Path $DirectoryPath
	}

	$folder = Get-COMFolder -DirectoryPath $DirectoryPath -DeviceName $DeviceName
	
	$folder.Items() | ForEach-Object {
		# 0..287 | Foreach-Object {
		# 	$propertyValue = $folder.GetDetailsOf($item, $_)
		# 	if ($propertyValue) {
		# 		$propertyName = $folder.GetDetailsOf($null, $_)
		# 		Write-Output "$_ > $propertyName : $propertyValue"
		# 	}
		# }
		
		Format-Item $_ $folder
	} |
	Sort-Object { -not $_.IsFolder }, Name | 
	Select-Object Type, LastWriteTime, Length, Name
}

# Format a folder item for output.
function Format-Item {
	param(
		[Parameter(Mandatory = $true)]
		[System.__ComObject]$Item,

		[Parameter(Mandatory = $true)]
		[System.__ComObject]$Folder
	)

	New-Object PSObject -Property @{
		Type = $Item.Type
		LastWriteTime = [DateTime]::Parse($Folder.GetDetailsOf($Item, 3))
		Length = $Item.ExtendedProperty("Size")
		Name = $Item.Name
		IsFolder = $Item.IsFolder
	}
}