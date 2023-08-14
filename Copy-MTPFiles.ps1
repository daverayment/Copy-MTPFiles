<#
.SYNOPSIS
    Transfers files to or from a portable device via MTP (Media Transfer Protocol).
.DESCRIPTION
    The Media Transfer Protocol (MTP) facilitates file transfers between computers and portable devices like smartphones, cameras, and media players. 

	This script integrates MTP transfers into your PowerShell workflow. It supports features such as file listing (on host and device), device enumeration and pattern matching to enhance and simplify the process.

	For further details, source code, or to report issues, visit the GitHub repository: https://github.com/daverayment/Copy-MTPFiles
.NOTES
	Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.
.PARAMETER Source
	The path to the source directory or file(s). If not provided, it defaults to the current path. Supports wildcards for file matching.
	Alias: s
.PARAMETER DestinationDirectory
	The path to the destination directory. Defaults to the current path if not provided.
	Aliases: DestinationFolder, Destination, Dest, d
.PARAMETER FilenamePatterns
	An array of filename patterns to match. By default, it matches all files. For multiple patterns, separate them with commas (e.g., "*.jpg,*.png").
	Aliases: Patterns, p
.PARAMETER Move
	When this switch is present, files are moved instead of copied.
.PARAMETER ListDevices
	Lists attached MTP-compatible devices. Useful to retrieve device names for the -DeviceName parameter. When present, other parameters are ignored.
	Aliases: GetDevices, ld
.PARAMETER DeviceName
	Specifies the name of the attached device to use. Required if multiple compatible devices are attached. Use -ListDevices to retrieve the names of all attached devices.
	Aliases: Device, dn
.PARAMETER ListFiles
	Lists files in the specified directory. For host directories, a standard PowerShell file listing is returned. For directories on a device, this returns objects with Name, Length, LastWriteTime, and Type properties. This can be combined with -FilenamePatterns for filtered results.
	Aliases: GetFiles, lf, ls
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 -Move -Source "Internal storage/Download" -Destination "C:\Projects\Documents" -Patterns "*.doc", "*.pdf"

    Moves .doc and .pdf files from an Android device's Download directory to the specified host directory.
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 "Internal storage/Download" -FilenamePatterns "*.jpg"

    Copies .jpg files from an Android device's Download directory to the current folder on the host.
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 -Move -Source "." -Destination "Internal storage/Download"

    Moves all files from the current host directory to the Download directory on an Android device.
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 -l

    Lists all MTP-compatible devices currently attached.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
	[Alias("s")]
	[ValidateNotNullOrEmpty()]
	[Parameter(Position = 0)]
	[string]$Source = $PWD.Path,

	[Alias("DestinationFolder", "Destination", "d")]
	[ValidateNotNullOrEmpty()]
	[Parameter(Position = 1)]
	[string]$DestinationDirectory = $PWD.Path,

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
	param([string]$Directory, [bool]$IsSource)

	$Directory = $Directory.TrimEnd('/').TrimEnd('\\')

	$OnHost = Test-IsHostDirectory -DirectoryPath $Directory
	if ($OnHost) {
		Test-DirectoryExists -Path $Directory -IsSource:$IsSource
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
function Initialize-TransferEnvironment {
	$script:Source = Set-TransferObject -Directory $SourceDirectory -IsSource:$true
	$script:Destination = Set-TransferObject -Directory $DestinationDirectory

	# Output the source and destination paths. Out-Host used to immediately display them.
	Write-Output ([PSCustomObject]@{
		Source = $script:Source.Directory
		SourceOnHost = $script:Source.OnHost
		Destination = $script:Destination.Directory
		DestinationOnHost = $script:Destination.OnHost
	}) | Format-List | Out-Host

	if ($script:Source.Directory -ieq $script:Destination.Directory) {
		Write-Error "Source and Destination directories cannot be the same." -ErrorAction Stop -Category InvalidArgument
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
			Write-Error "Failed to create a COM Shell Application object." -ErrorAction Stop -Category ResourceUnavailable
		}
	}

	$script:ShellApp
}

# Transfer a file from the source to the destination.
function Send-SingleFile {
	param(
		[Parameter(Mandatory = $true)]
		[System.__ComObject]$FileItem
	)

	$filename = $FileItem.Name

	if ($script:Source.OnHost -and $script:Destination.OnHost) {
		# Use Powershell for transfers.
		try {
			$uniqueFilename = Get-UniqueFilename -Folder $script:Destination.Folder -Filename $filename
			$destinationPath = Join-Path -Path $script:Destination.Directory -ChildPath $uniqueFilename
			if (-not ($uniqueFilename -ieq $filename)) {
				Write-Warning "A file with the same name already exists. The source file ""$($filename)"" will be transferred as ""$uniqueFilename""."
			}
			if ($Move) {
				Move-Item -Path $FileItem.Path -Destination $destinationPath -Confirm:$false
			}
			else {
				Copy-Item -Path $FileItem.Path -Destination $destinationPath -Confirm:$false
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
		$tempFile = Copy-SourceFileToTemporaryDirectory -FileItem $FileItem
		$script:Destination.Folder.CopyHere($tempFile)
		$script:Temp.LastFileItem = $tempFile
		if ($Move) {
			$script:SourceFilesToDelete.Enqueue($FileItem)
		}

		Clear-WorkingEnvironment
	}
}

# Clear all but the most recent file from the temporary directory. Also remove source files if this is a Move.
function Clear-WorkingEnvironment {
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

function Initialize-SourceParameter {
	# Ensure the directory part of the source path does not contain wildcards.
	$sourceDir = Split-Path $Source -Parent
	if ($sourceDir -match "\*|\?") {
		Write-Error "Wildcard characters are not allowed in the directory portion of the source path."
			-ErrorAction Stop -Category InvalidArgument
	}
	
	# Does the filename part of the path include wildcards?
	$sourceFilePattern = Split-Path $Source -Leaf
	if (Get-ContainsWildcard($sourceFilePattern)) {
		if ($FilenamePatterns) {
			Write-Error ("Cannot specify wildcards in the SourceDirectory parameter when the FilenamePatterns " +
				"parameter is also provided.") -ErrorAction Stop
		}

		# Assign the filename pattern to the patterns parameter.
		$FilenamePatterns = @($sourceFilePattern)
		# Update the source directory to just the directory part of the source path.
		$Source = $sourceDir
	}
	elseif (-not (Test-Path -Path $Source -PathType Container)) {
		if ($FilenamePatterns) {
			Write-Error ("Cannot specify a file path as the Source while also specifying a FilenamePatterns " +
				"parameter.") -ErrorAction Stop
		}

		# Assign the filename pattern to the patterns parameter. Will pick up the single file specified.
		$FilenamePatterns = @($sourceFilePattern)
		# Update the source to just the directory part of the path.
		$Source = $sourceDir
	}
}


# Main script start.
$script:ShellApp = $null
# Number of files found which match the file pattern.
$numMatches = 0
# Number of matched files transferred.
$numTransfers = 0

try {
	if ($ListDevices) {
		Get-MTPDevice | ForEach-Object {
			[PSCustomObject]@{
				Name = $_.Name
				Type = $_.Type
			}
		}
		return
	}

	Initialize-DeviceInfo

	$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

	if ($PSBoundParameters.ContainsKey("ListFiles")) {
		Get-FileList -DirectoryPath $ListFiles -RegexPattern $regexPattern
		return
	}

	Reset-TemporaryDirectory

	if ($PSBoundParameters.Count -eq 0) {
		Write-Error "No parameters were provided. Please see the usage information below:"
		Get-Help $PSCommandPath -Detailed
		return
	}

	Initialize-TransferEnvironment

	# For moves, we store information about the source files for later deletion.
	$script:SourceFilesToDelete = New-Object System.Collections.Generic.Queue[PSObject]

	# A script block to process a single item.
	$processItem = {
		param ([System.__ComObject]$item)

		$script:numMatches++
		if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
			Send-SingleFile -FileItem $item
			Write-Verbose "Transferred file ""$($item.Name)""."
			$script:numTransfers++
		}
	}

	# Determine the matching files and transfer them.
	if ($script:Source.OnHost) {
		# It is slow to iterate over all the files with COM, so use a hybrid approach.
		Get-ChildItem -Path $script:Source.Directory -File |
			Where-Object { $_.Name -match $regexPattern } |
			ForEach-Object {
				$comFileItem = $script:Source.Folder.ParseName($_.Name)
				& $processItem $comFileItem
			}
	}
	else {
		# When using MTP, we have no alternative but to iterate over all the files.
		foreach ($item in $script:Source.Folder.Items()) {
			if ($item.Name -match $regexPattern) {
				& $processItem $item
			}
		}
	}

	if ($numMatches -eq 0) {
		Write-Host "No matching files found."
	}
	else {
		Write-Host "$numMatches matching file(s) found. $numTransfers file(s) transferred."
	}

	if ($PSCmdlet.ShouldProcess("Temporary files", "Delete")) {
		Clear-WorkingEnvironment -Wait
	}

	$movedCopiedInitCap = $script:MovedCopied.Substring(0, 1).ToUpper() + $script:MovedCopied.Substring(1);

	return [PSCustomObject]@{
		Status = "Success"
		Message = "$movedCopiedInitCap files."
		FilesMatched = $numMatches
		FilesTransferred = $numTransfers
	} | Format-List
}
catch {
	$_.Exception | Out-File -FilePath ".\Error.log" -Append

	Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red

	return [PSCustomObject]@{
		Status = "Failure"
		Message = $_.Exception.Message
		ErrorCategory = $_.CategoryInfo.Category
		FilesMatched = if (Test-Path variable:numMatches) { $numMatches } else { 0 }
		FilesTransferred = if (Test-Path variable:numTransfers) { $numTransfers } else { 0 }
	} | Format-List
}