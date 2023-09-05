class MockFileSystem {
    [bool] $IsCaseSensitive
    [string[]] $Entries
    [string] $Name

    MockFileSystem([string]$Name, [bool]$IsCaseSensitive, [string[]]$Entries) {
        $this.Name = $Name
        $this.IsCaseSensitive = $IsCaseSensitive
        $this.Entries = $entries
    }

    [void] AddItem([string] $Path) {
        $this.Entries += $Path
    }

    [void] RemoveItem([string] $Path, [string] $PathType) {
        if ($PathType -eq 'Leaf') {
            $Path += '!'
        }

        if ($this.IsCaseSensitive) {
            # Remove is case-sensitive by default.
            $this.Entries.Remove($Path)
        } else {
            $item = $this.Entries | Where-Object { $_ -ieq $Path }
            if ($item) {
                $this.Entries.Remove($item)
            }
        }
    }

    [bool] Contains([string] $Path, [string] $PathType) {
        if ($PathType -eq 'Leaf') {
            $Path += '!'
        }

        if ($this.IsCaseSensitive) {
            return $this.Entries -ccontains $Path
        } else {
            return $this.Entries -contains $Path
        }
    }

    [Object] GetEntry([string] $Path) {
        return $this.GetEntry($Path, 'Container', $false)
    }

    [Object] GetEntry([string] $Path, [string] $PathType) {
        return $this.GetEntry($Path, $PathType, $false)
    }

    [Object] GetEntry([string] $Path, [string] $PathType, [bool] $CreateIfNotExists) {
        if ($PathType -eq 'Leaf') {
            $Path += '!'
        }

        $isFound = $this.Contains($Path, $PathType)

        if ($isFound) {
            $item = if ($this.IsCaseSensitive) {
                $this.Entries | Where-Object { $_ -ceq $Path }
            } else {
                $this.Entries | Where-Object { $_ -eq $Path }
            }

            $itemObj = [PSCustomObject]@{
                IsFolder = $item[-1] -ne '!'
                Name     = Split-Path -Path $Path -Leaf
                # Item     = $item
                Path     = $item
            }
        
            $itemObj | Add-Member -MemberType ScriptMethod -Name GetFolder -Value { return $this }
            $itemObj | Add-Member -MemberType ScriptMethod -Name ParseName `
                -Value {
                    param($Name)
                    $this.GetEntry("$Path/$Name", $PathType)
                }
            
            return $itemObj
        } elseif ($CreateIfNotExists) {
            $this.AddItem($Path)
            return $this.GetEntry($Path, $PathType)
        }

        return $null
    }
}

# This is a representation of our mocked file system on the attached device.
$DeviceFS = @(
    '/',
    'Internal storage',
    'Internal storage/MTPFilesTestDirA',
    'Internal storage/MTPFilesTestDirB',
    'Internal storage/MTPFilesTestDirB/DeviceFileA!',
    'Internal storage/MTPFilesTestDirB/DeviceFileA.txt!',
    'Internal storage/MTPFilesTestDirB/DeviceFileA.jpg!',
    'Internal storage/MTPFilesTestDirB/DeviceFileB.txt!',
    'Internal storage/MTPFilesTestDirC',
    'Internal storage/MTPFile',  # Folder with same name as file
    'Internal storage/MTPFile!',
    'Internal storage/MTPFilesTestFile!',
    'Internal storage/MTPFilesTestFile.doc!'
)

# This represents the host filesystem, relative to the current directory.
$HostFS = @(
    'SomeFile!',
    'SomeFile.txt!',
    'SomeHostFolder',
    'SomeHostFolder/HostSubFolderA',
    'SomeHostFolder/HostSubFolderA/HostFileA!',
    'SomeHostFolder/HostSubFolderA/HostFileA.txt!',
    'SomeHostFolder/HostFileB!',
    'SomeHostFolder/HostFileB.txt!',
    'Internal storage', # Same name as device top-level folder
    'Internal storage/HostSubFolderB',
    'Internal storage/HostFileC.txt!',
    'C:',
    'C:\HostFileD', # Folder with same name as file
    'C:\HostFileD!',
    'C:\HostFileD.txt!',
    'C:\HostSubFolderC/HostFileE!',
    'C:\HostSubFolderC/HostFileE.txt!'
)

$MockDeviceFS   = [MockFileSystem]::new('MockDeviceFS', $true, $DeviceFS)
$MockHostFS     = [MockFileSystem]::new('MockHostFS', $false, $HostFS)


# $MockDeviceFileSystem = @{
#     'Internal storage' = @{
#         'MTPFilesTestDirA' = @{ };
#         'MTPFilesTestDirB' = @{
#             'DeviceFileA' = "file";
#             'DeviceFileA.txt' = 'file';
#             'DeviceFileB.txt' = 'file';
#             'DeviceFileA.jpg' = 'file';
#         };
#         'MTPFilesTestDirC' = @{ };
#         'MTPFilesTestFile' = 'file';
#         'MTPFilesTestFile.doc' = 'file';
#     }
# }

# $MockHostFileSystem = @{
    #     'SomeFile' = 'file';
    #     'SomeFile.txt' = 'file';
    #     'SomeHostFolder' = @{
        #         'HostSubFolderA' = @{
#             'HostFileA' = 'file';
#             'HostFileA.txt' = 'file';
#         };
#         'HostFileB' = 'file';
#         'HostFileB.txt' = 'file';
#     };
#     # This simulates a host directory with the same name as the device's top-level folder.
#     'Internal storage' = @{
#         'HostSubFolderB' = @{ };
#         'HostFileC.txt' = 'file';
#     };
#     'C:' = @{
#         'HostFileD' = 'file';
#         'HostFileD.txt' = 'file';
#         'HostSubFolderC' = @{
#             'HostFileE' = 'file';
#             'HostFileE.txt' = 'file';
#         };
#     };
# }

# function Get-MockedItem {
#     param(
#         [Parameter(Mandatory = $true)]
#         [string]$Path,

#         [scriptblock]$Function,

#         [string[]]$FileSystem,

#         [switch]$CreateIfNotExists
#     )

#     if ($FileSystem.Contains($Path, [StringComparison]::OrdinalIgnoreCase)) {
        
#     }

#     foreach ($section in $pathSections) {
#         # Navigate deeper down the path if the next section exists.
#         if ($currentItem -is [hashtable] -and $currentItem.ContainsKey($section)) {
#             $currentItem = $currentItem[$section]
#         } else {
#             # The path doesn't exist.
#             return $null
#         }
#     }

#     $itemObj = [PSCustomObject]@{
#         IsFolder = $currentItem -is [hashtable]
#         Name     = if ($pathSections) { $pathSections[-1] } else { "/" }
#         Item     = $currentItem
#         Path     = $Path
#     }

#     $itemObj | Add-Member -MemberType ScriptMethod -Name GetFolder -Value { return $this }
#     $itemObj | Add-Member -MemberType ScriptMethod -Name ParseName `
#         -Value (Set-ParseNameMethod -Path $Path -Function ${function:Get-MockedItem} -FileSystem $FileSystem)
    
#     #Write-Host "Path: $($itemObj.Path)"
#     return $itemObj
# }

# function Set-ParseNameMethod {
#     param(
#         [Parameter(Mandatory = $true)]
#         [string]$Path,

#         [Parameter(Mandatory = $true)]
#         [scriptblock]$Function,

#         [string[]]$FileSystem
#     )

#     return {
#         param($Name)
#         & $Function -Path "$Path/$Name" -FileSystem $FileSystem
#     }.GetNewClosure()
# }

# Capture the script location because Pester runs in a different scope.
$BasePath = Split-Path $PSScriptRoot -Parent

# Test a path against our mock host filesystem instead of the host itself.
Mock Test-Path {
    param([string]$Path, [string]$PathType)

    # Remove the script root from the path, turning it into a relative path.
    $Path = $Path.Replace($BasePath, '')
    if ($Path -eq '' -and $PathType -ne 'Leaf') {
        # The path is the base path, so it's a valid container path.
        return $true
    }

    return $MockHostFS.Contains($Path, $PathType)
}

Mock Get-TargetDevice {
    return $MockDeviceFS.GetEntry('/')
}

Mock Get-IsDevicePath -RemoveParameterType 'Device' {
    if ($null -eq $Device) {
        return $false
    }

    # Get the first segment of the path.
    $topLevelPath = $Path.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries)[0]

    # Is it one of the mocked top-level folders?
    return $MockDeviceFS.Contains($topLevelPath, 'Container')
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
            if ($CreateIfNotExists) {
                Add-PathToFileSystem -Path $nextPath -FileSystem $MockDeviceFS -PathType 'Container'
            }
            break
        }

        $currentItem = $nextItem
    }
}

Mock Get-COMFolder {
    $isOnHost = Test-IsHostDirectory -DirectoryPath $Path
    $fileSystem = if ($isOnHost) { $HostFS } else { $DeviceFS }
    $item = Get-MockedItem -Path $Path -FileSystem $fileSystem -CreateIfNotExists $CreateIfNotExists
    if ($item -and $item.IsFolder) {
        return $item
    }
}

# Add a new folder or file to the filesystem.
function Add-PathToFileSystem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$FileSystem,
        [ValidateSet('Container', 'Leaf')]
        [string]$PathType = 'Container'
    )

    if ($PathType -eq 'Leaf') {
        $Path += '!'
    }

    $FileSystem += $Path
}
