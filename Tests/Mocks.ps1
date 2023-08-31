# This is a representation of our mocked file system on the attached device.
$MockDeviceFileSystem = @{
    'Internal storage' = @{
        'MTPFilesTestDirA' = @{ };
        'MTPFilesTestDirB' = @{
            'DeviceFileA' = "file";
            'DeviceFileA.txt' = 'file';
            'DeviceFileB.txt' = 'file';
            'DeviceFileA.jpg' = 'file';
        };
        'MTPFilesTestDirC' = @{ };
        'MTPFilesTestFile' = 'file';
        'MTPFilesTestFile.doc' = 'file';
    }
}

# This represents the host filesystem, relative to the current directory.
$MockHostFileSystem = @{
    'SomeFile' = 'file';
    'SomeFile.txt' = 'file';
    'SomeHostFolder' = @{
        'HostSubFolderA' = @{
            'HostFileA' = 'file';
            'HostFileA.txt' = 'file';
        };
        'HostFileB' = 'file';
        'HostFileB.txt' = 'file';
    };
    # This simulates a host directory with the same name as the device's top-level folder.
    'Internal storage' = @{
        'HostSubFolderB' = @{ };
        'HostFileC.txt' = 'file';
    };
    'C:' = @{
        'HostFileD' = 'file';
        'HostFileD.txt' = 'file';
        'HostSubFolderC' = @{
            'HostFileE' = 'file';
            'HostFileE.txt' = 'file';
        };
    };
}

function Get-MockedItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [scriptblock]$Function,

        [hashtable]$FileSystem
    )

    $pathSections = $Path.Trim("/").Split("/", [StringSplitOptions]::RemoveEmptyEntries)
    $currentItem = $FileSystem

    foreach ($section in $pathSections) {
        # Navigate deeper down the path if the next section exists.
        if ($currentItem -is [hashtable] -and $currentItem.ContainsKey($section)) {
            $currentItem = $currentItem[$section]
        } else {
            # The path doesn't exist.
            return $null
        }
    }

    $itemObj = [PSCustomObject]@{
        IsFolder = $currentItem -is [hashtable]
        Name     = if ($pathSections) { $pathSections[-1] } else { "/" }
        Item     = $currentItem
        Path     = $Path
    }

    $itemObj | Add-Member -MemberType ScriptMethod -Name GetFolder -Value { return $this }
    $itemObj | Add-Member -MemberType ScriptMethod -Name ParseName `
        -Value (Set-ParseNameMethod -Path $Path -Function ${function:Get-MockedItem} -FileSystem $FileSystem)
    
    #Write-Host "Path: $($itemObj.Path)"
    return $itemObj
}

function Set-ParseNameMethod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Function,

        [hashtable]$FileSystem
    )

    return {
        param($Name)
        & $Function -Path "$Path/$Name" -FileSystem $FileSystem
    }.GetNewClosure()
}

# Test a path against our mock host filesystem instead of the host itself.
Mock Test-Path {
    $segments = $Path.Trim('\').Split('\', [StringSplitOptions]::RemoveEmptyEntries)
    $currentItem = $MockHostFileSystem

    foreach ($segment in $segments) {
        if ($currentItem -is [hashtable] -and $currentItem.ContainsKey($segment)) {
            $currentItem = $currentItem[$segment]
        } else {
            return $false
        }
    }

    return $true            
}

Mock Get-TargetDevice {
    return Get-MockedItem -Path "/" -FileSystem $MockDeviceFileSystem
}

Mock Get-IsDevicePath -RemoveParameterType 'Device' {
    # Get the first segment of the path.
    $topLevelPath = $Path.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries)[0]
    # Is it one of the mocked top-level folders?
    $matched = @($MockDeviceFileSystem.Keys | `
        Where-Object { $_ -ceq $topLevelPath }).Count -gt 0

    return $matched
}

Mock Get-MTPIterator -RemoveParameterType 'ParentFolder' {
    $sections = $Path.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries)

    $currentItem = $null

    if ($ParentFolder -and $ParentFolder.Path) {
        # Start from the parent folder, if it has been supplied.
        $currentItem = Get-MockedItem -Path $ParentFolder.Path.Replace('\', '/') -FileSystem $MockDeviceFileSystem
    } else {
        # Otherwise start from the root.
        $currentItem = Get-MockedItem -Path "/" -FileSystem $MockDeviceFileSystem
    }

    foreach ($section in $sections) {
        $nextPath = Join-Path -Path $currentItem.Path -ChildPath $section
        $nextItem = Get-MockedItem -Path $nextPath.Replace('\', '/') -FileSystem $MockDeviceFileSystem

        # Output the item (or $null if it wasn't found).
        $nextItem

        if (-not $nextItem -or -not $nextItem.IsFolder) {
            break
        }

        $currentItem = $nextItem
    }
}
