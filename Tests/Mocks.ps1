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
    }

    $itemObj | Add-Member -MemberType ScriptMethod -Name GetFolder -Value { return $this }
    $itemObj | Add-Member -MemberType ScriptMethod -Name ParseName `
        -Value (Set-ParseNameMethod -Path $Path -Function ${function:Get-MockedItem} -FileSystem $FileSystem)
    
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
    $topLevelPath = $Path.Split('/', [StringSplitOptions]::RemoveEmptyEntries)[0]
    # Is it one of the mocked top-level folders?
    $matched = @($MockDeviceFileSystem.Keys | `
        Where-Object { $_ -ceq $topLevelPath }).Count -gt 0

    return $matched
}

Mock Get-MTPIterator -RemoveParameterType 'ParentFolder' {
    # If a parent folder has been provided, prepend it.
    if ($ParentFolder -and $ParentFolder.Path) {
        $Path = Join-Path -Path $ParentFolder.Path -ChildPath $Path
        # Join-Path normalises path separators to backslashes, so revert to device path
        # separators, which the other mocks use.
        $Path = $Path.Replace('\', '/')
    }

    $mockedItem = Get-MockedItem -Path $Path -FileSystem $MockFileSystem

    return $mockedItem
}
