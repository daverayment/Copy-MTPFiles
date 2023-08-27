Describe "PathTests" {
    BeforeAll {
        . $PSScriptRoot\..\Copy-MTPFilesLogic.ps1

        # Our test directory structure lives under this subdirectory. 
        $testSubDirName = "TestFiles"

        $originalLocation = Get-Location
        Set-Location $PSScriptRoot

        $testRoot = Join-Path -Path $PSScriptRoot -ChildPath $testSubDirName

        Write-Host "Test root: $testRoot"

        # Clean up from any previous tests.
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    
        # Create the test directory structure.

        # (Host dirs/files all relative to `<ProjectRootFolder>\TestFiles`):
        # - `TestFolderA` [dir] (no files in this folder)
        # - `TestFolderB` [dir]
        #     - `TestFileA.txt` [file]
        #     - `TestFileB.txt` [file]
        #     - `TestFileA.jpg` [file]
        # - `TestFolderC` [dir]
        #     - `NestedFolderD` [dir]
        #         - `TestFileC.txt` [file]
        # - `TestFile` [file] (NB: no extension)
        # - `TestFile.doc` [file]

        $testFolderA = (New-Item -Path $testRoot -Name "TestFolderA" -ItemType Directory).FullName
        $testFolderB = (New-Item -Path $testRoot -Name "TestFolderB" -ItemType Directory).FullName
        $testFolderC = (New-Item -Path $testRoot -Name "TestFolderC" -ItemType Directory).FullName
        $testFileA = (New-Item -Path $testFolderB -Name "TestFileA.txt" -ItemType File).FullName
        $testFileB = (New-Item -Path $testFolderB -Name "TestFileB.txt" -ItemType File).FullName
        $testFileA2 = (New-Item -Path $testFolderB -Name "TestFileA.jpg" -ItemType File).FullName
        $nestedFolderD = (New-Item -Path $testFolderC -Name "NestedFolderD" -ItemType Directory).FullName
        $testFileC = (New-Item -Path $nestedFolderD -Name "TestFileC.txt" -ItemType File).FullName
        $fileNoExtension = (New-Item -Path $testRoot -Name "TestFileNoExtension" -ItemType File).FullName
        $fileWithExtension = (New-Item -Path $testRoot -Name "TestFile.doc" -ItemType File).FullName

        # $existingDir = (New-Item -Path $testRoot -Name "ExistingDir" -ItemType Directory).FullName
        # $existingFile = (New-Item -Path $existingDir -Name "ExistingFile.txt" -ItemType File).FullName
        # $nonexistentDir = Join-Path -Path $testRoot -ChildPath "NonexistentDir"
        # $uniqueRootFile = (New-Item -Path "C:\\" -Name ("TestFile_" + [guid]::NewGuid().ToString() + ".txt") -ItemType File).FullName
    }

    AfterAll {

    }

    Describe "Convert-PathToAbsolute" {

        BeforeAll {
        }

        AfterAll {
            # Clean up the test directories and files.
            Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $uniqueRootFile -ErrorAction SilentlyContinue

            # Restore original working folder.
            Set-Location $originalLocation
        }

        # Tests.
        It "Converts a relative path to an absolute path" {
            $testPath = "$testSubDirName\\ExistingDir\\ExistingFile.txt"
            Convert-PathToAbsolute -Path $testPath | Should -BeExactly $existingFile
            Convert-PathToAbsolute -Path $(".\\$testPath") | Should -BeExactly $existingFile
        }

        It "Throws an error if the directory part of the source doesn't exist" {
            { Convert-PathToAbsolute -Path "NonexistentDir\\AnyFile.txt" -IsSource $true } |
            Should -Throw -ExpectedMessage "The source directory ""*"" does not exist."
        }

        It "Handles a root directory correctly" {
            Convert-PathToAbsolute -Path "C:\\" | Should -BeExactly "C:\\"
        }

        It "Handles a file at the root correctly" {
            Convert-PathToAbsolute -Path $uniqueRootFile | Should -BeExactly $uniqueRootFile
        }

        It "Accepts an already absolute path" {
            Convert-PathToAbsolute -Path $existingFile | Should -BeExactly $existingFile
        }

        # ... other tests ...
    }
}