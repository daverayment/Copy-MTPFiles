. $PSScriptRoot\..\src\Copy-MTPFilesSharedFunctions.ps1

class MockFileSystem {
    [bool]$IsHostFileSystem
    [string[]]$Entries
    [string]$Name
    [string]$BasePath

    MockFileSystem([string]$Name, [bool]$IsHostFileSystem, [string[]]$Entries, [string]$BasePath) {
        $this.Name = $Name
        $this.IsHostFileSystem = $IsHostFileSystem
        $this.Entries = $Entries
        $this.BasePath = $BasePath
    }

    [void] AddItem([string]$Path) {
        $this.Entries += $Path
    }

    [void] RemoveItem([string]$Path, [string]$PathType) {
        if ($PathType -eq 'Leaf') {
            $Path += '!'
        }

        if ($this.IsHostFileSystem) {
            $item = $this.Entries | Where-Object { $_ -ieq $Path }
            if ($item) {
                $this.Entries.Remove($item)
            }
        } else {
            # Remove is case-sensitive by default.
            $this.Entries.Remove($Path)
        }
    }

    [bool] Contains([string]$Path, [string]$PathType) {
        $Path = $this.NormalisePath($Path)

        if ($PathType -eq 'Leaf') {
            $Path += '!'
        } elseif (-not $PathType) {
            return $this.Contains($Path, 'Container') -or
                $this.Contains($Path, 'Leaf')
        }

        if ($Path -eq '' -and $PathType -ne 'Leaf') {
            # The path is the base path, so it's a valid container path.
            return $true
        }

        $hasWildcard = $Path -match '[*?]'

        if ($this.IsHostFileSystem) {
            if ($hasWildcard) {
                # Use -like for wildcard matching.
                return $this.Entries -like $Path
            } else {
                return $this.Entries -contains $Path
            }
        } else {
            if ($hasWildcard) {
                $regex = Convert-WildcardsToRegex -Patterns @($Path)
                return [bool]($this.Entries | Where-Object { $_ -match $regex })
            }
            return $this.Entries -ccontains $Path
        }
    }

    # Ensure paths are formatted properly for the mock host filesystem.
    [string] NormalisePath([string]$Path) {
        # Remove the script root from the path, turning it into a relative path.
        $Path = $Path.Replace($this.BasePath, '')

        # Normalise slashes and remove trailing slash(es).
        $Path = $Path.Replace('\', '/').TrimEnd('/')

        # Ensure relative paths start with "./"
        if ($this.IsHostFileSystem -and
            (-not [IO.Path]::IsPathRooted($Path)) -and 
            (-not $Path.StartsWith('./'))) {
            $Path = "./$Path"
        }

        return $Path
    }

    [Object] GetEntry([string]$Path) {
        return $this.GetEntry($Path, 'Any', $false)
    }

    [Object] GetEntry([string]$Path, [string]$PathType) {
        return $this.GetEntry($Path, $PathType, $false)
    }

    [Object] GetEntry([string]$Path, [string]$PathType, [bool]$CreateIfNotExists) {
        if ($PathType -eq 'Any') {
            $PathType = if ($this.Contains($Path, 'Leaf')) { 'Leaf' } else { 'Container' }
        }

        $Path = $this.NormalisePath($Path)
        $isFound = $this.Contains($Path, $PathType)

        if ($PathType -eq 'Leaf') {
            $Path += '!'
        }

        if ($isFound) {
            # NB: device paths are case-sensitive by default.
            $item = if ($this.IsHostFileSystem) {
                $this.Entries | Where-Object { $_ -eq $Path }
            } else {
                $this.Entries | Where-Object { $_ -ceq $Path }
            }

            $itemName = switch ($Path) {
                '/' { '' }
                '' { '' }
                default { Split-Path -Path $Path -Leaf }
            }

            $itemObj = [PSCustomObject]@{
                IsFolder = $item[-1] -ne '!'
                RawName  = $itemName
                Name     = $itemName.TrimEnd('!')
                # Item     = $item
                Path     = $item
                PathType = $PathType
                MockFS   = $this
            }
        
            $parseNameFn = {
                param($Name)
                $newPath = if ($this.Path) { Join-Path $this.Path $Name } else { $Name }
                $this.MockFS.GetEntry($newPath)
            }

            $itemObj | Add-Member -MemberType ScriptMethod -Name GetFolder -Value { return $this }
            $itemObj | Add-Member -MemberType ScriptMethod -Name ParseName -Value $parseNameFn

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
    '', # Root folder
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
    '.',
    './SomeFile!',
    './SomeFile.txt!',
    './SomeHostFolder',
    './SomeHostFolder/HostSubFolderA',
    './SomeHostFolder/HostSubFolderA/HostFileA!',
    './SomeHostFolder/HostSubFolderA/HostFileA.txt!',
    './SomeHostFolder/HostFileB!',
    './SomeHostFolder/HostFileB.txt!',
    './Internal storage', # Same name as device top-level folder
    './Internal storage/HostSubFolderB',
    './Internal storage/HostFileC.txt!',
    'C:',
    'C:/HostFileD', # Folder with same name as file
    'C:/HostFileD!',
    'C:/HostFileD.txt!',
    'C:/HostSubFolderC/HostFileE!',
    'C:/HostSubFolderC/HostFileE.txt!'
)

# Capture the script location because Pester runs in a different scope.
$BasePath = Split-Path $PSScriptRoot -Parent

$MockDeviceFS   = [MockFileSystem]::new('MockDeviceFS', $false, $DeviceFS, $BasePath)
$MockHostFS     = [MockFileSystem]::new('MockHostFS', $true, $HostFS, $BasePath)

# Test a path against our mock host filesystem instead of the host itself.
Mock Test-Path {
    param([string]$Path, [string]$PathType)

    return $MockHostFS.Contains($Path, $PathType)
}

Mock Get-TargetDevice {
    return $MockDeviceFS.GetEntry('')
}

# Mock Get-IsDevicePath -RemoveParameterType 'Device' {
#     if ($null -eq $Device) {
#         return $false
#     }

#     # Get the first segment of the path.
#     $topLevelPath = $Path.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries)[0]

#     # Is it one of the mocked top-level folders?
#     return $MockDeviceFS.Contains($topLevelPath, 'Container')
# }

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
    $isOnHost = (Get-PathType -Path $Path) -eq [PathType]::Host
    $fileSystem = if ($isOnHost) { $MockHostFS } else { $MockDeviceFS }
    $item = $fileSystem.GetEntry($Path, 'Container', $CreateIfNotExists)
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
