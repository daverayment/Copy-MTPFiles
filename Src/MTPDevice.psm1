# Return a COM reference to the shell application. Created if it does not exist.
# Use `Remove-ShellApplication` to clean up the COM object after use.
function Get-ShellApplication {
	if ($null -eq $ShellApp) {
		$ShellApp = New-Object -ComObject Shell.Application
		if ($null -eq $ShellApp) {
			Write-Error "Failed to create a COM Shell Application object."
				-ErrorAction Stop -Category ResourceUnavailable
		}
	}

	$ShellApp
}

# Clean up the shell object.
function Remove-ShellApplication {
    if ($null -ne $ShellApp) {
		$ShellApp = $null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApp) | Out-Null
    }
}

# Retrieve all attached MTP-compatible devices.
function Get-MTPDevice {
	(Get-ShellApplication).NameSpace(17).Items() |
		Where-Object { $_.IsBrowsable -eq $false -and $_.IsFileSystem -eq $false }
}

<#
.SYNOPSIS
Retrieves the target MTP-compatible device.

.DESCRIPTION
Attempts to find and return an attached MTP-compatible device. If a DeviceName is provided, it will search
for a device with that name.

Returns $null if no device was found or if no attached devices match the DeviceName parameter.

.PARAMETER DeviceName
The name of the MTP-compatible device to search for.

.EXAMPLE
Get-TargetDevice -DeviceName "MyDevice"
#>
function Get-TargetDevice {
	[CmdletBinding()]
    param(
		[string] $DeviceName
	)

	$devices = Get-MTPDevice

	if (-not $devices) {
		Write-Verbose "No MTP devices found."
		return $null
	}

	# If only one device and no DeviceName is specified, return it.
	if ($devices.Count -eq 1 -and -not $DeviceName) {
		Write-Verbose "One MTP device found: $($devices.Name)."
		return $devices
	}

	# If a specific device name is provided, search for it.
	if ($DeviceName) {
		$device = $devices | Where-Object { $_.Name -ieq $DeviceName }

		if ($device) {
			Write-Verbose "Found MTP device matching name: $DeviceName."
			return $device
		}
		else {
			Write-Verbose "No MTP device found matching name: $DeviceName."
			return $null
		}
	}

	Write-Verbose "Multiple MTP devices found. Please specify a device name."
	return $null
}

<#
.SYNOPSIS
Iterates through an MTP folder structure, starting from a specified parent folder.

.DESCRIPTION
The `Get-MTPIterator` function provides an iterator through the MTP folder structure. 
Starting from a given parent folder, the function traverses the path provided and yields each 
item (folder or file) to the caller. If an item in the specified path doesn't exist or if a non-folder 
item is encountered in the path before the last segment, the iteration stops.

.PARAMETER ParentFolder
A COM object representing the starting point of the folder structure to iterate through. 
This is usually an MTP device folder or2 any other folder within the MTP device structure.

.PARAMETER Path
A string representing the folder structure's path to iterate through. The path should be 
provided in a forward-slash-separated format, e.g., "Internal storage/Downloads/My Files". 
Leading and trailing slashes are optional.

.EXAMPLE
$device = Get-TargetDevice
$deviceFolder = $device.GetFolder()
Get-MTPIterator -ParentFolder $deviceFolder -Path "Internal storage/Photos/Vacation"

This example begins iteration at the device's root folder and progresses through "Internal storage",
"Photos", and finally "Vacation". For each section, the function yields the respective folder to the
caller.

.NOTES
- If the CreateIfNotExists switch is set, the function will attempt to create missing folders. Otherwise,
  the iteration will stop.
- It's the caller's responsibility to interpret the yielded item and check if it's a folder or a file.
  The IsFolder property can be used for this purpose, if the item is non-null. $null indicates a non-match.
#>
function Get-MTPIterator {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$ParentFolder,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[ValidatePattern('^[^\\]*$')]  # Ensure no backslashes
		[string]$Path,

		[switch]$CreateIfNotExists,

		[switch]$ShowProgress
	)

	$sections = $Path.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
	$currentPath = ""

	for ($i = 0; $i -lt $sections.Length; $i++) {
		$section = $sections[$i]
		$currentPath = Join-Path $currentPath $section

		if ($ShowProgress) {
			Write-Progress -Activity "Scanning device folders" -Status "Processing `"$currentPath`"" `
				-PercentComplete (($i / $sections.Length) * 100)
		}

		try {
			$item = $ParentFolder.ParseName($section)
		} catch {
			Write-Error "Could not parse path `"$currentPath`". Ensure it's a valid path." -ErrorAction Stop -Category InvalidArgument
		}

		# If the section doesn't exist and CreateIfNotExists is set, create it.
		if (($null -eq $item) -and $CreateIfNotExists) {
			try {
				$ParentFolder.NewFolder($section)
				$item = $ParentFolder.ParseName($section)
			} catch {
				Write-Error "Could not create folder `"$section`"." -ErrorAction Stop
			}
		}

		# Yield the item back to the caller ($null if the section could not be found).
		$item

		# Stop iterating if the next folder could not be found.
		if (($null -eq $item) -or (-not $item.IsFolder)) {
			break
		}

		# Keep iterating through the folder structure.
		$ParentFolder = $item.GetFolder()
	}

	if ($ShowProgress) {
		Write-Progress -Activity "Scanning device folders" -Completed
	}
}

# Retrieve an MTP folder by path.
function Get-DeviceCOMFolder {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$ParentFolder,

		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[string]$FolderPath,

		[switch]$CreateIfNotExists
	)

	# Get the last folder in the path.
	if ($FolderPath -eq '/') {
		$result = $ParentFolder
	} else {
		$results = @(Get-MTPIterator -ParentFolder $ParentFolder -Path $FolderPath -ShowProgress -CreateIfNotExists:$CreateIfNotExists)
		$result = $results[-1]
	}

	if (($null -eq $result) -or (-not $result.IsFolder)) {
		Write-Error ("Path ""$FolderPath"" not found. Check the provided path for errors and try again.") `
			-Category ObjectNotFound -TargetObject $FolderPath -ErrorAction Stop
	}

	return $result.GetFolder()
}

function Get-MTPFileIterator {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.__ComObject]$Folder,

		[string]$RegexPattern
	)

	foreach ($item in $Folder.Items()) {
		if ($RegexPattern) {
			if ($item.Name -match $RegexPattern) {
				$item
			}
		} else {
			$item
		}
	}
}

# Retrieve all top-level device folders for the attached device.
function Get-TopLevelDeviceFolders {
	param(
		[Object]$Device = $null
	)

	if ($null -ne $Device) {
		return $Device.GetFolder().Items() | Where-Object { $_.IsFolder }
	}
}

Export-ModuleMember -Function Get-MTPIterator, Get-MTPDevice, Get-TargetDevice, Get-DeviceCOMFolder, Get-TopLevelDeviceFolders, Get-ShellApplication, Remove-ShellApplication