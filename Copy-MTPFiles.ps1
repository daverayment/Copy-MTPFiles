<#
.SYNOPSIS
	This script transfers files to or from a portable device via MTP - the Media Transfer Protocol.
.DESCRIPTION
	The script accepts the following parameters:
	- SourceDirectory (Aliases: SourceFolder, Source, s): The path to the source directory. Defaults to the current path if not specified.
	- DestinationDirectory (Aliases: DestinationFolder, Destination, Dest, d): The path to the destination directory. Defaults to the current path if not specified.
	- FilenamePatterns (Aliases: Patterns, p): An array of filename patterns to search for. Defaults to matching all files. Separate multiple patterns with commas.
	- Move: A switch which, when included, moves files instead of the default of copying them.
	- ListDevices (Aliases: GetDevices, ld): A switch for listing the attached MTP-compatible devices. Use this option to get the names for the -DeviceName parameter. All other parameters will be ignored if this is present.
	- DeviceName (Aliases: Device, dn): The name of the attached device. Must be used if more than one compatible device is attached. Use the -List switch to get the names of MTP-compatible devices.
	- ListFiles (Aliases: GetFiles, lf, ls): Lists all files in the specified directory. For host directories, this returns a PowerShell file listing as usual; for device directories, this returns objects with Name, Length, LastWriteTime and Type properties. May be used in conjunction with -FilenamePatterns to filter the results.
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
	[Parameter(Position = 0)]
	[string]$SourceDirectory = $PWD.Path,

	[Alias("DestinationFolder", "Destination", "d")]
	[ValidateNotNullOrEmpty()]
	[Parameter(Position = 1)]
	[string]$DestinationDirectory = $PWD.Path,

	[Alias("Scan")]
	[switch]$ScanOnly,

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

# Custom format for file listings to keep it reasonably similar to Get-ChildItem.
Update-FormatData -PrependPath .\MTPFileFormat.ps1xml

Set-StrictMode -Version 2.0

# Create and return a custom object representing the source or destination directory information.
function Set-TransferObject {
	[CmdletBinding(SupportsShouldProcess)]
	param([string]$Directory, [string]$ParameterName, [bool]$IsSource)

	$Directory = $Directory.TrimEnd('/').TrimEnd('\\')

	$OnHost = Test-IsHostDirectory -DirectoryPath $Directory
	if ($OnHost) {
		$Directory = Convert-PathToAbsolute -Path $Directory
	}

	$Folder = Get-COMFolder -DirectoryPath $Directory -IsSource $IsSource

	if ($null -eq $Folder -and $PSCmdlet.ShouldProcess($Directory, "Directory error check")) {
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
		# Use Powershell for transfers.
		try {
			$destinationUnique = Join-Path -Path $script:Destination.Directory -ChildPath (Get-UniqueFilename -Folder $script:Destination.Folder -Filename $filename)
			if ($destinationUnique -ne $FileItem.Path) {
				$newFilename = [System.IO.Path]::GetFilename($destinationUnique)
				Write-Warning "A file with the same name already exists. The source file ""$($FileItem.Name)"" will be transferred as ""$newFilename""."
			}
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
$script:ShellApp = $null

if ($ListDevices) {
	Get-MTPDevices | ForEach-Object {
		[PSCustomObject]@{
			Name = $_.Name
			Type = $_.Type
		}
	}
	return
}

Set-DeviceInfo

$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

if ($PSBoundParameters.ContainsKey("ListFiles")) {
	Get-FileList -DirectoryPath $ListFiles -RegexPattern $regexPattern
	return
}

if ($PSCmdlet.ShouldProcess("Temporary folders", "Delete")) {
	Remove-TempDirectories
}

Set-TransferDirectories

$script:SourceFilesToDelete = New-Object System.Collections.Generic.Queue[PSObject]

$i = 0
foreach ($item in $script:Source.Folder.Items()) {
	if ($item.Name -match $regexPattern) {
		$i++
		if ($ScanOnly) {
			Format-Item $item $script:Source.Folder | Select-Object Type, LastWriteTime, Length, Name
		}
		elseif ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
			Send-SingleFile -FileItem $item
			Write-Verbose "Transferred file ""$($item.Name)""."
		}
	}
}
if ($i -eq 0) {
	Write-Output "No matching files found."
}

if (-not $ScanOnly) {
	if ($PSCmdlet.ShouldProcess("Temporary files", "Delete")) {
		Clear-WorkingFiles -Wait
	}
	
	Write-Output "$i file(s) transferred."
}
