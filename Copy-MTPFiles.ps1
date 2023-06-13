<#
.SYNOPSIS
	This script transfers files to or from a portable device via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts the following parameters:
	- PreScan: A switch which controls whether to scan the source directory before transfers begin. Outputs the number of matching files and allows cancelling before any transfers take place.
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
	[switch]$PreScan,

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
		try {
			$script:ShellApp = New-Object -ComObject Shell.Application
			if ($null -eq $script:ShellApp) {
				throw "Failed to create a COM Shell Application object."
			}	
		}
		catch {
			Write-Error -Message $_
			exit 1
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

	do {
		$newName = "$baseName ($counter)$extension"
		$counter++
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
	else {
		$tempPath | Get-ChildItem | Remove-Item
	}
}

# Copy the file to be transferred into our temporary folder, renaming it if 
# necessary to ensure there is no name conflict with a file in the destination.
# If a duplicate is detected, we append a unique numeric suffix.
function Copy-FileToTemp {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[Alias("Item")]
		[System.__ComObject]$FileItem,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$DestinationFolder
	)

	$tempDirectory = Get-TempFolderPath
	$tempFolder = $script:ShellApp.Namespace($tempDirectory)

	$filename = $FileItem.Name

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

function Get-MTPFolderByName {
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$ParentFolder,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$FolderName
	)

	foreach ($item in $ParentFolder.Items()) {
		Write-Verbose "Checking $($item.Name)..."
		if ($item.IsFolder -and $item.Name -eq $FolderName) {
			return $item.GetFolder
		}
	}

	return $null
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

# Get a COM reference to a directory, creating it if it doesn't already exist.
function Get-COMFolder {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$DirectoryPath
	)

	if (Test-IsHostDirectory($DirectoryPath)) {
		# Is a non-MTP path, i.e. on the host device.
		# Create the path if it doesn't already exist and return a COM reference to it.
		if (-not (Test-Path -Path $DirectoryPath)) {
			try {
				New-Item -Type Directory -Path $DirectoryPath
			}
			catch {
				throw "Could not create directory ""$DirectoryPath"". Please check you have adequate permissions."
			}
			if (-not (Test-Path -Path $DirectoryPath)) {
				# We get here if the Confirm prompt was declined.
				throw "Cannot continue without creating full ""$DirectoryPath"" path."
			}
		}
		return $script:ShellApp.NameSpace([IO.Path]::GetFullPath($DirectoryPath))
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
				throw "Multiple MTP-compatible devices found. Please use the 'DeviceName' parameter to specify the device to use. Use the 'List' switch to list all compatible device names."
			}
		}
		else {
			$device = $devices
		}

		Write-Verbose "Using $($device.Name) ($($device.Type))."
		
		# Retrieve the root folder of the attached device.
		$deviceRoot = $script:ShellApp.Namespace($device.Path)

		# Return a reference to the requested path on the device.
		return Get-MTPFolderByPath -ParentFolder $deviceRoot -FolderPath $DirectoryPath
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

# Transfer a file from the source to the destination, using our temporary
# folder as a working area.
function Send-SingleFile {
	param(
		[Parameter(Mandatory = $true)]
		[System.__ComObject]$FileItem,

		[Parameter(Mandatory = $true)]
		[System.__ComObject]$DestinationFolder,

		[int]$FileNumber,

		[int]$TotalFiles = 0
	)

	$filename = $FileItem.Name

	if ($script:SourceOnHost -and $script:DestinationOnHost) {
		# Use Powershell built-in commands if possible.
		try {
			$destinationUnique = Join-Path -Path $DestinationDirectory -ChildPath (Get-UniqueFilename -Folder $DestinationFolder -Filename $filename)
			if ($Move) {
				Move-Item -Path $item.Path -Destination $destinationUnique -Confirm:$false
			}
			else {
				Copy-Item -Path $item.Path -Destination $destinationUnique -Confirm:$false
			}
		}
		catch {
			throw "Error: unable to transfer the file ""$filename""."
		}
	}
	else {
		try {
			$tempItem = New-TemporaryFile -Item $FileItem -DestinationFolder $DestinationFolder

			if ($Move) {
				$DestinationFolder.MoveHere($tempItem)
			}
			else {
				$DestinationFolder.CopyHere($tempItem)
			}
		}
		catch {
			throw "Error: unable to transfer the file ""$filename""."
		}
		finally {
			# Add the temporary file to the clean-up list.
			$script:FileList.Add((New-Object PSObject -Property @{
				"Path" = $tempItem.Path
				"StartTime" = Get-Date
			}))
		}

		if ($Move) {
			# Add the source file to be cleaned up when finished.
			$script:FileList.Add((New-Object PSObject -Property @{
				"Path" = $FileItem.Path
				"StartTime" = Get-Date
			}))
		}
	}

	if ($TotalFiles -gt 0) {
		Write-Progress -Activity "Transferring files" -Status """$filename"" transferred. $FileNumber out of $TotalFiles $script:MovedCopied." -PercentComplete ($FileNumber / $TotalFiles * 100)
	}
	else {
		Write-Progress -Activity "Transferring files" -Status """$filename"" $script:MovedCopied to destination."
	}
}

function Complete-Transfers {
	param(
		[Parameter(Mandatory = $true)]
		[System.Management.Automation.Job]$CleanupJob,

		[int]$FileCount = 0
	)

	Write-Debug "Adding sentinel value to cleanup list."
	$script:FileList.Add((New-Object PSObject -Property @{
		"Path" = [string]::Empty
		"StartTime" = [datetime]::MinValue
	}))

	Write-Debug "Waiting on cleanup job to complete."
	Wait-Job $CleanupJob

	Write-Debug "Removing completed cleanup job."
	Remove-Job $CleanupJob

	Write-Output "$FileCount file(s) $script:MovedCopied."

	Clear-TempFolder
}


Write-Output "Copy-MTPFiles started."

if ($List) {
	Write-MTPDevices
	return
}

# Used to share details of the transferring files with the cleanup job.
$script:FileList = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# The cleanup job is used to remove temporary files and is also relied upon to keep the script running while transfers are still happening.
$cleanupJob = Start-Job -ScriptBlock {
	param(
		[System.Collections.ArrayList]$SyncFileList
	)

	$timeoutSeconds = 5 * 60
	$running = $true

	while ($running) {
		if ($SyncFileList.Count -gt 0) {
			for ($i = 0; $i -lt $SyncFileList.Count; i++) {
				$file = $SyncFileList[$i]
				# Check for sentinel value. If it's the only one in the list, we've finished.
				if ($file.Path -eq [string]::Empty -and $file.StartTime -eq [datetime]::MinValue) {
					if ($SyncFileList.Count -eq 1) {
						Write-Debug "Finished clean-up on all files."
						$running = $false
					}
					continue
				}

				# Try to open the file for writing, which will fail if the file is still transferring.
				try {
					[IO.File]::OpenWrite($file.Path).Close()
					Remove-Item -Path $file.Path
					$SyncFileList.RemoveAt($i)
					$i--
					Write-Debug "Clean-up: Removed file ""$($file.Path)""."
				}
				catch {
					if (((Get-Date) - $file.StartTime).TotalSeconds -gt $timeoutSeconds) {
						Write-Warning "Timeout reached while waiting for file lock to be released for file $($file.Path)"
						$SyncFileList.RemoveAt($i)
						$i--
					}
					# Next file
					continue
				}
			}
		}

		Start-Sleep -Seconds 1
	}
} -ArgumentList $script:FileList

New-ShellApplication

Clear-TempFolder

Write-Output "`nSource directory: ""$SourceDirectory""", "Destination directory: ""$DestinationDirectory""`n"

if ([string]::IsNullOrEmpty($SourceDirectory)) {
	throw "No source directory provided. Please use the 'SourceDirectory' parameter to set the folder from which to transfer files."
}

if ([string]::IsNullOrEmpty($DestinationDirectory)) {
	throw "No destination directory provided. Please use the 'DestinationDirectory' parameter to set the folder where the files will be transferred."
}

if (($SourceDirectory -eq $DestinationDirectory) -or
	([IO.Path]::GetFullPath($SourceDirectory) -eq [IO.Path]::GetFullPath($DestinationDirectory))) {
	throw "Source and Destination directories cannot be the same."
}

$script:SourceOnHost = Test-IsHostDirectory -DirectoryPath $SourceDirectory
$script:DestinationOnHost = Test-IsHostDirectory -DirectoryPath $DestinationDirectory

$sourceFolder = Get-COMFolder $SourceDirectory
$destinationFolder = Get-COMFolder $DestinationDirectory

$script:MovedCopied = "copied"
if ($Move) {
	$script:MovedCopied = "moved"
}

if ($null -eq $sourceFolder) {
	throw "Source folder ""$SourceDirectory"" could not be found or created."
}

Write-Debug "Found source folder ""$SourceDirectory""."

if ($null -eq $destinationFolder) {
	throw "Destination folder ""$DestinationDirectory"" either not found or could not be created."
}

Write-Debug "Found destination folder ""$DestinationDirectory""."

$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

if ($PSBoundParameters.ContainsKey("PreScan")) {
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
		Write-Output "$($filesToTransfer.Count) file(s) will be transferred from ""$SourceDirectory"" to ""$DestinationDirectory""."
		$totalItems = $filesToTransfer.Count
		$i = 0
		foreach ($item in $filesToTransfer) {
			$i++
			if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
				Send-SingleFile -FileItem $item -DestinationFolder $destinationFolder -FileNumber $i -TotalFiles $totalItems
			}
		}

		Complete-Transfers -CleanupJob $cleanupJob -FileCount $i 
	}
}
else {
	# Transfer files immediately, without scanning or confirmation.
	$i = 0
	foreach ($item in $sourceFolder.Items()) {
		if ($item.Name -match $regexPattern) {
			$i++
			if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
				Send-SingleFile -FileItem $item -DestinationFolder $destinationFolder
			}
		}
	}
	if ($i -eq 0) {
		Write-Output "No matching files found."
	}
	else {
		Complete-Transfers -CleanupJob $cleanupJob -FileCount $i
	}
}

Write-Output "Finished."
