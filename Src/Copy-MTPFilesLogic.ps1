enum PathType {
	Host
	Device
	Ambiguous
}

# Functions related to the MTP device and COM folders.
if (Get-Module MTPDevice) {
	Write-Debug "Removing MTPDevice module."
	Remove-Module MTPDevice
}
Import-Module "$PSScriptRoot\MTPDevice.psm1"

# Source resolution and validation.
. "$PSScriptRoot\SourceResolver.ps1"
# Ancillary functions.
. "$PSScriptRoot\Copy-MTPFilesFunctions.ps1"
# Functions shared with testing.
. "$PSScriptRoot\Copy-MTPFilesSharedFunctions.ps1"


# Custom format for file listings to keep it reasonably similar to Get-ChildItem.
Update-FormatData -PrependPath "$PSScriptRoot\MTPFileFormat.ps1xml"

Set-StrictMode -Version 2.0


# Check script parameters and setup script-level variables for source, destination and temporary directories.
function Initialize-TransferEnvironment {
	# $script:SourceDetails = Set-TransferObject -Directory $Source -IsSource $true
	$script:DestinationDetails = Set-TransferObject -Directory $DestinationDirectory

    # Output the source and destination path info.
    function Format-PathDetails {
        param([string]$PathName, [PSObject]$PathDetails)

        $locationType = if ($PathDetails.OnHost) { "host" } else { "device" }
        return "{0}: `"{1}`" (on {2})" -f $PathName, $PathDetails.Directory, $locationType
    }

    Write-Verbose (Format-PathDetails -PathName "Source" -PathDetails $script:SourceDetails)
    Write-Verbose (Format-PathDetails -PathName "Destination" -PathDetails $script:DestinationDetails)

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

function Test-EmptyParameterList {
	param(
		[Parameter(Mandatory = $true)]
		[hashtable]$BoundParameters,
		[Parameter(Mandatory = $true)]
		[System.Management.Automation.FunctionInfo]$CommandMetadata
	)

	$scriptParams = $CommandMetadata.Parameters.Keys

	$commonParams = [System.Management.Automation.PSCmdlet]::CommonParameters
	$boundUserParams = $BoundParameters.Keys |
		Where-Object { $_ -in $scriptParams -and $_ -notin $commonParams -and $_ -ne "CallingScriptPath" }
	return (-not $boundUserParams)
}

# Output a list of the connected MTP devices.
function Get-DeviceList {
	$devices = @(Get-MTPDevice)
	if ($devices.Length -eq 0) {
		Write-Warning "No MTP devices found."
	}
	else {
		$devices | ForEach-Object {
			[PSCustomObject]@{
				Name = $_.Name
				Type = $_.Type
			}
		}
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
		[string[]]$FilenamePatterns = "*",

        [switch]$WarningOnNoMatches,

		[string]$CallingScriptPath
	)

	# Number of files found which match the file pattern.
	$numMatches = 0
	# Number of matched files transferred.
	$numTransfers = 0

	# try {
		if ($ListDevices) {
			Get-DeviceList
			return
		}

		if (Test-EmptyParameterList -BoundParameters $PSBoundParameters -CommandMetadata $PSCmdlet.MyInvocation.MyCommand) {
			Write-Error "No parameters were provided. Please see the usage information below:" -Category InvalidArgument
			Get-Help $($CallingScriptPath) -Detailed
			return
		}

		# Get the attached MTP device. (Could be $null.)
		$device = Get-TargetDevice -DeviceName $DeviceName

		if ($PSBoundParameters.ContainsKey("ListFiles")) {
			$Source = $ListFiles
		}

		# Validate and process the source parameters before any transfers or file listing.
		# TODO: change back to $false after testing.
		$sourceInfo = [SourceResolver]::new($Source, $device, $FilenamePatterns, $true)
		$Source = $sourceInfo.Directory
		if ($sourceInfo.FilePattern) {
			# The path included a filename or file pattern. It should be converted into the matching regex.
			$FilenamePatterns = $sourceInfo.FilePattern
		}

		# Now the regex can be built, which is needed for both transfers and ListFiles.
		$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

		if ($PSBoundParameters.ContainsKey("ListFiles")) {
			return Get-FileList -Path $Source -Device $device -RegexPattern $regexPattern
		}

		Reset-TemporaryDirectory

		# Initialise the destination info.
		# $destination = $DestinationDirectory.Trim().TrimEnd('/').TrimEnd('\')
		# if (Test-IsHostDirectory -DirectoryPath $destination) {
		# 	$destination = Convert-PathToAbsolute -Path $destination -IsSource $false
		# }

		# $destinationFolder = Get-COMFolder -Path $destination -Device $device -CreateIfNotExists

		# if ($null -eq $destinationFolder) {
		# 	Write-Error "Folder ""$DestinationDirectory"" could not be found or created." -ErrorAction Stop
		# }
		# Write-Debug "Found folder ""$DestinationDirectory""."

		# Initialize-TransferEnvironment

		return

		# For moves, we store information about the source files for later deletion.
		$sourceFilesToDelete = New-Object System.Collections.Generic.Queue[PSObject]

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
		if ($sourceInfo.IsDeviceSource) {
			# When using MTP, we have no alternative but to iterate over all the files.
			foreach ($item in $sourceInfo.SourceFolder.Items()) {
				if ($item.Name -match $regexPattern) {
					Invoke-ItemTransfer -Item $item
				}
			}
		}
		else {
			# It is slow to iterate over all the files with COM, so use a hybrid approach.
			# Get-ChildItem -Path $script:SourceDetails.Directory -File |
			Get-ChildItem -Path $sourceInfo.Directory -File |
				Where-Object { $_.Name -match $regexPattern } |
				ForEach-Object {
					$comFileItem = $sourceInfo.Folder.ParseName($_.Name)
					Invoke-ItemTransfer -Item $comFileItem
				}
		}

		if ($numMatches -eq 0) {
            if ($WarningOnNoMatches) {
                Write-Warning "No matching files found."
            }
            else {
                Write-Information "No matching files found."
            }
		}
		else {
			Write-Information "$numMatches matching file(s) found. $numTransfers file(s) transferred."
		}

		if ($PSCmdlet.ShouldProcess("Temporary files", "Delete")) {
			Clear-WorkingEnvironment -Wait
		}

		$movedCopiedInitCap = $script:MovedCopied.Substring(0, 1).ToUpper() + $script:MovedCopied.Substring(1);

        $status = if ($numMatches -eq 0 -and $WarningOnNoMatches) { "Warning"} else { "Completed" }

		return [PSCustomObject]@{
			Status = $status
			Message = if ($numMatches -eq 0) { "No matching files found." } else { "$movedCopiedInitCap files." }
			FilesMatched = $numMatches
			FilesTransferred = $numTransfers
		}
	# }
	# catch {
	# 	$_.Exception | Out-File -FilePath ".\Error.log" -Append

	# 	Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red

	# 	return [PSCustomObject]@{
	# 		Status = "Failure"
	# 		Message = $_.Exception.Message
	# 		ErrorCategory = $_.CategoryInfo.Category
	# 		FilesMatched = if (Test-Path variable:numMatches) { $numMatches } else { 0 }
	# 		FilesTransferred = if (Test-Path variable:numTransfers) { $numTransfers } else { 0 }
	# 	}
	# }
}