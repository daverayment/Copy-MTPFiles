# Functions related to the MTP device and COM folders.
if (Get-Module MTPDevice) {
	Write-Debug "Removing MTPDevice module."
	Remove-Module MTPDevice
}
Import-Module "$PSScriptRoot\MTPDevice.psm1"

# Ancillary functions.
. "$PSScriptRoot\Copy-MTPFilesFunctions.ps1"


# Custom format for file listings to keep it reasonably similar to Get-ChildItem.
Update-FormatData -PrependPath "$PSScriptRoot\MTPFileFormat.ps1xml"

Set-StrictMode -Version 2.0


# Create and return a custom object representing the source or destination directory information.
function Set-TransferObject {
	[CmdletBinding(SupportsShouldProcess)]
	param([string]$Directory, [bool]$IsSource)

    # TODO: rename fn to Get-TransferObject
    #     Integrate the Initialize-SourceParameter fn?

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

# Validate the Source parameter and perform any necessary pre-processing for path and wildcards.
function Resolve-SourceParameter {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Source,
		[string[]]$FilenamePatterns = "*",
		[System.__ComObject]$Device = $null
	)

	$isDeviceSource = $false

	if ($Device) {
		# Does the first part of the source look like a device path?
		$isDeviceSource = Get-IsDevicePath -Path $Source -Device $Device

		if ($isDeviceSource) {
			# Split the path string into segments and also retrieve the matching folders on the device.
			$sections = $Source.Split("/")
			$folders = @(Get-MTPIterator -ParentFolder $Device.GetFolder() -Path $Source)

			# A valid path will have the same number of folders returned as there are path string segments.
			if ($folders.Length -eq $sections.Length) {
				if ($null -eq $folders[-1]) {
					# The last part of the path didn't match a folder, so assume it is a file.
					$sourceDir = (Split-Path $Source -Parent).Replace('\', '/')
					$sourceFilePattern = Split-Path $Source -Leaf
				} else {
					# The entire path has been found as folders on the device.
					$sourceDir = $sections -join '/'
					$sourceFilePattern = $FilenamePatterns
				}
			} else {
				# Could not iterate through the whole path.
				# Niche case: is there a host directory with the same path?
				if (Test-Path -Path $Source) {
					$isDeviceSource = $false
				} else {
					# The source must exist but cannot be found on the device.
					Write-Error "Specified source path ""$Source"" does not exist." -ErrorAction Stop `
						-Category ObjectNotFound
				}
			}
		}
	}

	# Host-specific processing.
	if (-not $isDeviceSource) {
		$sourceDir = Split-Path $Source -Parent
		$sourceFilePattern = Split-Path $Source -Leaf
	
		if (-not $sourceDir) {
			$sourceDir = "."
		}
	}

	# Check for wildcards in the directory part of the source path.
	if ($sourceDir -match "\*|\?") {
		Write-Error "Wildcard characters are not allowed in the directory portion of the source path." `
			-ErrorAction Stop -Category InvalidArgument
	}

	if (-not $isDeviceSource) {
		# NB: we do not need to do a check for the device here because it has already been done above.
		if (-not (Test-Path -Path $sourceDir)) {
			Write-Error "Specified source directory ""$sourceDir"" does not exist." -ErrorAction Stop `
				-Category ObjectNotFound
		}		
	}

	# At this point, we know that the folders part of the source path is valid.

	# Process wildcards or specific file in the source path.
	if (($sourceFilePattern -match "\*|\?")) {
		if ($FilenamePatterns -ne "*") {
			Write-Error ("Cannot specify wildcards in the Source parameter when the FilenamePatterns " +
				"parameter is also provided.") -ErrorAction Stop -Category InvalidArgument
		}
	} else {
		# $sourceFilePattern should contain the exact filename we're looking for.
		if ($isDeviceSource) {
			$lastFolder = if ($null -eq $folders[-1]) { $folders[-2] } else { $folders[-1] }

			if ($lastFolder.ParseName($sections[-1])) {
				$fileExists = $true
			}
		} else {
			$fileExists = Test-Path -Path $Source -PathType Leaf
		}

		if ($FilenamePatterns -ne "*" -and $fileExists) {
			# We do not allow wildcard patterns when the source resolves to a single file.
			Write-Error "Cannot provide FilenamePatterns parameter when the Source is a file." `
				-ErrorAction Stop -Category InvalidArgument
		}

		# If the source path refers to a single file, it must exist.
		if (-not $fileExists) {
			Write-Error "Specified source file ""$Source"" does not exist." -ErrorAction Stop `
				-Category ObjectNotFound
		}
	}

	return [PSCustomObject]@{
		Source = $sourceDir
		FilenamePatterns = $sourceFilePattern
		IsDeviceSource = $isDeviceSource
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

	try {
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

		# We need to do source path validation and set up before any transfers.
		$sourceInfo = Resolve-SourceParameter -Source $Source -FilenamePatterns $FilenamePatterns -Device $device
		$Source = $sourceInfo.Source
		$FilenamePatterns = $sourceInfo.FilenamePatterns

		if ($PSBoundParameters.ContainsKey("ListFiles")) {
			return Get-FileList -Path $ListFiles -Device $device -RegexPattern (Convert-WildcardsToRegex -Patterns $FilenamePatterns)
		}
		
		return
		
		Reset-TemporaryDirectory

		# Now the regex can be built, which is needed for both transfers and ListFiles.
		$regexPattern = Convert-WildcardsToRegex -Patterns $FilenamePatterns

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
            if ($WarningOnNoMatches) {
                Write-Warning "No matching files found."
            }
            else {
                Write-Host "No matching files found."
            }
		}
		else {
			Write-Host "$numMatches matching file(s) found. $numTransfers file(s) transferred."
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