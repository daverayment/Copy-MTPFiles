# Returns whether the provided path is formatted like one from the host computer.
# Note: this does not check whether the directory exists.
function Test-IsHostDirectory {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath
	)

	# Device paths contain forward slashes.
	if ($DirectoryPath -contains '/') {
		return $false
	}

	return $DirectoryPath.StartsWith('.') -or
		[System.IO.Path]::IsPathRooted($DirectoryPath) -or
		$DirectoryPath.Contains('\')
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

# Ensure a host directory exists, creating it if necessary.
function Confirm-HostDirectoryExists {
	[CmdletBinding(SupportsShouldProcess = $true)]
	param(
		[Parameter(Mandatory = $true)]
		[string]$DirectoryPath
	)

	if (Test-Path -Path $DirectoryPath -PathType Leaf) {
		Write-Error "Path ""$DirectoryPath"" must be a folder, not a file." -ErrorAction Stop -Category InvalidArgument
	}

	if (-not (Test-Path -Path $DirectoryPath -PathType Container)) {
		Write-Verbose "Creating directory ""$DirectoryPath""."

		try {
			Invoke-WithRetry -Command { New-Item -Type Directory -Path $using:DirectoryPath -Force | Out-Null }
		}
		catch {
			throw "Could not create directory ""$DirectoryPath"" after $maxAttempts attempts. Please check you have adequate permissions."
		}
	}
}

# Returns a COM reference to a directory on the host.
function Get-HostCOMFolder {
	param(
		[Parameter(Mandatory = $true)]
		[string]$DirectoryPath,
		[switch]$CreateIfNotExists
	)

	if ($CreateIfNotExists) {
		Confirm-HostDirectoryExists -DirectoryPath $DirectoryPath
	}
	return (Get-ShellApplication).NameSpace([IO.Path]::GetFullPath($DirectoryPath))
}

# Retrieves a COM reference to a host or device directory, creating the path if required.
function Get-COMFolder {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$Path,

		[Object]$Device,
		# [System.__ComObject]$Device

		[switch]$CreateIfNotExists
	)

	if (Test-IsHostDirectory -DirectoryPath $Path) {
		return Get-HostCOMFolder -DirectoryPath $Path -CreateIfNotExists:$CreateIfNotExists
	} else {
		# Retrieve the root folder of the attached device.
		$deviceRoot = (Get-ShellApplication).Namespace($Device.Path)

		# Return a reference to the requested path on the device.
		return Get-DeviceCOMFolder -ParentFolder $deviceRoot -FolderPath $Path -CreateIfNotExists:$CreateIfNotExists
	}
}

# Retries a command until it succeeds or the maximum number of attempts is reached. With exponential backoff.
function Invoke-WithRetry {
	param(
		[Parameter(Mandatory = $true)]
		[scriptblock]$Command,

		[int]$MaxAttempts = 3,

		[int]$RetryDelay = 1	# seconds
	)

	$currentAttempt = 0

	while ($true) {
		try {
			$currentAttempt++
			$Command.Invoke()
			return
		}
		catch {
			if ($currentAttempt -eq $MaxAttempts) {
				throw
			}

			Write-Warning "Attempt $currentAttempt of $MaxAttempts failed. Retrying in $RetryDelay seconds."
			Start-Sleep -Seconds $RetryDelay
			$RetryDelay *= 2	# exponential backoff
		}
	}
}

function Test-HasWritePermission {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$tempFile = Join-Path -Path $Path -ChildPath ([Guid]::NewGuid().ToString() + ".tmp")

	# TODO: use Invoke-WithRetry?

	try {
		New-Item -Path $tempFile -ItemType File -ErrorAction Stop | Out-Null

		Remove-Item -Path $tempFile -ErrorAction Stop

		return $true
	}
	catch {
		return $false
	}
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
		[string]$Path,

		[string]$RegexPattern,

		[System.__ComObject]$Device = $null
	)

	if (Test-IsHostDirectory -DirectoryPath $Path) {
		if (-not (Test-Path -Path $Path)) {
			Write-Error "Directory ""$Path"" does not exist." -ErrorAction Stop
		}
		$items = Get-ChildItem -Path $Path
		if ($RegexPattern) {
			$items = $items | Where-Object { $_.Name -match $RegexPattern }
		}
		return $items
	} else {
		$folder = Get-COMFolder -Path $Path -Device $Device

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