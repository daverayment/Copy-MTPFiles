class SourceResolver {
	[string]$Path
	[bool]$IsOnDevice = $false
	[bool]$IsOnHost = $false
	[Object]$Device
	[string[]]$FilenamePatterns
	[bool]$SkipSameFolderCheck = $false
	[string[]]$PathSegments
	[Object[]]$MatchedFolders
	[string]$Directory
	[string]$FilePattern
	[bool]$IsFileMatch = $false
	[bool]$IsDirectoryMatch = $false
	[Object]$Folder	# resolved COM folder for the Source

	# SourceResolver constructor which allows all parameters to be set.
	SourceResolver([string]$Path, [Object]$Device, [string[]]$FilenamePatterns, [bool]$SkipSameFolderCheck) {
		$this.Initialise($Path, $Device, $FilenamePatterns, $SkipSameFolderCheck)
	}

	# Split the path string into segments and also retrieve the matching folders on the device.
	hidden [void] GetMatchingDeviceFolders() {
		$this.PathSegments = @($this.Path.Split('/'))
		$this.MatchedFolders = @(Get-MTPIterator -ParentFolder $this.Device.GetFolder() -Path $this.Path)
	}

	hidden [void] Initialise([string]$Path, [Object]$Device, [string[]]$FilenamePatterns, [bool]$SkipSameFolderCheck) {
		$this.Path = $Path.Trim().Trim('/')
		$this.Device = $Device
		$this.FilenamePatterns = $FilenamePatterns
		$this.SkipSameFolderCheck = $SkipSameFolderCheck

		if (-not $this.Path) {
			throw [System.ArgumentNullException]::new("Path cannot be null or empty.")
		}

		# The user likely intends to want to match all files in the current directory.
		if ($this.Path -eq "*") {
			$this.Path = "."
		}

		# TODO: 'PathTarget' instead?
		$pathType = Get-PathType -Path $this.Path -Device $Device
		if ($pathType -eq [PathType]::Ambiguous) {
			throw [System.ArgumentException]::new("Ambiguous path `"$($this.Path)`".")
		}

		$this.IsOnHost = $pathType -eq [PathType]::Host
		$this.IsOnDevice = $pathType -eq [PathType]::Device

		if ($this.IsOnDevice) {
			$this.ResolveDevicePath()
		} else {
			$this.ResolveHostPath()
		}

		$this.Validate()

		# If the file part of the path was specified and included wildcards, copy over to
		# FilenamePatterns for regex conversion later.
		if ($this.FilePattern) {
			$this.FilenamePatterns = @($this.FilePattern)
		}

		$this.Folder = Get-COMFolder -Path $this.Directory -Device $this.Device
	}

	hidden [void] ResolveDevicePath() {
		if ($this.Path.Contains('\')) {
			throw [System.ArgumentException]::new("Device path `"$($this.Path)`" cannot contain backslashes. Please use forward slashes instead.")
		}

		# Populates PathSegments and MatchedFolders.
		$this.GetMatchingDeviceFolders()

		# Disallow relative host paths which start with the same name as a top-level device folder. This is
		# because of the difficulty of discerning between device and host when it is a single relative folder.
		if ((-not $this.SkipSameFolderCheck) -and
			(Test-Path -Path $this.PathSegments[0] -PathType Container)) {
			throw [System.InvalidOperationException]::new("`"$($this.PathSegments[0])`" is also a top-level device folder. Change to another directory and retry.")
		}

		# A valid path will have the same number of matches returned as there are path string segments.
		if ($this.MatchedFolders.Length -eq $this.PathSegments.Length) {
			if ($this.MatchedFolders[-1] -and $this.MatchedFolders[-1].IsFolder) {
				# The entire path has been found as folders on the device.
				$this.Directory = $this.PathSegments -join '/'
				$this.IsDirectoryMatch = $true
			} else {
				# The last part of the path didn't match a folder, so assume it is a file.
				$this.Directory = (Split-Path $this.Path -Parent).Replace('\', '/')
				$this.FilePattern = Split-Path $this.Path -Leaf
				$this.IsFileMatch = $true
			}
		} else {
			$allButLast = $this.PathSegments[0..($this.PathSegments.Length - 2)]
			$wildcardMatches = $allButLast | Where-Object { $_ -match '[*?]' }
			if ($wildcardMatches) {
				$this.ReportWildcardInDirectoryError()
			}
		}
	}

	hidden [void] ResolveHostPath() {
		$normalisedPath = Get-FullPath($this.Path)

		if (Test-Path $normalisedPath) {
			$this.IsFileMatch = (Test-Path $normalisedPath -PathType Leaf)
			$this.IsDirectoryMatch = (Test-Path $normalisedPath -PathType Container)

			# Disallow both a file and a directory match (this can happen if wildcards are supplied.)
			if ($this.IsFileMatch -and $this.IsDirectoryMatch) {
				throw [System.ArgumentException]::new("Path `"$($this.Path)`" cannot be both a file and a directory.")
			}

			$this.Directory = if ($this.IsFileMatch) { Split-Path $normalisedPath -Parent } else { $normalisedPath }
			$this.FilePattern = if ($this.IsFileMatch) { Split-Path $normalisedPath -Leaf } else { '' }

			# Check for wildcards in the directory part of the source path.
			if ($this.Directory -match '[*?]') {
				$this.ReportWildcardInDirectoryError()
			}
		}
	}

	hidden [void] ReportWildcardInDirectoryError() {
		throw [System.ArgumentException]::new("Wildcard characters are not allowed in the directory portion of the path.")
	}

	hidden [void] ValidateMatchFound() {
		if (-not $this.IsFileMatch -and -not $this.IsDirectoryMatch) {
			throw [System.IO.FileNotFoundException]::new("Path `"$($this.Path)`" not found.")
		}
	}

	hidden [void] ValidateHostPathExists() {
		if ($this.IsOnHost -and (-not (Test-Path -Path $this.Directory))) {
			throw [System.IO.DirectoryNotFoundException]::new("Directory `"$($this.Directory)`" not found.")
		}
	}

	# Process wildcards or specific file in the source path.
	hidden [void] ValidateWildcards() {
		if (($this.FilePattern -match '[*?]')) {
			if ($this.FilenamePatterns -ne "*") {
				throw [System.ArgumentException]::new("Cannot specify wildcards in the path parameter when the FilenamePatterns " +
					"parameter is also provided.")
			}
		} else {
			$fileExists = $false

			# $SourceFilePattern should contain the exact filename we're looking for.
			if ($this.IsOnDevice) {
				$lastFolder = if ($this.MatchedFolders[-1] -and $this.MatchedFolders[-1].IsFolder) {
					$this.MatchedFolders[-1]
				} else {
					$this.MatchedFolders[-2]
				}

				if ($lastFolder.ParseName($this.PathSegments[-1])) {
					$fileExists = $true
				}
			} else {
				$normalisedPath = Get-FullPath($this.Path)
				$fileExists = $(Test-Path -Path $normalisedPath -PathType Leaf)
			}

			if ($fileExists) {
				if ($this.FilenamePatterns -ne "*") {
					# We do not allow wildcard patterns when the source resolves to a single file.
					throw "Cannot provide FilenamePatterns parameter when the path is a file."
				}
			} else {
				# If the source path refers to a single file, it must exist.
				throw "Specified path `"$($this.Path)`" not found."
			}
		}
	}

	hidden [void] Validate() {
		$this.ValidateMatchFound()

		$this.ValidateHostPathExists()	# NB: we do not need to do a check for the device here because it has already been done above.

		# At this point, we know that the folders part of the source path is valid.

		$this.ValidateWildcards()
	}
}