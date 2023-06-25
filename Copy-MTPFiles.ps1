<#
.SYNOPSIS
	This script transfers files to or from a portable device via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts the following parameters:
	- Scan (Alias: PreScan): A switch which controls whether to scan the source directory before transfers begin. Outputs the number of matching files and allows cancelling before any transfers take place.
	- Move: A switch which, when included, moves files instead of the default of copying them.
	- List (Alias: l): A switch for listing the attached MTP-compatible devices. Use this option to get the names for the -DeviceName parameter. All other parameters will be ignored if this is present.
	- DeviceName (Aliases: Device, dn): The name of the attached device. Must be used if more than one compatible device is attached. Use the -List switch to get the names of MTP-compatible devices.
	- SourceDirectory (Aliases: SourceFolder, Source, s): The path to the source directory. Defaults to the current path if not specified.
	- DestinationDirectory (Aliases: DestinationFolder, Destination, Dest, d): The path to the destination directory. Defaults to the current path if not specified.
	- FilenamePatterns (Aliases: Patterns, p): An array of filename patterns to search for. Defaults to matching all files. Separate multiple patterns with commas.
.LINK
	https://github.com/daverayment/Copy-MTPFiles
.NOTES
	Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.
.EXAMPLE
	Move files with a .doc or .pdf extension from the Download directory on the device to a specified directory on the host:
	
	.\Copy-MTPFiles.ps1 -Move -Source "Internal storage/Download" -Destination "C:\Projects\Documents" -Patterns "*.doc", "*.pdf"
.EXAMPLE
	Copy files with a .jpg extension from the Download directory on the device to the current folder:

	.\Copy-MTPFiles.ps1 "Internal storage/Download" -FilenamePatterns "*.jpg"
.EXAMPLE
	Move all files from the current directory on the host computer to the Download directory on the portable device:

	.\Copy-MTPFiles.ps1 -Move -Source "." -Destination "Internal storage/Download"
.EXAMPLE
	List all compatible devices which are currently attached:

	.\Copy-MTPFiles.ps1 -l
#>
[CmdletBinding(SupportsShouldProcess)]
param(
	[Alias("Scan")]
	[switch]$PreScan,

	[switch]$Move,

	[Alias("l")]
	[switch]$List,

	[Alias("Device", "dn")]
	[string]$DeviceName,

	[Alias("SourceFolder", "Source", "s")]
	[ValidateNotNullOrEmpty()]
	[string]$SourceDirectory = $PWD.Path,

	[Alias("DestinationFolder", "Destination", "Dest", "d")]
	[ValidateNotNullOrEmpty()]
	[string]$DestinationDirectory = $PWD.Path,

	[Alias("Patterns", "p")]
	[string[]]$FilenamePatterns = "*"
)

. ./Copy-MTPFilesFunctions.ps1

# Check script parameters and setup script-level variables for source and destination.
function Set-TransferDirectories {
	if ([string]::IsNullOrEmpty($SourceDirectory)) {
		Write-Error ("No source directory provided. Please use the 'SourceDirectory' parameter to set the folder " +
			"from which to transfer files.") -ErrorAction Stop
	}
	if ([string]::IsNullOrEmpty($DestinationDirectory)) {
		Write-Error ("No destination directory provided. Please use the 'DestinationDirectory' parameter to set " +
			"the folder where the files will be transferred.") -ErrorAction Stop
	}

	$script:SourceOnHost = Test-IsHostDirectory -DirectoryPath $SourceDirectory
	$script:DestinationOnHost = Test-IsHostDirectory -DirectoryPath $DestinationDirectory

	if ($script:SourceOnHost) {
		$SourceDirectory = Convert-PathToAbsolute -Path $SourceDirectory
	}
	if ($script:DestinationOnHost) {
		$DestinationDirectory = Convert-PathToAbsolute -Path $DestinationDirectory
	}

	$script:SourceFolder = Get-COMFolder -DirectoryPath $SourceDirectory -DeviceName $DeviceName
	$script:DestinationFolder = Get-COMFolder -DirectoryPath $DestinationDirectory -DeviceName $DeviceName

	Write-Output "`nSource directory: ""$SourceDirectory""", "Destination directory: ""$DestinationDirectory""`n"

	if ($SourceDirectory -ieq $DestinationDirectory) {
		Write-Error "Source and Destination directories cannot be the same." -ErrorAction Stop
	}

	$script:MovedCopied = "copied"
	if ($Move) {
		$script:MovedCopied = "moved"
	}

	if ($null -eq $script:SourceFolder) {
		Write-Error "Source folder ""$SourceDirectory"" could not be found or created." -ErrorAction Stop
	}

	Write-Debug "Found source folder ""$SourceDirectory""."

	if ($null -eq $script:DestinationFolder) {
		Write-Error "Destination folder ""$DestinationDirectory"" could not be found or created." -ErrorAction Stop
	}

	Write-Debug "Found destination folder ""$DestinationDirectory""."
}

# Ensure we have a script-level Shell Application object for COM interactions.
function Get-ShellApplication {
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

	$script:ShellApp
}


# Transfer a file from the source to the destination or queue it for transfer if it requires MTP transfer.
function Send-SingleFile {
	param(
		[Parameter(Mandatory = $true)]
		[System.__ComObject]$FileItem,

		[Array]$Jobs,

		[int]$TotalFiles,

		[int]$FileNumber
	)

	$filename = $FileItem.Name
	# TODO: Cache the temp vars so they aren't recalculated each time through?
	$tempDirectory = Get-TempFolderPath
	$tempFolder = (Get-ShellApplication).Namespace($tempDirectory)

	if ($script:SourceOnHost -and $script:DestinationOnHost) {
		# Use synchronous Powershell built-in commands if possible.
		try {
			$destinationUnique = Join-Path -Path $DestinationDirectory -ChildPath (Get-UniqueFilename -Folder $script:DestinationFolder -Filename $filename)
			if ($Move) {
				Move-Item -Path $item.Path -Destination $destinationUnique -Confirm:$false
			}
			else {
				Copy-Item -Path $item.Path -Destination $destinationUnique -Confirm:$false
			}
		}
		catch {
			Write-Error "Error: Unable to transfer the file ""$filename"". Exception: $($_.Exception.Message)"
			if ($_.Exception.InnerException) {
				Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
			}
		}
	}
	else {
		# Queue for async processing otherwise.
		try {
			$jobId = $currentJobId++

			# $job = Start-Job -ScriptBlock {
			# 	param(
			# 		$FnNewTempFile,
			# 		$JobId,
			# 		$FileItem,
			# 		$DestinationFolder,
			# 		$TempDirectory,
			# 		$TempFolder,
			# 		$Move
			# 	)
			# 	. ${function:FnNewTempFile}

				$timeoutSeconds = 5 * 60
				$filename = $FileItem.Name

				Write-Debug ("JOB {0:D4}: START. Beginning transfer of file ""$filename""." -f $JobId)

				$tempFile = New-TemporaryFile $FileItem $DestinationFolder $TempDirectory $TempFolder

				# Transfer the file to the destination folder.
				$DestinationFolder.CopyHere($tempFile)

				# Clean-up the temp file.
				Remove-LockedFile -FilePath $tempFile.Path

				if ($Move) {
					# Remove the source file.
					Remove-LockedFile -FilePath $item.Path
				}

			# } -ArgumentList ${function:New-TemporaryFile}, $jobId, $FileItem, $script:DestinationFolder, $tempDirectory, $tempFolder, $Move

			$Jobs += $job
		}
		catch {
			Write-Error "Error: Unable to queue the file ""$filename"" for transfer. Exception: $($_.Exception.Message)"
			if ($_.Exception.InnerException) {
				Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
			}
		}
	}

	if ($Wait -and $null -ne $script:LastTemporaryFileItem) {
		Remove-LockedFile -FileItem $script:LastTemporaryFileItem -Folder $script:TempFolder
	}
}


Write-Output "Copy-MTPFiles started."

if ($List) {
	Show-MTPDevices
	return
}

Clear-TempFolder

Set-TransferDirectories

$tempDirectory = Get-TempFolderPath
$tempFolder = (Get-ShellApplication).Namespace($tempDirectory)

$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

$currentJobId = 1
$jobs = @()

if ($PSBoundParameters.ContainsKey("PreScan")) {
	# Holds all the files in the source directory which match the file pattern(s).
	$filesToTransfer = @()

	# For the scanned items progress bar.
	Write-Progress -Activity "Scanning files" -Status "Counting total files."
	$totalItems = $script:SourceFolder.Items().Count
	$i = 0

	# Scan the source folder for items which match the filename pattern(s).
	foreach ($item in $script:SourceFolder.Items()) {
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
				Send-SingleFile -FileItem $item -FileNumber $i -TotalFiles $totalItems
			}
		}

		Complete-FileTransfers -CleanupJob $cleanupJob -FileCount $i 
	}
}
else {
	# Transfer files immediately, without scanning or confirmation.
	$i = 0
	foreach ($item in $script:SourceFolder.Items()) {
		if ($item.Name -match $regexPattern) {
			$i++
			if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
				Send-SingleFile -FileItem $item -DestinationFolder $script:DestinationFolder
			}
		}
	}
	if ($i -eq 0) {
		Write-Output "No matching files found."
	}
	else {
		Complete-FileTransfers -CleanupJob $cleanupJob -FileCount $i
	}
}

Write-Output "Finished."
