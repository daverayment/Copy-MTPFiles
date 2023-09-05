BeforeAll {
    . $PSScriptRoot\..\src\Copy-MTPFilesLogic.ps1

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
    }

    It "Accepts current directory as list files source." {
        $result = Main -ListFiles "."
    }

    It "Clears out the temporary directory." {
        $result = Main -Source "." -Destination "Internal storage/SomeBackup"
    }
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

Describe "Get-IsDevicePath Validation" {
    BeforeAll {
        . .\Mocks.ps1

        $device = Get-TargetDevice
    }

    It "Detects when the supplied path is the top-level folder on the device." {
        Get-IsDevicePath "Internal storage" $device | Should -Be $true
    }

    It "Detects when the supplied path is a top-level folder on the device with incorrect case." {
        Get-IsDevicePath "internal STORAGE" $device | Should -Be $false
    }

    It "Detects when the supplied path is the top-level folder on the device. With trailing slash." {
        Get-IsDevicePath "Internal storage/" $device | Should -Be $true
    }

    It "Detects when the supplied path is a top-level folder on the device. With trailing slash and incorrect case." {
        Get-IsDevicePath "internal STORAGE/" $device | Should -Be $false
    }

    It "Detects when the supplied path is a nested folder on the device." {
        Get-IsDevicePath "Internal storage/Download" $device | Should -Be $true
    }

    It "Detects when the supplied path is not a folder on the device." {
        Get-IsDevicePath "NotADeviceFolder" $device | Should -Be $false
    }

    It "Detects when the supplied path is not a folder on the device. Host folder example." {
        Get-IsDevicePath "\NotADeviceFolder\SomeFile*.txt" $device | Should -Be $false
    }

    It "Differentiates between paths with similar starting names on the device." {
        Get-IsDevicePath "Internal storage backup folder which does not exist" $device | Should -Be $false
    }

    It "Handles paths with spaces." {
        Get-IsDevicePath "    " $device | Should -Be $false
    }

    It "Handles paths with special characters." {
        Get-IsDevicePath "Internal storage/()!£$%^&()_-+=@';{[}]~#.,¬``" $device | Should -Be $true
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
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests an invalid child path." {
        Test-Path 'SomeHostFolder\Invalid' | Should -Be $false
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests a file in a top-level folder without an extension." {
        Test-Path 'SomeHostFolder\HostFileB' | Should -Be $true
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests a file in a top-level folder with an extension." {
        Test-Path 'SomeHostFolder\HostFileB.txt' | Should -Be $true
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests a file in a child folder without an extension." {
        Test-Path 'SomeHostFolder\HostSubFolderA\HostFileA' | Should -Be $true
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests a file in a child folder with an extension." {
        Test-Path 'SomeHostFolder\HostSubFolderA\HostFileA.txt' | Should -Be $true
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests the top-level folder with a trailing slash." {
        Test-Path 'SomeHostFolder\' | Should -Be $true
        Should -Invoke Test-Path -Times 1 -Exactly
    }

    It "Tests a mixed-case valid path." {
        # Case-insensitive comparison.
        Test-Path 'someHOSTfolder' | Should -Be $true
        Should -Invoke Test-Path -Times 1 -Exactly
    }   


    # Confirm the device root is correct and not 'Internal storage'.
    It "Retrieves the root folder." {
        $root = Get-TargetDevice
        $root.Name | Should -Be "/"
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Retrieves the top-level folder." {
        $folder = (Get-TargetDevice).ParseName("Internal storage")
        $folder.Name | Should -Be "Internal storage"
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Retrieves a child folder." {
        $folder = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB")
        $folder.Name | Should -Be "MTPFilesTestDirB"
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Identifies the root as a folder." {
        $folder = (Get-TargetDevice).ParseName("/")
        $folder.IsFolder | Should -Be $true
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Identifies the top-level folder as a folder." {
        $folder = (Get-TargetDevice).ParseName("Internal storage")
        $folder.IsFolder | Should -Be $true
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Identifies a child folder as a folder." {
        $folder = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB")
        $folder.IsFolder | Should -Be $true
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Retrieves a file without an extension from the top-level folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestFile")
        $file.Name | Should -Be "MTPFilesTestFile"
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Identifies a file without an extension from the top-level folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestFile")
        $file.IsFolder | Should -Be $false
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Retrieves a file with an extension from the top-level folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestFile.doc")
        $file.Name | Should -Be "MTPFilesTestFile.doc"
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Identifies a file with an extension from the top-level folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestFile.doc")
        $file.IsFolder | Should -Be $false
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Retrieves a file with an extension from a child folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA.txt")
        $file.Name | Should -Be "DeviceFileA.txt"
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Identifies a file with an extension from a child folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA.txt")
        $file.IsFolder | Should -Be $false
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Retrieves a file without an extension from a child folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA")
        $file.Name | Should -Be "DeviceFileA"
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Identifies a file without an extension from a child folder." {
        $file = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("MTPFilesTestDirB").GetFolder().ParseName("DeviceFileA")
        $file.IsFolder | Should -Be $false
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Returns `$null for an invalid top-level path." {
        $invalidItem = (Get-TargetDevice).ParseName("Invalid")
        $invalidItem | Should -Be $null
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
    }

    It "Returns `$null for an invalid child path." {
        $invalidItem = (Get-TargetDevice).ParseName("Internal storage").GetFolder().ParseName("Invalid")
        $invalidItem | Should -Be $null
        Should -Invoke Get-TargetDevice -Times 1 -Exactly
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

    It 'Throws if a Source directory contains wildcards. Absolute path.' {
        { [SourceResolver]::new('C:\Host*\HostFileE.txt', $device, $true) } |
            Should -Throw -ExpectedMessage 'Wildcard characters are not allowed in the directory portion of the source path.'
    }

    It 'Throws if a Source directory contains wildcards. Relative path.' {
        { [SourceResolver]::new('.\SomeHost*\HostFileB.txt', $device, $true) } |
            Should -Throw -ExpectedMessage 'Wildcard characters are not allowed in the directory portion of the source path.'
    }
    
    It "Test" {
        $sourceInfo = [SourceResolver]::new("Internal storage", $device, "*", $true)
        $sourceInfo.SourceDirectory | Should -Be "Internal storage"
        $sourceInfo.IsDeviceSource | Should -Be $true
        $sourceInfo.FilenamePatterns | Should -Be "*"
        $sourceInfo.IsDirectoryMatch | Should -Be $true
    }

    It "Throws if the path resembles a device path but contains backslashes." {
        { [SourceResolver]::new("Internal storage\Download", $device, $true) } |
            Should -Throw -ExpectedMessage "Device path ""*"" cannot contain backslashes. *"
        }

    It "Throws if the Source directory does not exist. Relative path." {
        { [SourceResolver]::new("NonExistentDir", $device, $true) } |
            Should -Throw -ExpectedMessage "Specified source path ""*"" not found."
    }

    It "Throws if the Source file on the device does not exist. With file extension." {
        { [SourceResolver]::new("Internal storage/NonExistentFile.txt", $device, $true) } |
            Should -Throw -ExpectedMessage "Specified source path ""*"" not found."
    }

    It "Throws if the Source file on the device does not exist. Without file extension." {
        { [SourceResolver]::new("Internal storage/NonExistentFile", $device, $true) } |
        Should -Throw -ExpectedMessage "Specified source path ""*"" not found."
    }

    It "Throws if a device folder includes a wildcard." {
        { [SourceResolver]::new("Internal storage/MTPFiles*DirA/DeviceFileA.txt", $device, $true) } |
            Should -Throw -ExpectedMessage "Wildcard characters are not allowed in the directory portion of the source path."
    }

    It "Detects a device path including a filename. Top-level folder." {
        $result = [SourceResolver]::new("Internal storage/MTPFilesTestFile.doc", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage"
        $result.SourceFilePattern | Should -Be "MTPFilesTestFile.doc"
    }

    It "Detects a device path including a filename with a wildcard. Top-level folder." {
        $result = [SourceResolver]::new("Internal storage/MTPFilesTestFile.*", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage"
        $result.SourceFilePattern | Should -Be "MTPFilesTestFile.*"
    }

    It "Detects a device path including a filename. Child folder." {
        $result = [SourceResolver]::new("Internal storage/MTPFilesTestDirB/DeviceFileA.txt", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage/MTPFilesTestDirB"
        $result.SourceFilePattern | Should -Be "DeviceFileA.txt"
    }
    
    It "Detects a device path including a filename with a wildcard. Child folder." {
        $result = [SourceResolver]::new("Internal storage/MTPFilesTestDirB/DeviceFileA.*", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage/MTPFilesTestDirB"
        $result.SourceFilePattern | Should -Be "DeviceFileA.*"
    }

    It "Detects a device path including a trailing slash." {
        $result = [SourceResolver]::new("Internal storage/", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage"
        $result.SourceFilePattern | Should -Be "*"
    }
    
    It "Correctly detects a device folder. Top-level folder." {
        $result = [SourceResolver]::new("Internal storage", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage"
        $result.SourceFilePattern | Should -Be "*"
    }

    It "Correctly detects a device folder. Child folder." {
        $result = [SourceResolver]::new("Internal storage/MTPFilesTestDirA", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage/MTPFilesTestDirA"
        $result.SourceFilePattern | Should -Be "*"
    }

    It "Correctly detects a device folder. Child folder with trailing slash." {
        $result = [SourceResolver]::new("Internal storage/MTPFilesTestDirA/", $device, $true)
        $result.IsDeviceSource | Should -Be $true
        $result.IsDirectoryMatch | Should -Be $true
        $result.SourceDirectory | Should -Be "Internal storage/MTPFilesTestDirA"
        $result.SourceFilePattern | Should -Be "*"
    }
    
    # Host filesystem.
    
    It "Throws if the Source is empty." {
        { [SourceResolver]::new("", $device, $true) } |
            Should -Throw -ExpectedMessage "Source cannot be null or empty."
    }

    It "Throws if the Source is null." {
        { [SourceResolver]::new($null, $device, $true) } |
            Should -Throw -ExpectedMessage "Source cannot be null or empty."
    }

    It 'Throws if the Source directory does not exist. Relative path.' {
        { [SourceResolver]::new('..\NonExistentDir', $device, $true) } |
            Should -Throw -ExpectedMessage 'Specified source path "*" not found.'
    }

    It 'Throws if the Source directory does not exist. Absolute path.' {
        { [SourceResolver]::new('C:\NonExistentDir', $device, $true) } |
        Should -Throw -ExpectedMessage 'Specified source path "*" not found.'
    }
    
    It 'Throws if the current path contains a directory that resembles a device path.' {
        { [SourceResolver]::new('Internal storage/TestFile.txt', $device, $false) } |
            Should -Throw -ExpectedMessage '*is also a top-level device folder.*'
    }
    
    It 'Throws if the Source directory exists, but the file does not exist.' {
        { [SourceResolver]::new('NonExistentFile.txt', $device, $true) } |
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
        $result = [SourceResolver]::new("SomeFile.txt", $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $BasePath
        $result.SourceFilePattern | Should -Be "SomeFile.txt"
    }

    It "Sets the file as the filepattern. Host file without extension in current directory." {
        $result = [SourceResolver]::new("SomeFile", $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $BasePath
        $result.SourceFilePattern | Should -Be "SomeFile"
    }

    It "Supports case-insensitivity for host paths." {
        $result = [SourceResolver]::new('SOMEFILE.TXT', $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $BasePath
        $result.SourceFilePattern | Should -Be 'SOMEFILE.TXT'
    }

    It "Handles multiple wildcards." {
        $result = [SourceResolver]::new('SomeHostFolder\HostSubFolderA\*File*.txt', $device, $true)
        $result.SourceFilePattern | Should -Be '*File*.txt'
    }

    It "Handles root paths." {
        $result = [SourceResolver]::new('C:\', $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.SourceDirectory | Should -Be 'C:\'
        $result.SourceFilePattern | Should -Be '*'
        $result.IsDirectoryMatch | Should -Be $true
    }

    It "Handles paths with leading spaces." {
        $result = [SourceResolver]::new('  SomeHostFolder\HostFileB.txt', $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $(Join-Path $BasePath "SomeHostFolder")
        $result.SourceFilePattern | Should -Be "HostFileB.txt"
    }

    It "Handles paths with trailing spaces." {
        $result = [SourceResolver]::new('SomeHostFolder\HostFileB.txt  ', $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $(Join-Path $BasePath "SomeHostFolder")
        $result.SourceFilePattern | Should -Be "HostFileB.txt"
    }

    It "Handles relative paths with .." {
        $result = [SourceResolver]::new('SomeHostFolder\..\SomeHostFolder\HostFileB.txt', $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $(Join-Path $BasePath "SomeHostFolder")
        $result.SourceFilePattern | Should -Be "HostFileB.txt"
    }

    It "Handles mixed separators." {
        $result = [SourceResolver]::new('SomeHostFolder\HostSubFolderA/HostFileA.txt', $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $(Join-Path $BasePath 'SomeHostFolder\HostSubFolderA')
        $result.SourceFilePattern | Should -Be "HostFileA.txt"
    }

    It "Handles paths with only wildcards." {
        $result = [SourceResolver]::new('*', $device, $true)
        $result.IsDeviceSource | Should -Be $false
        # This is because the wildcard is translated into the current directory.
        $result.IsDirectoryMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $BasePath
        $result.SourceFilePattern | Should -Be '*'
    }

    It "Finds a host file when the path separators are forward slashes." {
        $result = [SourceResolver]::new("SomeHostFolder/HostFileB", $device, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $(Join-Path $BasePath "SomeHostFolder")
        $result.SourceFilePattern | Should -Be "HostFileB"
    }
    
    It "Succeeds in finding a file in a host directory with the same starting path as the device. (Only if no device connected.)" {
        $result = [SourceResolver]::new("Internal storage/HostFileC.txt", $null, $true)
        $result.IsDeviceSource | Should -Be $false
        $result.IsFileMatch | Should -Be $true
        $result.SourceDirectory | Should -Be $(Join-Path $BasePath "Internal storage")
        $result.SourceFilePattern | Should -Be "HostFileC.txt"
    }
}
