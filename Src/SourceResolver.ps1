class SourceResolver {
	[string]$Source
	[bool]$IsDeviceSource
	[Object]$Device
	[string[]]$FilenamePatterns
	[bool]$SkipSameFolderCheck
	[string[]]$SourceSegments
	[Object[]]$MatchedFolders
	[string]$SourceDirectory
	[string]$SourceFilePattern
	[bool]$IsFileMatch
	[bool]$IsDirectoryMatch

	SourceResolver([string]$Source, [Object]$Device) {
		$this.Initialise($Source, $Device, "*", $false)
	}

	SourceResolver([string]$Source, [Object]$Device, [bool]$SkipSameFolderCheck)
	{
		$this.Initialise($Source, $Device, "*", $SkipSameFolderCheck)
	}

	SourceResolver([string]$Source, [Object]$Device, [string[]]$FilenamePatterns) {
		$this.Initialise($Source, $Device, $FilenamePatterns, $false)
	}

	SourceResolver([string]$Source, [Object]$Device, [string[]]$FilenamePatterns, [bool]$SkipSameFolderCheck) {
		$this.Initialise($Source, $Device, $FilenamePatterns, $SkipSameFolderCheck)
	}

	hidden [void] Initialise([string]$Source, [Object]$Device, [string[]]$FilenamePatterns, [bool]$SkipSameFolderCheck) {
		$this.Source = $Source.Trim('/')
		$this.Device = $Device
		$this.FilenamePatterns = $FilenamePatterns
		$this.SkipSameFolderCheck = $SkipSameFolderCheck

		$this.IsDeviceSource = Get-IsDevicePath -Path $this.Source -Device $this.Device

		if ($this.IsDeviceSource) {
			$this.ResolveDeviceSource()
		} else {
			$this.ResolveHostSource()
		}

		$this.ValidationChecks()
	}

	hidden [void] ResolveDeviceSource() {
		if ($this.Source.Contains('\')) {
			Write-Error ("Device path ""$($this.Source)"" cannot contain backslashes. " +
				"Please use forward slashes instead.") -ErrorAction Stop -Category InvalidArgument
		}

		# Split the path string into segments and also retrieve the matching folders on the device.
		$this.SourceSegments = @($this.Source.Split('/'))
		$this.MatchedFolders = @(Get-MTPIterator -ParentFolder $this.Device.GetFolder() -Path $this.Source)

		# Disallow host directories with the same name as a top-level device folder.
		if (-not [IO.Path]::IsPathRooted($this.Source) -and
			(-not $this.SkipSameFolderCheck) -and
			(Test-Path -Path $this.SourceSegments[0] -PathType Container)) {
				Write-Error ("`"$($this.SourceSegments[0])`" is also a top-level device folder. " +
					"Please change to another directory and retry.") `
					-ErrorAction Stop -Category InvalidArgument
		}

		# A valid path will have the same number of matches returned as there are path string segments.
		if ($this.MatchedFolders.Length -eq $this.SourceSegments.Length) {
			if ($this.MatchedFolders[-1] -and $this.MatchedFolders[-1].IsFolder) {
				# The entire path has been found as folders on the device.
				$this.SourceDirectory = $this.SourceSegments -join '/'
				$this.SourceFilePattern = $this.FilenamePatterns
				$this.IsDirectoryMatch = $true
			} else {
				# The last part of the path didn't match a folder, so assume it is a file.
				$this.SourceDirectory = (Split-Path $this.Source -Parent).Replace('\', '/')
				$this.SourceFilePattern = Split-Path $this.Source -Leaf
				$this.IsFileMatch = $true
			}
		}	
	}

	hidden [void] ResolveHostSource() {
		$normalisedPath = [IO.Path]::GetFullPath($this.Source)
		if (Test-Path $normalisedPath) {
			$this.IsFileMatch = (Test-Path $normalisedPath -PathType Leaf)
			$this.IsDirectoryMatch = (Test-Path $normalisedPath -PathType Container)

			# Disallow both a file and a directory match (this can happen if wildcards are supplied.)
			if ($this.IsFileMatch -and $this.IsDirectoryMatch) {
				Write-Error "Specified source path `"$($this.Source)`" cannot be both a file and a directory." `
					-ErrorAction Stop -Category InvalidArgument
			}

			$this.SourceDirectory = if ($this.IsFileMatch) { Split-Path $normalisedPath -Parent } else { $normalisedPath }
			$this.SourceFilePattern = if ($this.IsFileMatch) { Split-Path $normalisedPath -Leaf } else { $this.FilenamePatterns }
		}
	}

	hidden [void] ValidationChecks() {
		if (-not $this.IsFileMatch -and -not $this.IsDirectoryMatch) {
			Write-Error "Specified source path `"$($this.Source)`" not found." -ErrorAction Stop -Category ObjectNotFound
		}

		# Check for wildcards in the directory part of the source path.
		if ($this.SourceDirectory -match "\*|\?") {
			Write-Error "Wildcard characters are not allowed in the directory portion of the source path." `
				-ErrorAction Stop -Category InvalidArgument
		}

		if (-not $this.IsDeviceSource) {
			# NB: we do not need to do a check for the device here because it has already been done above.
			if (-not (Test-Path -Path $this.SourceDirectory)) {
				Write-Error "Specified source directory `"$($this.SourceDirectory)`" does not exist." `
					-ErrorAction Stop -Category ObjectNotFound
			}		
		}

		# At this point, we know that the folders part of the source path is valid.

		# Process wildcards or specific file in the source path.
		if (($this.SourceFilePattern -match "\*|\?")) {
			if ($this.FilenamePatterns -ne "*") {
				Write-Error ("Cannot specify wildcards in the Source parameter when the FilenamePatterns " +
					"parameter is also provided.") -ErrorAction Stop -Category InvalidArgument
			}
		} else {
			$fileExists = $false

			# $SourceFilePattern should contain the exact filename we're looking for.
			if ($this.IsDeviceSource) {
				$lastFolder = if ($this.MatchedFolders[-1] -and $this.MatchedFolders[-1].IsFolder) {
					$this.MatchedFolders[-1]
				} else {
					$this.MatchedFolders[-2]
				}

				if ($lastFolder.ParseName($this.SourceSegments[-1])) {
					$fileExists = $true
				}
			} else {
				$fileExists = Test-Path -Path $this.Source -PathType Leaf
			}

			if ($fileExists) {
				if ($this.FilenamePatterns -ne "*") {
					# We do not allow wildcard patterns when the source resolves to a single file.
					Write-Error "Cannot provide FilenamePatterns parameter when the Source is a file." `
						-ErrorAction Stop -Category InvalidArgument					
				}
			} else {
				# If the source path refers to a single file, it must exist.
				Write-Error "Specified source path `"$($this.Source)`" not found." `
					-ErrorAction Stop -Category ObjectNotFound
			}
		}
	}
}