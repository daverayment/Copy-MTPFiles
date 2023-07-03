<#
.SYNOPSIS
	This script transfers files to or from a portable device via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts the following parameters:
	- Scan (Alias: PreScan): A switch which controls whether to scan the source directory before transfers begin. Outputs the number of matching files and allows cancelling before any transfers take place.
	- Move: A switch which, when included, moves files instead of the default of copying them.
	- ListDevices (Aliases: GetDevices, ld): A switch for listing the attached MTP-compatible devices. Use this option to get the names for the -DeviceName parameter. All other parameters will be ignored if this is present.
	- DeviceName (Aliases: Device, dn): The name of the attached device. Must be used if more than one compatible device is attached. Use the -List switch to get the names of MTP-compatible devices.
	- ListFiles (Aliases: GetFiles, lf, ls): Lists all files in the specified directory. For host directories, this returns a PowerShell file listing as usual; for device directories, this returns objects with Name, Length, LastWriteTime and Type properties.
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
	[Alias("SourceFolder", "Source", "s")]
	[ValidateNotNullOrEmpty()]
	[Parameter(Position=0)]
	[string]$SourceDirectory = $PWD.Path,

	[Alias("DestinationFolder", "Destination", "Dest", "d")]
	[ValidateNotNullOrEmpty()]
	[Parameter(Position=1)]
	[string]$DestinationDirectory = $PWD.Path,

	[Alias("Scan")]
	[switch]$PreScan,

	[switch]$Move,

	[Alias("GetDevices", "ld")]
	[switch]$ListDevices,

	[Alias("Device", "dn")]
	[string]$DeviceName,

	[Alias("GetFiles", "lf", "ls")]
	[string]$ListFiles,

	[Alias("Patterns", "p")]
	[string[]]$FilenamePatterns = "*"
)

. ./Copy-MTPFilesFunctions.ps1

Set-StrictMode -Version 2.0

# Create and return a custom object representing the source or destination directory information.
function Set-TransferObject {
	param([string]$Directory, [string]$ParameterName, [bool]$IsSource)

	$OnHost = Test-IsHostDirectory -DirectoryPath $Directory
	if ($OnHost) {
		$Directory = Convert-PathToAbsolute -Path $Directory
	}

	$Folder = Get-COMFolder -DirectoryPath $Directory -DeviceName $DeviceName -IsSource $IsSource

	if ($null -eq $Folder) {
		Write-Error "Folder ""$Directory"" could not be found or created." -ErrorAction Stop
	}
	Write-Debug "Found folder ""$Directory""."

	[PSCustomObject]@{
		Directory = $Directory
		Folder = $Folder
		OnHost = $OnHost
	}
}

# Check script parameters and setup script-level variables for source, destination and temporary directories.
function Set-TransferDirectories {
	$script:Source = Set-TransferObject -Directory $SourceDirectory -ParameterName "SourceDirectory" -IsSource:$true
	$script:Destination = Set-TransferObject -Directory $DestinationDirectory -ParameterName "DestinationDirectory"

	Write-Output "`nSource directory: ""$($script:Source.Directory)""", "Destination directory: ""$($script:Destination.Directory)""`n"

	if ($script:Source.Directory -ieq $script:Destination.Directory) {
		Write-Error "Source and Destination directories cannot be the same." -ErrorAction Stop
	}

	$script:MovedCopied = "copied"
	if ($Move) {
		$script:MovedCopied = "moved"
	}

	$tempPath = New-TempDirectory
	$script:Temp = [PSCustomObject]@{
		Directory = $tempPath
		Folder = (Get-ShellApplication).Namespace($tempPath)
		LastFileItem = $null
	}
}

# Ensure we have a script-level Shell Application object for COM interactions.
function Get-ShellApplication {
	if ($null -eq $script:ShellApp) {
		$script:ShellApp = New-Object -ComObject Shell.Application
		if ($null -eq $script:ShellApp) {
			Write-Error "Failed to create a COM Shell Application object." -ErrorAction Stop
		}
	}

	$script:ShellApp
}

# Transfer a file from the source to the destination.
function Send-SingleFile {
	param(
		[Parameter(Mandatory = $true)]
		[System.__ComObject]$FileItem,

		[int]$TotalFiles = -1
	)

	$filename = $FileItem.Name

	if ($script:Source.OnHost -and $script:Destination.OnHost) {
		# Use Powershell built-in commands if possible.
		try {
			$destinationUnique = Join-Path -Path $script:Destination.Directory -ChildPath (Get-UniqueFilename -Folder $script:Destination.Folder -Filename $filename)
			if ($Move) {
				Move-Item -Path $FileItem.Path -Destination $destinationUnique -Confirm:$false
			}
			else {
				Copy-Item -Path $FileItem.Path -Destination $destinationUnique -Confirm:$false
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
		# MTP transfer using our temporary directory as a working area.
		$tempFile = New-TemporaryFile -FileItem $FileItem
		$script:Destination.Folder.CopyHere($tempFile)
		$script:Temp.LastFileItem = $tempFile
		if ($Move) {
			$script:SourceFilesToDelete.Enqueue($FileItem)
		}

		Clear-WorkingFiles
	}
}

# Clear all but the most recent file from the temporary directory. Also remove source files if this is a Move.
function Clear-WorkingFiles {
	param([switch]$Wait)

	foreach ($file in Get-ChildItem ($script:Temp.Directory)) {
		if ($file.FullName -eq $script:Temp.LastFileItem.Path) {
			continue
		}

		try {
			$file.Delete()
		}
		catch {
			Write-Error "Failed to delete $($file.FullName): $($_.Exception.Message)"
			if ($_.Exception.InnerException) {
				Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
			}
		}
	}

	if ($Wait -and $null -ne $script:Temp.LastFileItem) {
		Remove-LockedFile -FileItem $script:Temp.LastFileItem -Folder $script:Temp.Folder
	}

	while ($script:SourceFilesToDelete.Count -gt 0) {
		$sourceFile = $script:SourceFilesToDelete.Dequeue()
		if ($script:Source.OnHost) {
			if (Test-Path -Path $sourceFile.Path) {
				Remove-Item -Path $sourceFile.Path -Force
			}
			else {
				Write-Warning "File at path $($sourceFile.Path) not found."
			}
		}
		else {
			$script:Source.Folder.Delete($sourceFile.Name)
		}
	}
}

# Main script start.
if ($ListDevices) {
	Show-MTPDevices
	return
}

$script:ShellApp = $null

if ($ListFiles) {
	List-Files $ListFiles $DeviceName
	return
}

Remove-TempDirectories

Set-TransferDirectories

$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

$script:SourceFilesToDelete = New-Object System.Collections.Generic.Queue[PSObject]

if ($PreScan) {
	# Holds all the files in the source directory which match the file pattern(s).
	$filesToTransfer = @()

	# For the scanned items progress bar.
	Write-Progress -Id 1 -Activity "Scanning files" -Status "Counting total files."
	$totalItems = $script:Source.Folder.Items().Count
	$i = 0

	# Scan the source folder for items which match the filename pattern(s).
	foreach ($item in $script:Source.Folder.Items()) {
		if ($item.Name -match $regexPattern) {
			$filesToTransfer += $item
		}

		# Progress bar.
		$i++
		Write-Progress -Id 1 -Activity "Scanning files" -Status "$i out of $totalItems processed" -PercentComplete ($i / $totalItems * 100)
	}
	if ($filesToTransfer.Count -eq 0) {
		Write-Output "No files to transfer."
		return
	}
	else {
		Write-Output "$($filesToTransfer.Count) file(s) will be transferred from ""$($script:Source.Directory)"" to ""$($script:Destination.Directory)""."
		$totalItems = $filesToTransfer.Count
		$i = 0
		foreach ($item in $filesToTransfer) {
			$i++
			if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
				Write-Progress -Id 2 -Activity "Transferring files" -Status "Transferring $($item.Name) - File $i out of $totalItems" -PercentComplete ($i / $totalItems * 100)
				Send-SingleFile -FileItem $item -TotalFiles $totalItems
			}
		}
	}
}
else {
	# Transfer files immediately, without scanning or confirmation.
	$i = 0
	foreach ($item in $script:Source.Folder.Items()) {
		if ($item.Name -match $regexPattern) {
			$i++
			if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
				Send-SingleFile -FileItem $item
			}
		}
	}
	if ($i -eq 0) {
		Write-Output "No matching files found."
	}
}

Clear-WorkingFiles -Wait

Write-Output "$i file(s) transferred."
Write-Output "Finished."
