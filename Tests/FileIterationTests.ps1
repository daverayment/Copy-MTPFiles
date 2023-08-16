# Benchmarks various methods for iterating and filtering the files.
# Creates 10,000 files with a quarter of those matching the regular expression.
# Cleans up previous run's files, but 
# 5 benchmark runs for each method. The first of those is removed from the stats, along with any outliers.
# Quick and dirty experiment. Not production code.

# Prepare the test directory.
function SetupTestDirectory {
    # Populate the test directory with test files.
    1..10000 | ForEach-Object {
        # Create some files that match the regular expression and some that don't.
        $filename = if ($_ % 4 -eq 0) { "test$_.txt" } else { "file$_.txt" }
        New-Item -Path (Join-Path $directoryPath $filename) -ItemType File | Out-Null
    }
}

# Clear the test directory if it already exists.
function Clear-TestDirectory {
    if (Test-Path $directoryPath) {
        Remove-Item -Path $directoryPath -Recurse -Force
    }
}

# The different approaches to benchmark follow.
function COMApproach {
    $i = 0
    foreach ($item in $folder.Items()) {
        if ($item.Name -match $regexPattern) {
            $i++
            # Further processing would happen here.
        }
    }
    Write-Host "COMApproach: $i matches found."
}

function HybridApproach {
    $i = 0
    Get-ChildItem -Path $directoryPath -File | Where-Object { $_.Name -match $regexPattern } | ForEach-Object {
        $fileItem = $folder.ParseName($_.Name)
        $i++
        # Further processing would happen here.
    }
    Write-Host "HybridApproach: $i matches found."
}

function ChildItemApproach {
    $i = 0;
    Get-ChildItem -Path $directoryPath -File |
        Where-Object { $_.Name -match $regexPattern } |
        ForEach-Object {
            $i++
            # Further processing would happen here.
        }
    Write-Host "ChildItemApproach: $i matches found."
}

# Benchmark each approach multiple times.
function Benchmark($approach, $runs = 5) {
    $times = for ($i = 0; $i -lt $runs; $i++) {
        $startTime = Get-Date
        &$approach
        $endTime = Get-Date
        ($endTime - $startTime).TotalMilliseconds
    }

    # Remove the first run (warm-up) and any outliers (defined as beyond 1.5x the IQR).
    $times = $times | Sort-Object
    $q1 = $times[[int]($times.Count / 4)]
    $q3 = $times[[int](3 * $times.Count / 4)]
    $iqr = $q3 - $q1
    $times = $times | Where-Object { $q1 - 1.5 * $iqr -le $_ -and $_ -le $q3 + 1.5 * $iqr }
    
    # Return the average of the remaining runs.
    $times | Measure-Object -Average | Select-Object -ExpandProperty Average
}

try {
    # Prepare the COM shell.
    $shellApp = New-Object -ComObject Shell.Application
    if ($null -eq $shellApp) {
        Write-Error "Failed to create a COM Shell Application object." -ErrorAction Stop
    }

    # Set the directory path and regular expression pattern.
    $testPath = Split-Path $MyInvocation.MyCommand.Path
    $directoryPath = Join-Path -Path $testPath -ChildPath "DirectoryPath"
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled
    $regexPattern = New-Object System.Text.RegularExpressions.Regex ("test[0-9]+\.txt", $options)  # Example pattern to match 'test<number>.txt'.

    Write-Host "Creating files in `"$directoryPath`"..."

    # Clear any previous runs' data if it is still present.
    Clear-TestDirectory
        
    # Create the test directory.
    New-Item -Path $directoryPath -ItemType Directory | Out-Null
    
    # COM object for the COM iteration test.
    $folder = $shellApp.NameSpace($directoryPath)
    if ($null -eq $folder) {
        Write-Error "Failed to create a COM Folder object." -ErrorAction Stop
    }

    # Prepare the test directory.
    SetupTestDirectory

    # Perform the benchmarks.
    $COMAverage = Benchmark COMApproach
    $ChildItemAverage = Benchmark ChildItemApproach
    $HybridAverage = Benchmark HybridApproach

    # Print the results.
    Write-Output "COM approach took an average of $COMAverage milliseconds."
    Write-Output "Get-ChildItem approach took an average of $ChildItemAverage milliseconds."
    Write-Output "Hybrid approach took an average of $HybridAverage milliseconds."
}
finally {
    Clear-TestDirectory

    # Release the folder object.
    if ($null -ne $folder) {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) | Out-Null
    }

    # Release the shell object.
    if ($null -ne $shellApp) {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellApp) | Out-Null
    }

    # Force a garbage collection to clean up any remaining COM references.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}