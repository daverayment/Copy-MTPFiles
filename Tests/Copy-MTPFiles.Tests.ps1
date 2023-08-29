BeforeAll {
    . $PSScriptRoot\..\src\Copy-MTPFilesLogic.ps1

    $originalLocation = Get-Location
    Set-Location $PSScriptRoot
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
        $result = Main -Source "C:\" -Destination "C:\"
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

Describe "Resolve-SourceParameter" {
    BeforeAll {
        if (Test-Path "SomeTestFile.txt") {
            Remove-Item "SomeTestFile.txt"
        }
        if (Test-Path "Internal storage") {
            Remove-Item "Internal storage" -Force -Recurse
        }
        New-Item "Internal storage" -ItemType Directory
        New-Item "Internal storage\TestFile.txt" -ItemType File
        New-Item "SomeTestFile.txt" -ItemType File
        $Device = Get-TargetDevice
    }

    AfterAll {
        Remove-Item "Internal storage" -Force
        Remove-Item "SomeTestFile.txt"
    }

    It "Correctly differentiates a host path that resembles a device path." {
        $result = Resolve-SourceParameter -Source "Internal storage/TestFile.txt" -Device $Device
        $result.Source | Should -Be "Internal storage"
        $result.FilenamePatterns | Should -Be "TestFile.txt"
        $result.IsDeviceSource | Should -Be $false
    }

    # TODO: mock the device filesystem.
    It "Detects a device path including a filename. Top-level folder." {
        $result = Resolve-SourceParameter -Source "Internal storage/TestFile.txt" -Device $Device
        $result.Source | Should -Be "Internal storage"
        $result.FilenamePatterns | Should -Be "TestFile.txt"
    }

    It "Detects a device path including a filename with a wildcard. Top-level folder." {
        $result = Resolve-SourceParameter -Source "Internal storage/TestFile.*" -Device $Device
        $result.Source | Should -Be "Internal storage"
        $result.FilenamePatterns | Should -Be "TestFile.*"
    }

    It "Detects a device path including a filename. Child folder." {
        $result = Resolve-SourceParameter -Source "Internal storage/MTPFilesTestDir/TestFile.txt" -Device $Device
        $result.Source | Should -Be "Internal storage"
        $result.FilenamePatterns | Should -Be "TestFile.txt"
    }

    It "Detects a device path including a filename with a wildcard. Child folder." {
        $result = Resolve-SourceParameter -Source "Internal storage/MTPFilesTestDir/TestFile.*" -Device $Device
        $result.Source | Should -Be "Internal storage"
        $result.FilenamePatterns | Should -Be "TestFile.*"
    }

    It "Detects a device path including a trailing slash." {
        $result = Resolve-SourceParameter -Source "Internal storage/" -Device $Device
        $result.Source | Should -Be "Internal storage"
        $result.FilenamePatterns | Should -Be "*"
    }

    It "Correctly detects a device folder. Top-level folder." {
        $result = Resolve-SourceParameter -Source "Internal storage" -Device $Device
        $result.Source | Should -Be "Internal storage"
        $result.FilenamePatterns | Should -Be "*"
    }

    It "Correctly detects a device folder. Child folder." {
        $result = Resolve-SourceParameter -Source "Internal storage/Download" -Device $Device
        $result.Source | Should -Be "Internal storage/Download"
        $result.FilenamePatterns | Should -Be "*"
    }

    It "Sets the file as the filepattern. Host file in current directory." {
        $result = Resolve-SourceParameter -Source "SomeTestFile.txt" -Device $Device
        $result.FilenamePatterns | Should -Be "SomeTestFile.txt"
        $result.Source | Should -Be "."
    }

    It "Throws if the Source directory does not exist. Current path." {
        { Resolve-SourceParameter -Source "NonExistentDir\File.txt" } |
            Should -Throw -ExpectedMessage "Specified source directory ""*"" does not exist."
    }

    It "Throws if the Source directory does not exist. Relative path." {
        { Resolve-SourceParameter -Source "..\NonExistentDir\File.txt" } |
            Should -Throw -ExpectedMessage "Specified source directory ""*"" does not exist."
    }

    It "Throws if the Source directory does not exist. Absolute path." {
        { Resolve-SourceParameter -Source "C:\NonExistentDir\File.txt" } |
            Should -Throw -ExpectedMessage "Specified source directory ""*"" does not exist."
    }

    It "Throws if the Source directory exists, but the file does not exist." {
        { Resolve-SourceParameter -Source "NonExistentFile.txt" } |
            Should -Throw -ExpectedMessage "Specified source file ""*"" does not exist."
    }

    It "Throws if a Source directory exists, the file exists, and the FilenamePatterns parameter is provided." {
        { Resolve-SourceParameter -Source "..\src\Copy-MTPFiles.ps1" -FilenamePattern "Any*" } |
            Should -Throw -ExpectedMessage "Cannot provide FilenamePatterns parameter when the Source is a file."
    }
    
    It "Throws if a Source directory contains wildcards. Relative path." {
        { Resolve-SourceParameter -Source "..\SomeDir*ory\File.txt" } |
            Should -Throw -ExpectedMessage "Wildcard characters are not allowed in the directory portion of the source path."
    }

    It "Throws if a Source directory contains wildcards. Absolute path." {
        { Resolve-SourceParameter -Source "C:\SomeDir*ory\File.txt" } |
            Should -Throw -ExpectedMessage "Wildcard characters are not allowed in the directory portion of the source path."
    }

    It "Throws if a filename is provided and the FilenamePatterns parameter is provided." {
        { Resolve-SourceParameter -Source "SomeFile.txt" -FilenamePattern "Any*" } |
            Should -Throw -ExpectedMessage "Cannot provide FilenamePatterns parameter when the Source is a file."
    }

    It "Throws if a Source is null or empty." {
        { Resolve-SourceParameter -Source "" } |
            Should -Throw -ExpectedMessage "Source cannot be null or empty."
    }

    # It "Throws if a Source file contains wildcards and the FilenamePatterns parameter is provided." {
    #     { Initialize-SourceParameter -Source "AnyExtension.*" -FilenamePattern "Any*" } |
    #         Should -Throw -ExpectedMessage "Cannot specify wildcards in the Source parameter when the FilenamePatterns parameter is also provided."
    # }
}

AfterAll {
    Set-Location $originalLocation
}