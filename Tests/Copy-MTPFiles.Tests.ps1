enum PathType {
	Host
	Device
	Ambiguous
}


BeforeAll {
    . $PSScriptRoot\..\src\Copy-MTPFilesLogic.ps1
    . $PSScriptRoot\..\src\Copy-MTPFilesSharedFunctions.ps1

    $originalLocation = Get-Location
    Set-Location $PSScriptRoot
}

AfterAll {
    Set-Location $originalLocation
}

Describe "Tests" {
    BeforeAll {
        . .\Mocks.ps1

        $device = Get-TargetDevice
        $parentFolder = $device.GetFolder()

        Mock Get-TopLevelDeviceFolders {
            param($Device = $null)
            return @(
                [PSCustomObject]@{ Name = "Internal storage" },
                [PSCustomObject]@{ Name = "Another folder" }
            )
        }

        # Mock Get-ChildItem {
        #     param([string]$Path)

        #     $MockHostFS.Get
        # }
    }

    It "Accepts current directory as list files source." {
        $result = Main -ListFiles "."
        Write-Output $result
    }

    # It "Clears out the temporary directory." {
    #     $result = Main -Source "." -Destination "Internal storage/SomeBackup"
    # }
}

Describe "Get-COMFolder" {
    BeforeAll {
        $device = Get-TargetDevice
    }

    # TODO: edit to bring in the device details from the user.
    It "Returns a COM reference to the device root." {
        $result = Get-COMFolder -Path "/" -Device $device
        $result.Self.IsFolder | Should -Be $true
        $result.Self.Name | Should -Be "Huawei P30 Pro"
        $result.Self.Type | Should -Be "Mobile Phone"
    }

    It "Lists the contents of the device's top-level folder." {
        $result = Get-FileList -Path "Internal storage" -Device $device -RegexPattern ".*"
    }
}

Describe Get-PathType {
    BeforeAll {
        $Device = $null
    
        Mock Get-TopLevelDeviceFolders {
            param($Device = $null)
            return @(
                [PSCustomObject]@{ Name = "Internal storage" },
                [PSCustomObject]@{ Name = "Another folder" }
            )
        }
    
        # Simulate the current host directory including a directory with the same name as a top-level device folder.
        Mock Test-Path {
            return ($Path.Replace('\', '/') + "/").StartsWith("Internal storage/")
        }
    }

    It "Identifies device paths correctly." {
        # NB: "Internal storage" is a folder on both device and host in this scenario.
        # Get-PathType -Path "Internal storage/somepath" -Device $null | Should -BeExactly [PathType]::Device
        # Get-PathType -Path "Internal storage" -Device $null | Should -Be Device
        # Get-PathType -Path "Internal storage/" -Device $null | Should -Be Device
        Get-PathType -Path "Another folder/somepath" -Device $null | Should -Be Device
        Get-PathType -Path "Another folder" -Device $null | Should -Be Device
        Get-PathType -Path "Another folder/" -Device $null | Should -Be Device
        Get-PathType -Path "Another folder/()!£$%^&()_-+=@';{[}]~#.,¬``" | Should -Be Device
        { Get-PathType -Path "Another FOLDER" -Device $null } |
            Should -Throw -ExpectedMessage 'Could not determine path type*'
    }

    It "Identifies host paths correctly." {
        Get-PathType -Path "./localpath" -Device $null | Should -Be Host
        Get-PathType -Path "./localpath/" -Device $null | Should -Be Host
        Get-PathType -Path ".\localpath" -Device $null | Should -Be Host
        Get-PathType -Path ".\localpath\" -Device $null | Should -Be Host
        Get-PathType -Path "\rootedpath" -Device $null | Should -Be Host
        Get-PathType -Path "/rootedpath" -Device $null | Should -Be Host
        Get-PathType -Path "C:\path" -Device $null | Should -Be Host
        Get-PathType -Path "..\..\localpath" -Device $null | Should -Be Host
        Get-PathType -Path "../../localpath" -Device $null | Should -Be Host
        Get-PathType -Path "..\..\localpath\" -Device $null | Should -Be Host
        Get-PathType -Path "../../localpath/" -Device $null | Should -Be Host
        Get-PathType -Path "./Internal storage/somepath" -Device $null | Should -Be Host
        Get-PathType -Path ".\Internal storage\somepath" -Device $null | Should -Be Host
        Get-PathType -Path "./Internal storage" -Device $null | Should -Be Host
        Get-PathType -Path ".\Internal storage" -Device $null | Should -Be Host
        Get-PathType -Path "./Internal storage/" -Device $null | Should -Be Host
        Get-PathType -Path ".\Internal storage\" -Device $null | Should -Be Host
    }

    It "Identifies ambiguous paths correctly." {
        Get-PathType -Path "Internal storage" -Device $null | Should -Be Ambiguous
        Get-PathType -Path "Internal storage/somepath" -Device $null | Should -Be Ambiguous
    }

    It "Catches invalid paths." {
        { Get-PathType -Path "    " -Device $null } | Should -Throw "Could not determine path type*"
    }
}

Describe "Copy-MTPFiles" {
    It "Lists files in the source directory. Relative path." {
        $result = Main -ListFiles (Join-Path $PSScriptRoot -ChildPath "..")
        $file = $result | Where-Object { $_.Name -eq "Copy-MTPFiles.ps1" }
        $file | Should -Not -BeNullOrEmpty
        # TODO: finish? Test more files?
    }

    It "Validates Failure if Source and Destination to be identical relative directories." {
        $result = Main -Source "." -Destination "."
        $result.Status | Should -Be "Failure"
        $result.Message | Should -Be "Source and Destination directories cannot be the same."
    }

    It "Throws if Source and Destination to be identical absolute paths." {
        $result = Main -Source 'C:\' -Destination 'C:\'
        $result.Status | Should -Be "Failure"
        $result.Message | Should -Be "Source and Destination directories cannot be the same."

    }

    It "Throws if the relative Source directory does not exist." {
        $result = Main -Source "NonexistentDir"
        $result.Status | Should -Be "Failure"
    }

    It "Throws if the absolute Source directory does not exist." {
        $result = Main -Source "C:\NonexistentDir"
        $result.Status | Should -Be "Failure"
    }
}

Describe "Iterator tests" {
    BeforeAll {
        . .\Mocks.ps1

        $device = Get-TargetDevice
        $parentFolder = $device.GetFolder()
    }

    # The following tests test the mocks independently of the application.

    # 'SomeHostFolder' = @{
    #     'HostSubFolderA' = @{
    #         'HostFileA' = 'file';
    #         'HostFileA.txt' = 'file';
    #     };
    #     'HostFileB' = 'file';
    #     'HostFileB.txt' = 'file';
    # };
    # 'Internal storage' = @{
    #     'HostSubFolderB' = @{ };
    #     'HostFileC.txt' = 'file';
    # }

    It "Tests an invalid top-level path." {
        Test-Path 'Invalid' | Should -Be $false
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests the top-level folder. Relative path." {
        Test-Path 'SomeHostFolder' | Should -Be $true
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests a child folder." {
        # NB: backslashes need not be doubled in single-quoted strings.
        Test-Path 'SomeHostFolder\HostSubFolderA' | Should -Be $true
    }

    It "Tests an invalid child path." {
        Test-Path 'SomeHostFolder\Invalid' | Should -Be $false
    }

    It "Tests a file in a top-level folder without an extension." {
        Test-Path 'SomeHostFolder\HostFileB' | Should -Be $true
    }

    It "Tests a file in a top-level folder with an extension." {
        Test-Path 'SomeHostFolder\HostFileB.txt' | Should -Be $true
    }

    It "Tests a file in a child folder without an extension." {
        Test-Path 'SomeHostFolder\HostSubFolderA\HostFileA' | Should -Be $true
    }

    It "Tests a file in a child folder with an extension." {
        Test-Path 'SomeHostFolder\HostSubFolderA\HostFileA.txt' | Should -Be $true
    }

    It "Tests the top-level folder with a trailing slash." {
        Test-Path 'SomeHostFolder\' | Should -Be $true
    }

    It "Tests a mixed-case valid path." {
        # Case-insensitive comparison.
        Test-Path 'someHOSTfolder' | Should -Be $true
    }   


    # Confirm the device root is correct and not 'Internal storage'.
    It "Retrieves the root folder." {
        $root = Get-TargetDevice
        $root.Name | Should -Be ""
    }

    It "Retrieves the top-level folder." {
        $folder = $device.ParseName("Internal storage")
        $folder.Name | Should -Be "Internal storage"
        $folder.Path | Should -Be "Internal storage"
        $folder.PathType | Should -Be "Container"
    }

    It "Retrieves a child folder." {
        $folder = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB")
        $folder.Name | Should -Be "MTPFilesTestDirB"
    }

    It "Identifies the root as a folder." {
        $folder = $device.ParseName('/')
        $folder.IsFolder | Should -Be $true
    }

    It "Identifies the top-level folder as a folder." {
        $folder = $device.ParseName("Internal storage")
        $folder.IsFolder | Should -Be $true
    }

    It "Identifies a child folder as a folder." {
        $folder = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB")
        $folder.IsFolder | Should -Be $true
    }

    It "Retrieves a file without an extension from the top-level folder." {
        $folder = $device.ParseName("Internal storage").GetFolder()
        $file = $folder.ParseName("MTPFilesTestFile")
        $file.Name | Should -Be "MTPFilesTestFile"
    }

    It "Identifies a file without an extension from the top-level folder." {
        $file = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestFile")
        $file.IsFolder | Should -Be $false
    }

    It "Retrieves a file with an extension from the top-level folder." {
        $file = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestFile.doc")
        $file.Name | Should -Be "MTPFilesTestFile.doc"
    }

    It "Identifies a file with an extension from the top-level folder." {
        $file = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestFile.doc")
        $file.IsFolder | Should -Be $false
    }

    It "Retrieves a file with an extension from a child folder." {
        $file = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA.txt")
        $file.Name | Should -Be "DeviceFileA.txt"
    }

    It "Identifies a file with an extension from a child folder." {
        $file = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA.txt")
        $file.IsFolder | Should -Be $false
    }

    It "Retrieves a file without an extension from a child folder." {
        $file = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA")
        $file.Name | Should -Be "DeviceFileA"
    }

    It "Identifies a file without an extension from a child folder." {
        $file = $device.ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA")
        $file.IsFolder | Should -Be $false
    }

    It "Returns `$null for an invalid top-level path." {
        $invalidItem = $device.ParseName("Invalid")
        $invalidItem | Should -Be $null
    }

    It "Returns `$null for an invalid child path." {
        $invalidItem = $device.ParseName("Internal storage").GetFolder().ParseName("Invalid")
        $invalidItem | Should -Be $null
    }
}

Describe "Parameter Validation" {
    It "Detects when the source directory is on the device." {
        $result = & "$PSScriptRoot\..\src\Copy-MTPFiles.ps1" -Source "Internal storage/Download"

    }

    It "Doesn't throw if a single parameter is given." {
        { ..\src\Copy-MTPFiles.ps1 -ListDevices } | Should -Not -Throw
    }

    It "Throws when no parameters are given." {
        $result = & "$PSScriptRoot\..\src\Copy-MTPFiles.ps1" 2>&1
        $errors = @($result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $errors.Count | Should -Be 1
        $errors.Exception.Message | Should -BeLike "No parameters were provided.*"
        $errors.CategoryInfo.Category | Should -Be "InvalidArgument"

        # TODO: check usage information is displayed.
    }

    It "Throws when only common parameters are given." {
        $result = & "$PSScriptRoot\..\src\Copy-MTPFiles.ps1" -Verbose 2>&1
        $errors = @($result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $errors.Count | Should -Be 1
        $errors.Exception.Message | Should -BeLike "No parameters were provided.*"
        $errors.CategoryInfo.Category | Should -Be "InvalidArgument"

        # TODO: check usage information is displayed.
    }
}

Describe "Source parameter resolution" {
    BeforeAll {
        . .\Mocks.ps1

        $device = Get-TargetDevice
    }

    # Host filesystem mocked:
    # 'SomeFile' = 'file';
    # 'SomeFile.txt' = 'file';
    # 'SomeHostFolder' = @{
    #     'HostSubFolderA' = @{
    #         'HostFileA' = 'file';
    #         'HostFileA.txt' = 'file';
    #     };
    #     'HostFileB' = 'file';
    #     'HostFileB.txt' = 'file';
    # };
    # # This simulates a host directory with the same name as the device's top-level folder.
    # 'Internal storage' = @{
    #     'HostSubFolderB' = @{ };
    #     'HostFileC.txt' = 'file';
    # };
    # 'C:' = @{
    #     'HostFileD' = 'file';
    #     'HostFileD.txt' = 'file';
    #     'HostSubFolderC' = @{
        #         'HostFileE' = 'file';
        #         'HostFileE.txt' = 'file';
    #     };
    # };

    # Device filesystem mocked:
    # 'Internal storage' = @{
    #     'MTPFilesTestDirA' = @{ };
    #     'MTPFilesTestDirB' = @{
    #         'DeviceFileA' = "file";
    #         'DeviceFileA.txt' = 'file';
    #         'DeviceFileB.txt' = 'file';
    #         'DeviceFileA.jpg' = 'file';
    #     };
    #     'MTPFilesTestDirC' = @{ };
    #     'MTPFilesTestFile' = 'file';
    #     'MTPFilesTestFile.doc' = 'file';
    # }

    # SourceResolver([string]$Path, [Object]$Device, [string[]]$FilenamePatterns, [bool]$SkipSameFolderCheck) {

    It 'Throws if a Source directory contains wildcards. Absolute path.' {
        { [SourceResolver]::new('C:\Host*\HostFileE.txt', $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Wildcard characters are not allowed in the directory portion of the source path.'
    }

    It 'Throws if a Source directory contains wildcards. Relative path.' {
        { [SourceResolver]::new('.\SomeHost*\HostFileB.txt', $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Wildcard characters are not allowed in the directory portion of the source path.'
    }
    
    It "Test" {
        $sourceInfo = [SourceResolver]::new('Internal storage', $device, '*', $true)
        $sourceInfo.Directory | Should -Be 'Internal storage'
        $sourceInfo.IsOnDevice | Should -Be $true
        $sourceInfo.FilenamePatterns | Should -Be '*'
        $sourceInfo.IsDirectoryMatch | Should -Be $true
    }

    It "Throws if the path resembles a device path but contains backslashes." {
        { [SourceResolver]::new('Internal storage\Download', $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Device path `"*`" cannot contain backslashes. *'
        }

    It "Throws if the Source directory does not exist. Relative path." {
        { [SourceResolver]::new("NonExistentDir", $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Specified source path `"*`" not found.'
    }

    It "Throws if the Source file on the device does not exist. With file extension." {
        { [SourceResolver]::new('Internal storage/NonExistentFile.txt', $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Specified source path `"*`" not found.'
    }

    It "Throws if the Source file on the device does not exist. Without file extension." {
        { [SourceResolver]::new('Internal storage/NonExistentFile', $device, '*', $true) } |
        Should -Throw -ExpectedMessage 'Specified source path `"*`" not found.'
    }

    It "Throws if a device folder includes a wildcard." {
        { [SourceResolver]::new("Internal storage/MTPFiles*DirA/DeviceFileA.txt", $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Wildcard characters are not allowed in the directory portion of the source path.'
    }

    It "Detects a device path including a filename. Top-level folder." {
        $result = [SourceResolver]::new('Internal storage/MTPFilesTestFile.doc', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage'
        $result.FilePattern | Should -Be 'MTPFilesTestFile.doc'
    }

    It "Detects a device path including a filename with a wildcard. Top-level folder." {
        $result = [SourceResolver]::new('Internal storage/MTPFilesTestFile.*', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage'
        $result.FilePattern | Should -Be 'MTPFilesTestFile.*'
    }

    It "Detects a device path including a filename. Child folder." {
        $result = [SourceResolver]::new('Internal storage/MTPFilesTestDirB/DeviceFileA.txt', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage/MTPFilesTestDirB'
        $result.FilePattern | Should -Be 'DeviceFileA.txt'
    }
    
    It "Detects a device path including a filename with a wildcard. Child folder." {
        $result = [SourceResolver]::new('Internal storage/MTPFilesTestDirB/DeviceFileA.*', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage/MTPFilesTestDirB'
        $result.FilePattern | Should -Be 'DeviceFileA.*'
    }

    It "Detects a device path including a trailing slash." {
        $result = [SourceResolver]::new('Internal storage/', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage'
        $result.FilePattern | Should -Be '*'
    }
    
    It "Correctly detects a device folder. Top-level folder." {
        $result = [SourceResolver]::new('Internal storage', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage'
        $result.FilePattern | Should -Be '*'
    }

    It "Correctly detects a device folder. Child folder." {
        $result = [SourceResolver]::new('Internal storage/MTPFilesTestDirA', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage/MTPFilesTestDirA'
        $result.FilePattern | Should -Be '*'
    }

    It "Correctly detects a device folder. Child folder with trailing slash." {
        $result = [SourceResolver]::new('Internal storage/MTPFilesTestDirA/', $device, '*', $true)
        $result.IsOnDevice | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.Directory | Should -Be 'Internal storage/MTPFilesTestDirA'
        $result.FilePattern | Should -Be '*'
    }
    
    # Host filesystem.
    
    It "Throws if the Source is empty." {
        { [SourceResolver]::new('', $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Source cannot be null or empty.'
    }

    It "Throws if the Source is null." {
        { [SourceResolver]::new($null, $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Source cannot be null or empty.'
    }

    It 'Throws if the Source directory does not exist. Relative path.' {
        { [SourceResolver]::new('..\NonExistentDir', $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Specified source path "*" not found.'
    }

    It 'Throws if the Source directory does not exist. Absolute path.' {
        { [SourceResolver]::new('C:\NonExistentDir', $device, '*', $true) } |
        Should -Throw -ExpectedMessage 'Specified source path "*" not found.'
    }
    
    It 'Throws if the current path contains a directory that resembles a device path.' {
        { [SourceResolver]::new('Internal storage/TestFile.txt', $device, '*', $false) } |
            Should -Throw -ExpectedMessage '*is also a top-level device folder.*'
    }
    
    It 'Throws if the Source directory exists, but the file does not exist.' {
        { [SourceResolver]::new('NonExistentFile.txt', $device, '*', $true) } |
            Should -Throw -ExpectedMessage 'Specified source path "*" not found.'
    }

    It 'Throws if a Source directory exists, the file exists, and the FilenamePatterns parameter is provided.' {
        { [SourceResolver]::new('SomeHostFolder\HostFileB.txt', $device, 'Any*', $true) } |
            Should -Throw -ExpectedMessage 'Cannot provide FilenamePatterns parameter when the Source is a file.'
    }

    It 'Throws if a filename is provided and the FilenamePatterns parameter is provided.' {
        { [SourceResolver]::new('SomeFile.txt', $device, 'Any*', $true) } |
            Should -Throw -ExpectedMessage 'Cannot provide FilenamePatterns parameter when the Source is a file.'
    }

    It "Sets the file as the filepattern. Host file with extension in current directory." {
        $result = [SourceResolver]::new('SomeFile.txt', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $BasePath
        $result.FilePattern | Should -Be 'SomeFile.txt'
    }

    It "Sets the file as the filepattern. Host file without extension in current directory." {
        $result = [SourceResolver]::new('SomeFile', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $BasePath
        $result.FilePattern | Should -Be 'SomeFile'
    }

    It "Supports case-insensitivity for host paths." {
        $result = [SourceResolver]::new('SOMEFILE.TXT', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $BasePath
        $result.FilePattern | Should -Be 'SOMEFILE.TXT'
    }

    It "Handles multiple wildcards." {
        $result = [SourceResolver]::new('SomeHostFolder\HostSubFolderA\*File*.txt', $device, '*', $true)
        $result.FilePattern | Should -Be '*File*.txt'
    }

    It "Handles root paths." {
        $result = [SourceResolver]::new('C:\', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.Directory | Should -Be 'C:\'
        $result.FilePattern | Should -Be '*'
        $result.IsDirectoryMatch | Should -Be $true
    }

    It "Handles paths with leading spaces." {
        $result = [SourceResolver]::new('  SomeHostFolder\HostFileB.txt', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $(Join-Path $BasePath 'SomeHostFolder')
        $result.FilePattern | Should -Be 'HostFileB.txt'
    }

    It "Handles paths with trailing spaces." {
        $result = [SourceResolver]::new('SomeHostFolder\HostFileB.txt  ', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $(Join-Path $BasePath 'SomeHostFolder')
        $result.FilePattern | Should -Be 'HostFileB.txt'
    }

    It "Handles relative paths with .." {
        $result = [SourceResolver]::new('SomeHostFolder\..\SomeHostFolder\HostFileB.txt', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $(Join-Path $BasePath 'SomeHostFolder')
        $result.FilePattern | Should -Be 'HostFileB.txt'
    }

    It "Handles mixed separators." {
        $result = [SourceResolver]::new('SomeHostFolder\HostSubFolderA/HostFileA.txt', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $(Join-Path $BasePath 'SomeHostFolder\HostSubFolderA')
        $result.FilePattern | Should -Be 'HostFileA.txt'
    }

    It "Handles paths with only wildcards." {
        $result = [SourceResolver]::new('*', $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        # This is because the wildcard is translated into the current directory.
        $result.IsDirectoryMatch | Should -Be $true
        $result.Directory | Should -Be $BasePath
        $result.FilePattern | Should -Be '*'
    }

    It "Finds a host file when the path separators are forward slashes." {
        $result = [SourceResolver]::new("SomeHostFolder/HostFileB", $device, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $(Join-Path $BasePath 'SomeHostFolder')
        $result.FilePattern | Should -Be 'HostFileB'
    }
    
    It "Succeeds in finding a file in a host directory with the same starting path as the device. (Only if no device connected.)" {
        $result = [SourceResolver]::new('Internal storage/HostFileC.txt', $null, '*', $true)
        $result.IsOnDevice | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.Directory | Should -Be $(Join-Path $BasePath 'Internal storage')
        $result.FilePattern | Should -Be 'HostFileC.txt'
    }
}
