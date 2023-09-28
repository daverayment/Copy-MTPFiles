<#
.SYNOPSIS
    Transfers files to or from a portable device via MTP (Media Transfer Protocol).
.DESCRIPTION
    The Media Transfer Protocol (MTP) facilitates file transfers between computers and portable devices like smartphones, cameras, and media players.

	This script integrates MTP transfers into your PowerShell workflow. It supports features such as file listing (on host and device), device enumeration and pattern matching to enhance and simplify the process.

	For further details, source code, or to report issues, visit the GitHub repository: https://github.com/daverayment/Copy-MTPFiles
.NOTES
	Detecting attached MTP-compatible devices isn't foolproof, so false positives may occur in exceptional circumstances.
.PARAMETER Source
	The path to the source directory or file(s). If not provided, it defaults to the current path. Supports wildcards for file matching.
	Alias: s
.PARAMETER DestinationDirectory
	The path to the destination directory. Defaults to the current path if not provided.
	Aliases: DestinationFolder, Destination, Dest, d
.PARAMETER FilenamePatterns
	An array of filename patterns to match. By default, it matches all files. For multiple patterns, separate them with commas (e.g., "*.jpg,*.png").
	Aliases: Patterns, p
.PARAMETER Move
	When this switch is present, files are moved instead of copied.
.PARAMETER ListDevices
	Lists attached MTP-compatible devices. Useful to retrieve device names for the -DeviceName parameter. When present, other parameters are ignored.
	Aliases: GetDevices, ld
.PARAMETER DeviceName
	Specifies the name of the attached device to use. Required if multiple compatible devices are attached. Use -ListDevices to retrieve the names of all attached devices.
	Aliases: Device, dn
.PARAMETER ListFiles
	Lists files in the specified directory. For host directories, a standard PowerShell file listing is returned. For directories on a device, this returns objects with Name, Length, LastWriteTime, and Type properties. This can be combined with -FilenamePatterns for filtered results.
	Aliases: GetFiles, lf, ls
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 -Move -Source "Internal storage/Download" -Destination "C:\Projects\Documents" -Patterns "*.doc", "*.pdf"

    Moves .doc and .pdf files from an Android device's Download directory to the specified host directory.
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 "Internal storage/Download" -FilenamePatterns "*.jpg"

    Copies .jpg files from an Android device's Download directory to the current folder on the host.
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 -Move -Source "." -Destination "Internal storage/Download"

    Moves all files from the current host directory to the Download directory on an Android device.
.EXAMPLE
    PS C:\> .\Copy-MTPFiles.ps1 -ld

    Lists all MTP-compatible devices currently attached.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
	[Alias("s")]
	[ValidateNotNullOrEmpty()]
	[Parameter(Position = 0)]
	[string]$Source = $PWD.Path,

	[Alias("DestinationFolder", "Destination", "d")]
	[ValidateNotNullOrEmpty()]
	[Parameter(Position = 1)]
	[string]$DestinationDirectory = $PWD.Path,

	[switch]$Move,

	[Alias("GetDevices", "ld")]
	[switch]$ListDevices,

	[Alias("Device", "dn")]
	[string]$DeviceName,

	[Alias("GetFiles", "lf", "ls")]
	[string]$ListFiles,

	[Alias("Patterns", "p")]
	[string[]]$FilenamePatterns = "*",

	[switch]$WarningOnNoMatches
)

. "$PSScriptRoot\Copy-MTPFilesLogic.ps1"

$PSBoundParameters["CallingScriptPath"] = $PSCommandPath
Main @PSBoundParameters