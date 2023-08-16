BeforeAll {
    . $PSScriptRoot\..\Copy-MTPFilesLogic.ps1
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

Describe "Initialize-SourceParameter" {
    It "Throws if a Source directory contains wildcards. Relative path." {
        {  & Initialize-SourceParameter -Source "..\\..\\SomeDir*ory\\AFile.txt" } |
            Should -Throw -ExpectedMessage "Wildcard characters are not allowed in the directory portion of the source path."
    }

    It "Throws if a Source directory contains wildcards. Absolute path." {
        { Initialize-SourceParameter -Source "C:\\SomeDir*ory\\AFile.txt" } |
            Should -Throw -ExpectedMessage "Wildcard characters are not allowed in the directory portion of the source path."
    }

    It "Throws if a Source file contains wildcards and the FilenamePatterns parameter is provided." {
        { Initialize-SourceParameter -Source "AnyExtension.*" -FilenamePattern "Any*" } |
            Should -Throw -ExpectedMessage "Cannot specify wildcards in the Source parameter when the FilenamePatterns parameter is also provided."
    }

}