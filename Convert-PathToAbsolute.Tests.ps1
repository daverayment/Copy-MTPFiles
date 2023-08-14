Describe "Convert-PathToAbsolute" {

    BeforeAll {
        . $PSScriptRoot/Copy-MTPFilesFunctions.ps1

        $testRoot = Join-Path -Path $PSScriptRoot -ChildPath "Testing"

        # Clean up from any previous tests.
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        
        # Create the test directory structure.
        $existingDir = (New-Item -Path $testRoot -Name "ExistingDir" -ItemType Directory).FullName
        $existingFile = (New-Item -Path $existingDir -Name "ExistingFile.txt" -ItemType File).FullName
        $nonexistentDir = Join-Path -Path $testRoot -ChildPath "NonexistentDir"
        $uniqueRootFile = (New-Item -Path "C:\\" -Name ("TestFile_" + [guid]::NewGuid().ToString() + ".txt") -ItemType File).FullName
    }

    AfterAll {
        # Clean up the test directories and files.
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $uniqueRootFile -ErrorAction SilentlyContinue
    }

    # Tests.
    It "Converts a relative path to an absolute path" {
        $testPath = "Testing\\ExistingDir\\ExistingFile.txt"
        Convert-PathToAbsolute -Path $testPath | Should -BeExactly $existingFile
        Convert-PathToAbsolute -Path $(".\\$testPath") | Should -BeExactly $existingFile
    }

    It "Throws an error if the directory part of the source doesn't exist" {
        { Convert-PathToAbsolute -Path "NonexistentDir\\AnyFile.txt" -IsSource $true } | Should -Throw -ExpectedMessage "The source directory ""*"" does not exist."
    }

    It "Handles a root directory correctly" {
        Convert-PathToAbsolute -Path "C:\\" | Should -BeExactly "C:\\"
    }

    It "Handles a file at the root correctly" {
        Convert-PathToAbsolute -Path $uniqueRootFile | Should -BeExactly $uniqueRootFile
    }

    It "Accepts an already absolute path" {
        $absolutePath = Join-Path -Path $testRoot -ChildPath $existingFile
        Convert-PathToAbsolute -Path $absolutePath | Should -BeExactly $absolutePath
    }

    # ... other tests ...
}
