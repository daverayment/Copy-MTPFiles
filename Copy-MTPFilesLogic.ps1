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
		Test-DirectoryExists -Path $Directory -IsSource $IsSource
		$Directory = Convert-PathToAbsolute -Path $Directory -IsSource $IsSource
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
	$script:SourceDetails = Set-TransferObject -Directory $Source -IsSource $true
	$script:DestinationDetails = Set-TransferObject -Directory $DestinationDirectory

	# Output the source and destination paths. Out-Host used to immediately display them.
	Write-Output ([PSCustomObject]@{
		Source = $script:SourceDetails.Directory
		SourceOnHost = $script:SourceDetails.OnHost
		Destination = $script:DestinationDetails.Directory
		DestinationOnHost = $script:DestinationDetails.OnHost
	}) | Format-List | Out-Host

	if ($script:SourceDetails.Directory -ieq $script:DestinationDetails.Directory) {
		Write-Error "Source and Destination directories cannot be the same." -ErrorAction Stop -Category InvalidArgument
	}

	$script:MovedCopied = "copied"
	if ($Move) {
		$script:MovedCopied = "moved"
	}

	$tempPath = New-TempDirectory
	$script:TempDetails = [PSCustomObject]@{
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

	if ($script:SourceDetails.OnHost -and $script:DestinationDetails.OnHost) {
		# Use Powershell for transfers.
		try {
			$uniqueFilename = Get-UniqueFilename -Folder $script:DestinationDetails.Folder -Filename $filename
			$destinationPath = Join-Path -Path $script:DestinationDetails.Directory -ChildPath $uniqueFilename
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
		$script:DestinationDetails.Folder.CopyHere($tempFile)
		$script:TempDetails.LastFileItem = $tempFile
		if ($Move) {
			$script:SourceFilesToDelete.Enqueue($FileItem)
		}

		Clear-WorkingEnvironment
	}
}

# Clear all but the most recent file from the temporary directory. Also remove source files if this is a Move.
function Clear-WorkingEnvironment {
	param([switch]$Wait)

	foreach ($file in Get-ChildItem ($script:TempDetails.Directory)) {
		if ($file.FullName -eq $script:TempDetails.LastFileItem.Path) {
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

	if ($Wait -and $null -ne $script:TempDetails.LastFileItem) {
		Remove-LockedFile -FileItem $script:TempDetails.LastFileItem -Folder $script:TempDetails.Folder
	}

	while ($script:SourceFilesToDelete.Count -gt 0) {
		$sourceFile = $script:SourceFilesToDelete.Dequeue()
		if ($script:SourceDetails.OnHost) {
			if (Test-Path -Path $sourceFile.Path) {
				Remove-Item -Path $sourceFile.Path -Force
			}
			else {
				Write-Warning "File at path $($sourceFile.Path) not found."
			}
		}
		else {
			$script:SourceDetails.Folder.Delete($sourceFile.Name)
		}
	}
}

# Validate the Source parameter and perform any necessary pre-processing.
function Initialize-SourceParameter {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Source,
		[string[]]$FilenamePatterns = "*"
	)

	$sourceDir = Split-Path $Source -Parent
	$sourceFilePattern = Split-Path $Source -Leaf
	
	# Check for wildcards in the directory part of the source path.
	if ($sourceDir -match "\*|\?") {
		Write-Error "Wildcard characters are not allowed in the directory portion of the source path."
			-ErrorAction Stop -Category InvalidArgument
	}

	# Process wildcards or specific file in the source path.
	if (($sourceFilePattern -match "\*|\?") -or
		(-not (Test-Path -Path $Source -PathType Container))) {

		if ($FilenamePatterns -ne "*") {
			Write-Error ("Cannot specify wildcards in the Source parameter when the FilenamePatterns " +
				"parameter is not provided.") -ErrorAction Stop
		}
		# Set the pattern so we can match the file(s) later.
		$FilenamePatterns = @($sourceFilePattern)
		# Update the source directory to just the directory part of the path.
		$Source = $sourceDir
	}

	return @{
		Source = $Source
		FilenamePatterns = $FilenamePatterns
	}
}

function Main {
	[CmdletBinding(SupportsShouldProcess)]
	param (
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

		Reset-TemporaryDirectory

		if ($PSBoundParameters.Count -eq 0) {
			Write-Error "No parameters were provided. Please see the usage information below:"
			Get-Help $PSCommandPath -Detailed
			return
		}

		$sourceInfo = Initialize-SourceParameter -Source $Source -FilenamePatterns $FilenamePatterns
		$Source = $sourceInfo.Source
		$FilenamePatterns = $sourceInfo.FilenamePatterns

		$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

		if ($PSBoundParameters.ContainsKey("ListFiles")) {
			return Get-FileList -DirectoryPath $ListFiles -RegexPattern $regexPattern
		}

		Initialize-TransferEnvironment

		# For moves, we store information about the source files for later deletion.
		$script:SourceFilesToDelete = New-Object System.Collections.Generic.Queue[PSObject]

		# Function to process a single item.
		function Invoke-ItemTransfer {
			[CmdletBinding(SupportsShouldProcess)]
			param ([System.__ComObject]$item)

			numMatches++
			if ($PSCmdlet.ShouldProcess($item.Name, "Transfer")) {
				Send-SingleFile -FileItem $item
				Write-Verbose "Transferred file ""$($item.Name)""."
				numTransfers++
			}
		}

		# Determine the matching files and transfer them.
		if ($script:SourceDetails.OnHost) {
			# It is slow to iterate over all the files with COM, so use a hybrid approach.
			Get-ChildItem -Path $script:SourceDetails.Directory -File |
				Where-Object { $_.Name -match $regexPattern } |
				ForEach-Object {
					$comFileItem = $script:SourceDetails.Folder.ParseName($_.Name)
					Invoke-ItemTransfer -Item $comFileItem
				}
		}
		else {
			# When using MTP, we have no alternative but to iterate over all the files.
			foreach ($item in $script:SourceDetails.Folder.Items()) {
				if ($item.Name -match $regexPattern) {
					Invoke-ItemTransfer -Item $item
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
		}
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
		}
	}
}