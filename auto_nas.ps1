<#
.SYNOPSIS
Synchronizes Azure Files shares into an existing Veeam NAS/File Share job.

.DESCRIPTION
Discovers shares in an Azure Storage account, ensures each share exists in
Veeam NAS inventory, and adds missing shares to the target job scope.
The sync is add-only: existing job scope entries are never removed.

.NOTES
LEGAL DISCLAIMER - PLEASE READ CAREFULLY

This script was written by someone who is not a professional software developer and was created with the help of artificial intelligence (AI). Because of this, it may contain bugs, errors, or behaviour that may not suit every environment.

It is provided as-is, with no guarantees that it will work correctly, securely, or meet your specific needs. Please review, test, and validate the script in your own environment before using it, especially in production.

You are responsible for how the script is used, including testing, security checks, backups, and change control.

This is not an official Veeam product and is not supported by Veeam. Using this script does not create any support or warranty obligations from Veeam.
#>

# Script inputs can be overridden via parameters; defaults are defined inline for pre-job reliability.
param(
	[string]$StorageAccountName = 'Your Storage Account Name Here',

	[string]$StorageAccountKey = 'Your Storage Account Key Here',

	[string]$VeeamJobName = 'Your Veeam Job Name Here',

	[string]$VeeamServer = 'Your Veeam Server Name Here',

	[string]$VeeamUsername = 'Your Veeam Username Here',

	[string]$VeeamPassword = 'Your Veeam Password Here',

	[string]$VeeamCacheRepositoryName,

	[string]$AzureFilesHostSuffix = 'file.core.windows.net',

	[string]$AzureFilesSmbUsername,

	[switch]$ListOnly,

	[switch]$AllowInsecureVeeamTls = $true,

	[switch]$EnableTranscript = $true,

	[string]$TranscriptPath
)

# Stop at first non-terminating error and enforce strict variable usage.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ScriptVersion = '2026.03.06.13'
$script:WarnedAboutInsecureAzureTls = $false
$script:WarnedAboutInsecureVeeamTls = $false
$script:TranscriptStarted = $false
$script:ResolvedTranscriptPath = ''

# Flattens exception and inner-exception messages for actionable error output.
function Get-ExceptionMessageChain {
	param(
		[Parameter(Mandatory = $true)][System.Exception]$Exception
	)

	$messages = New-Object System.Collections.Generic.List[string]
	$current = $Exception
	while ($null -ne $current) {
		$message = [string]$current.Message
		if (-not [string]::IsNullOrWhiteSpace($message)) {
			$messages.Add($message)
		}

		$current = $current.InnerException
	}

	if ($messages.Count -eq 0) {
		return 'No exception details were provided.'
	}

	return ($messages | Select-Object -Unique) -join ' | Inner: '
}

# Writes a timestamped message to console only.
function Write-Log {
	param(
		[Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
		[Parameter(Mandatory = $true)][string]$Message
	)

	$timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
	$line = "$timestamp [$Level] $Message"

	Write-Host $line
}

# Ensures HOME points to a writable directory for Linux web cmdlet compatibility.
function Ensure-WebCmdletHomeDirectory {
	if (-not $IsLinux) {
		return
	}

	$existingHome = $env:HOME
	if (-not [string]::IsNullOrWhiteSpace($existingHome) -and (Test-Path -LiteralPath $existingHome)) {
		return
	}

	$defaultTranscriptPath = Get-DefaultTranscriptPath
	$baseDir = Split-Path -Path $defaultTranscriptPath -Parent
	if ([string]::IsNullOrWhiteSpace($baseDir)) {
		$baseDir = [System.IO.Path]::GetTempPath()
	}

	$newHome = Join-Path -Path $baseDir -ChildPath 'auto_nas-home'
	try {
		if (-not (Test-Path -LiteralPath $newHome)) {
			New-Item -Path $newHome -ItemType Directory -Force -ErrorAction Stop | Out-Null
		}

		$probePath = Join-Path -Path $newHome -ChildPath ("auto_nas-home-write-test-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
		Set-Content -LiteralPath $probePath -Value 'probe' -ErrorAction Stop
		Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
	}
	catch {
		$homeError = Get-ExceptionMessageChain -Exception $_.Exception
		throw "Unable to initialize writable HOME directory for web cmdlets. Error: $homeError"
	}

	$env:HOME = $newHome
	Write-Log -Level WARN -Message ("HOME was unset or unavailable. Set HOME to '{0}' for web cmdlet compatibility." -f $newHome)
}

# Resolves a writable default transcript path for current platform/runtime.
function Get-DefaultTranscriptPath {
	$candidateDirs = New-Object System.Collections.Generic.List[string]

	if ($IsLinux -and (Test-Path -LiteralPath '/var/lib/veeam/scripts/sandbox')) {
		$null = $candidateDirs.Add('/var/lib/veeam/scripts/sandbox')
	}

	if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
		$null = $candidateDirs.Add($env:TEMP)
	}

	if (-not [string]::IsNullOrWhiteSpace($env:TMPDIR)) {
		$null = $candidateDirs.Add($env:TMPDIR)
	}

	if ($IsLinux) {
		$null = $candidateDirs.Add('/tmp')
	}

	if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
		$null = $candidateDirs.Add($PSScriptRoot)
	}

	$fileName = "auto_nas-transcript-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
	foreach ($candidateDir in ($candidateDirs | Select-Object -Unique)) {
		try {
			if (-not (Test-Path -LiteralPath $candidateDir)) {
				continue
			}

			$probePath = Join-Path -Path $candidateDir -ChildPath ("auto_nas-write-test-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
			Set-Content -LiteralPath $probePath -Value 'probe' -ErrorAction Stop
			Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
			return (Join-Path -Path $candidateDir -ChildPath $fileName)
		}
		catch {
			continue
		}
	}

	return (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $fileName)
}

# Starts transcript capture when enabled. Failure to start is non-fatal.
function Start-ScriptTranscriptIfEnabled {
	param(
		[switch]$Enabled,
		[AllowNull()][AllowEmptyString()][string]$Path
	)

	if (-not $Enabled -or $script:TranscriptStarted) {
		return
	}

	if ($null -eq (Get-Command -Name 'Start-Transcript' -ErrorAction SilentlyContinue)) {
		Write-Log -Level WARN -Message 'Start-Transcript is unavailable in this PowerShell host; continuing without transcript.'
		return
	}

	$targetPath = $Path
	if ([string]::IsNullOrWhiteSpace($targetPath)) {
		$targetPath = Get-DefaultTranscriptPath
	}

	try {
		$targetDir = Split-Path -Path $targetPath -Parent
		if (-not [string]::IsNullOrWhiteSpace($targetDir) -and -not (Test-Path -LiteralPath $targetDir)) {
			New-Item -Path $targetDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
		}

		Start-Transcript -Path $targetPath -Force -ErrorAction Stop | Out-Null
		$script:TranscriptStarted = $true
		$script:ResolvedTranscriptPath = $targetPath
		Write-Log -Level INFO -Message ("Transcript started: {0}" -f $targetPath)
	}
	catch {
		$transcriptError = Get-ExceptionMessageChain -Exception $_.Exception
		Write-Log -Level WARN -Message ("Unable to start transcript. Continuing without transcript. Error: {0}" -f $transcriptError)
	}
}

# Stops transcript capture when active.
function Stop-ScriptTranscriptIfStarted {
	if (-not $script:TranscriptStarted) {
		return
	}

	try {
		Stop-Transcript | Out-Null
		if (-not [string]::IsNullOrWhiteSpace($script:ResolvedTranscriptPath)) {
			Write-Log -Level INFO -Message ("Transcript saved: {0}" -f $script:ResolvedTranscriptPath)
		}
	}
	catch {
		$transcriptStopError = Get-ExceptionMessageChain -Exception $_.Exception
		Write-Log -Level WARN -Message ("Unable to stop transcript cleanly. Error: {0}" -f $transcriptStopError)
	}
	finally {
		$script:TranscriptStarted = $false
	}
}

# Centralized exit to ensure transcript is closed before terminating.
function Exit-Script {
	param(
		[Parameter(Mandatory = $true)][int]$Code
	)

	Stop-ScriptTranscriptIfStarted
	exit $Code
}

# Throws if a required input is empty so failures happen early and clearly.
=======

	$logDir = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
	if (-not (Test-Path -LiteralPath $logDir)) {
		New-Item -Path $logDir -ItemType Directory -Force | Out-Null
	}

	$logPath = Join-Path -Path $logDir -ChildPath ("auto_nas-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
	Add-Content -LiteralPath $logPath -Value $line
}

function Import-DotEnvIfPresent {
	param(
		[Parameter(Mandatory = $true)][string]$DotEnvPath
	)

	if (-not (Test-Path -LiteralPath $DotEnvPath)) {
		return
	}

	Write-Log -Level INFO -Message "Loading .env from: $DotEnvPath"

	foreach ($rawLine in Get-Content -LiteralPath $DotEnvPath -ErrorAction Stop) {
		$line = $rawLine.Trim()
		if ($line.Length -eq 0) { continue }
		if ($line.StartsWith('#')) { continue }

		$idx = $line.IndexOf('=')
		if ($idx -lt 1) { continue }

		$name = $line.Substring(0, $idx).Trim()
		$value = $line.Substring($idx + 1).Trim()

		if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
			$value = $value.Substring(1, $value.Length - 2)
		}

		if ($name.Length -eq 0) { continue }
		[Environment]::SetEnvironmentVariable($name, $value, 'Process')
	}
}

>>>>>>> 6d5e6e0 (Initial Azure Files share discovery script)
function Assert-NonEmpty {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Value
	)

	if ([string]::IsNullOrWhiteSpace($Value)) {
		throw "Missing required value: $Name"
	}
}

<<<<<<< HEAD
# Builds canonicalized resource used by Azure Storage Shared Key auth.
function New-AzureStorageCanonicalizedResource {
	param(
		[Parameter(Mandatory = $true)][string]$AccountName,
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][hashtable]$QueryParameters
	)

	$canonicalizedResource = "/$AccountName$Path"
	$sortedQueryKeys = @($QueryParameters.Keys | ForEach-Object { [string]$_ } | Sort-Object)
	foreach ($queryKey in $sortedQueryKeys) {
		$queryValue = [string]$QueryParameters[$queryKey]
		$canonicalizedResource += "`n{0}:{1}" -f $queryKey.ToLowerInvariant(), $queryValue
	}

	return $canonicalizedResource
}

# Computes the Authorization header value for Azure Storage Shared Key requests.
function Get-AzureStorageSharedKeyAuthorizationValue {
	param(
		[Parameter(Mandatory = $true)][string]$AccountName,
		[Parameter(Mandatory = $true)][string]$AccountKey,
		[Parameter(Mandatory = $true)][string]$Method,
		[Parameter(Mandatory = $true)][hashtable]$CanonicalizedHeaders,
		[Parameter(Mandatory = $true)][string]$CanonicalizedResource,
		[Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$ContentLength = ''
	)

	$canonicalHeadersText = ''
	$sortedHeaderKeys = @($CanonicalizedHeaders.Keys | ForEach-Object { [string]$_ } | Sort-Object)
	foreach ($headerKey in $sortedHeaderKeys) {
		$headerValue = [string]$CanonicalizedHeaders[$headerKey]
		$headerValue = ($headerValue -replace '\s+', ' ').Trim()
		$canonicalHeadersText += "{0}:{1}`n" -f $headerKey.ToLowerInvariant(), $headerValue
	}

	# File service string-to-sign format (Shared Key auth).
	$stringToSign = @(
		$Method.ToUpperInvariant()
		'' # Content-Encoding
		'' # Content-Language
		$ContentLength
		'' # Content-MD5
		'' # Content-Type
		'' # Date
		'' # If-Modified-Since
		'' # If-Match
		'' # If-None-Match
		'' # If-Unmodified-Since
		'' # Range
		$canonicalHeadersText + $CanonicalizedResource
	) -join "`n"

	$keyBytes = [Convert]::FromBase64String($AccountKey.Trim())
	$stringToSignBytes = [System.Text.Encoding]::UTF8.GetBytes($stringToSign)

	$hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
	try {
		$signatureBytes = $hmac.ComputeHash($stringToSignBytes)
	}
	finally {
		$hmac.Dispose()
	}

	$signature = [Convert]::ToBase64String($signatureBytes)
	return "SharedKey ${AccountName}:$signature"
}

# Enumerates Azure Files share names using direct File service REST calls.
function Get-AzureFileShareNamesViaRest {
	param(
		[Parameter(Mandatory = $true)][string]$AccountName,
		[Parameter(Mandatory = $true)][string]$AccountKey,
		[switch]$AllowInsecureTls
	)

	if ($AccountName -notmatch '^[a-z0-9]{3,24}$') {
		throw "Invalid storage account name '$AccountName'. Expected 3-24 lowercase alphanumeric characters."
	}

	$apiVersion = '2023-11-03'
	$baseUri = "https://$AccountName.file.core.windows.net/"
	$marker = ''
	$resultNames = New-Object System.Collections.Generic.List[string]

	do {
		$queryParams = [ordered]@{
			comp = 'list'
			maxresults = '5000'
		}

		if (-not [string]::IsNullOrWhiteSpace($marker)) {
			$queryParams['marker'] = $marker
		}

		$encodedQuery = @(
			foreach ($queryItem in $queryParams.GetEnumerator()) {
				"{0}={1}" -f [System.Uri]::EscapeDataString([string]$queryItem.Key), [System.Uri]::EscapeDataString([string]$queryItem.Value)
			}
		) -join '&'

		$requestUri = "${baseUri}?$encodedQuery"

		$xMsDate = [DateTime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
		$canonicalizedHeaders = [ordered]@{
			'x-ms-date' = $xMsDate
			'x-ms-version' = $apiVersion
		}

		$canonicalizedResource = New-AzureStorageCanonicalizedResource -AccountName $AccountName -Path '/' -QueryParameters $queryParams
		$authorizationValue = Get-AzureStorageSharedKeyAuthorizationValue -AccountName $AccountName -AccountKey $AccountKey -Method 'GET' -CanonicalizedHeaders $canonicalizedHeaders -CanonicalizedResource $canonicalizedResource

		$headers = @{
			'x-ms-date' = $xMsDate
			'x-ms-version' = $apiVersion
			'Authorization' = $authorizationValue
		}

		$invokeParams = @{
			Method = 'Get'
			Uri = $requestUri
			Headers = $headers
			ErrorAction = 'Stop'
		}

		$invokeWebRequestCommand = Get-Command -Name 'Invoke-WebRequest' -ErrorAction Stop
		if ($invokeWebRequestCommand.Parameters.ContainsKey('NoProxy')) {
			$invokeParams['NoProxy'] = $true
		}
		if ($invokeWebRequestCommand.Parameters.ContainsKey('SslProtocol')) {
			$invokeParams['SslProtocol'] = 'Tls12'
		}

		$appliedLegacyInsecureCallback = $false
		$previousValidationCallback = $null
		if ($AllowInsecureTls) {
			if (-not $script:WarnedAboutInsecureAzureTls) {
				Write-Log -Level WARN -Message 'TLS certificate validation for Azure Files REST API is disabled by default. Set -AllowInsecureVeeamTls:$false to enforce strict TLS. Use only in trusted lab environments.'
				$script:WarnedAboutInsecureAzureTls = $true
			}

			if ($invokeWebRequestCommand.Parameters.ContainsKey('SkipCertificateCheck')) {
				$invokeParams['SkipCertificateCheck'] = $true
			}
			else {
				# Windows PowerShell fallback when -SkipCertificateCheck is not available.
				$previousValidationCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
				[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
				$appliedLegacyInsecureCallback = $true
			}
		}

		try {
			$response = Invoke-WebRequest @invokeParams
		}
		finally {
			if ($appliedLegacyInsecureCallback) {
				[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousValidationCallback
			}
		}

		$xmlText = [string]$response.Content
		$xmlText = $xmlText.TrimStart([char]0xFEFF)
		$firstAngleIndex = $xmlText.IndexOf('<')
		if ($firstAngleIndex -gt 0) {
			# Some hosts prepend non-XML bytes/chars before the XML document.
			$xmlText = $xmlText.Substring($firstAngleIndex)
		}

		$xml = [System.Xml.XmlDocument]::new()
		$xml.LoadXml($xmlText)

		$shareNameNodes = $xml.SelectNodes('/EnumerationResults/Shares/Share/Name')
		foreach ($nameNode in $shareNameNodes) {
			$shareName = ([string]$nameNode.InnerText).Trim()
			if (-not [string]::IsNullOrWhiteSpace($shareName)) {
				$resultNames.Add($shareName)
			}
		}

		$nextMarkerNode = $xml.SelectSingleNode('/EnumerationResults/NextMarker')
		if ($null -eq $nextMarkerNode) {
			$marker = ''
		}
		else {
			$marker = ([string]$nextMarkerNode.InnerText).Trim()
		}
	} while (-not [string]::IsNullOrWhiteSpace($marker))

	return @($resultNames | Sort-Object -Unique)
}

# Enumerates Azure Files share names with REST-first behavior.
function Get-AzureFileShareNames {
	param(
		[Parameter(Mandatory = $true)][string]$AccountName,
		[Parameter(Mandatory = $true)][string]$AccountKey,
		[switch]$AllowInsecureTls
	)

	try {
		return @(Get-AzureFileShareNamesViaRest -AccountName $AccountName -AccountKey $AccountKey -AllowInsecureTls:$AllowInsecureTls)
	}
	catch {
		$restFailure = Get-ExceptionMessageChain -Exception $_.Exception

		if (Get-Module -ListAvailable -Name Az.Storage) {
			Write-Log -Level WARN -Message "Azure REST share enumeration failed; trying Az.Storage fallback. Error: $restFailure"

			Import-Module Az.Storage -ErrorAction Stop
			$ctx = New-AzStorageContext -StorageAccountName $AccountName -StorageAccountKey $AccountKey -ErrorAction Stop
			$shares = Get-AzStorageShare -Context $ctx -ErrorAction Stop
			$names = @($shares | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			return $names
		}

		throw "Unable to enumerate Azure Files shares via REST, and Az.Storage is not available. REST error: $restFailure"
	}
}

# Builds an SMB UNC path expected by Veeam (\\account.file.core.windows.net\share).
=======
function Get-AzureFileShareNames {
	param(
		[Parameter(Mandatory = $true)][string]$AccountName,
		[Parameter(Mandatory = $true)][string]$AccountKey
	)

	if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
		throw "Az.Storage module is required. Install it with: Install-Module Az.Storage -Scope AllUsers"
	}

	Import-Module Az.Storage -ErrorAction Stop

	$ctx = New-AzStorageContext -StorageAccountName $AccountName -StorageAccountKey $AccountKey -ErrorAction Stop

	$shares = Get-AzStorageShare -Context $ctx -ErrorAction Stop
	$names = @($shares | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	return $names
}

>>>>>>> 6d5e6e0 (Initial Azure Files share discovery script)
function Get-AzureFilesUncPath {
	param(
		[Parameter(Mandatory = $true)][string]$AccountName,
		[Parameter(Mandatory = $true)][string]$HostSuffix,
		[Parameter(Mandatory = $true)][string]$ShareName
	)

	return "\\$AccountName.$HostSuffix\$ShareName"
}

<<<<<<< HEAD
# Normalizes NAS paths for case-insensitive path comparisons.
function Normalize-NasPath {
	param(
		[Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Path
	)

	if ([string]::IsNullOrWhiteSpace($Path)) {
		return ''
	}

	$p = $Path.Trim()
	$p = $p.Replace('/', '\')
	$p = $p.TrimEnd('\')
	return $p.ToLowerInvariant()
}

# Builds a base URI for Veeam REST API.
function Get-VeeamApiBaseUri {
	param(
		[Parameter(Mandatory = $true)][string]$Server
	)

	if ($Server -match '^https?://') {
		return $Server.TrimEnd('/')
	}

	# Default VBR REST API endpoint port.
	return ("https://{0}:9419" -f $Server).TrimEnd('/')
}

# Encodes query parameters into URL format.
function ConvertTo-QueryString {
	param(
		[Parameter(Mandatory = $false)][AllowNull()][hashtable]$QueryParameters
	)

	if ($null -eq $QueryParameters -or $QueryParameters.Count -eq 0) {
		return ''
	}

	$parts = New-Object System.Collections.Generic.List[string]
	foreach ($key in $QueryParameters.Keys) {
		$value = $QueryParameters[$key]
		if ($null -eq $value) {
			continue
		}

		if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [string])) {
			foreach ($item in $value) {
				if ($null -eq $item) { continue }
				$parts.Add(('{0}={1}' -f [System.Uri]::EscapeDataString([string]$key), [System.Uri]::EscapeDataString([string]$item)))
			}
			continue
		}

		$parts.Add(('{0}={1}' -f [System.Uri]::EscapeDataString([string]$key), [System.Uri]::EscapeDataString([string]$value)))
	}

	return ($parts -join '&')
}

# Performs a Veeam REST API request with API version and bearer token headers.
function Invoke-VeeamApiRequest {
	param(
		[Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
		[Parameter(Mandatory = $true)][pscustomobject]$Session,
		[Parameter(Mandatory = $true)][string]$RelativePath,
		[Parameter(Mandatory = $false)][AllowNull()][hashtable]$QueryParameters,
		[Parameter(Mandatory = $false)][AllowNull()][object]$Body,
		[Parameter(Mandatory = $false)][string]$ContentType = 'application/json',
		[switch]$SkipAuthorization
	)

	$queryString = ConvertTo-QueryString -QueryParameters $QueryParameters
	$uri = '{0}{1}' -f $Session.BaseUri, $RelativePath
	if (-not [string]::IsNullOrWhiteSpace($queryString)) {
		$uri = '{0}?{1}' -f $uri, $queryString
	}

	$headers = @{
		'x-api-version' = $Session.ApiVersion
	}

	if (-not $SkipAuthorization) {
		$headers['Authorization'] = "Bearer $($Session.AccessToken)"
	}

	$invokeParams = @{
		Method = $Method
		Uri = $uri
		Headers = $headers
		ErrorAction = 'Stop'
	}

	$invokeRestMethodCommand = Get-Command -Name 'Invoke-RestMethod' -ErrorAction Stop
	if ($invokeRestMethodCommand.Parameters.ContainsKey('NoProxy')) {
		$invokeParams['NoProxy'] = $true
	}
	if ($invokeRestMethodCommand.Parameters.ContainsKey('SslProtocol')) {
		$invokeParams['SslProtocol'] = 'Tls12'
	}

	if ($PSBoundParameters.ContainsKey('Body')) {
		if ($ContentType -eq 'application/json') {
			$invokeParams['Body'] = ($Body | ConvertTo-Json -Depth 100 -Compress)
		}
		else {
			$invokeParams['Body'] = $Body
		}

		$invokeParams['ContentType'] = $ContentType
	}

	$appliedLegacyInsecureCallback = $false
	$previousValidationCallback = $null
	if ($Session.AllowInsecureTls) {
		if (-not $script:WarnedAboutInsecureVeeamTls) {
			Write-Log -Level WARN -Message 'TLS certificate validation for Veeam REST API is disabled by default. Set -AllowInsecureVeeamTls:$false to enforce strict TLS. Use only in trusted lab environments.'
			$script:WarnedAboutInsecureVeeamTls = $true
		}

		if ($invokeRestMethodCommand.Parameters.ContainsKey('SkipCertificateCheck')) {
			$invokeParams['SkipCertificateCheck'] = $true
		}
		else {
			# Windows PowerShell fallback when -SkipCertificateCheck is not available.
			$previousValidationCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
			[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
			$appliedLegacyInsecureCallback = $true
		}
	}

	try {
		return Invoke-RestMethod @invokeParams
	}
	catch {
		$errorMessage = Get-ExceptionMessageChain -Exception $_.Exception
		if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
			$errorMessage = '{0} | {1}' -f $errorMessage, $_.ErrorDetails.Message
		}

		if (-not $Session.AllowInsecureTls -and $errorMessage -match 'SSL connection|certificate') {
			$errorMessage = '{0} | Check Veeam certificate trust and hostname match, or use -AllowInsecureVeeamTls for lab-only testing.' -f $errorMessage
		}

		throw "Veeam REST API call failed ($Method $RelativePath): $errorMessage"
	}
	finally {
		if ($appliedLegacyInsecureCallback) {
			[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousValidationCallback
		}
	}
}

# Creates an authenticated REST session against Veeam.
function New-VeeamApiSession {
	param(
		[Parameter(Mandatory = $true)][string]$Server,
		[Parameter(Mandatory = $true)][string]$Username,
		[Parameter(Mandatory = $true)][string]$Password,
		[switch]$AllowInsecureTls
	)

	$baseUri = Get-VeeamApiBaseUri -Server $Server
	$session = [pscustomobject]@{
		BaseUri = $baseUri
		ApiVersion = '1.3-rev1'
		AccessToken = ''
		RefreshToken = ''
		AllowInsecureTls = [bool]$AllowInsecureTls
	}

	$tokenResponse = Invoke-VeeamApiRequest `
		-Method POST `
		-Session $session `
		-RelativePath '/api/oauth2/token' `
		-Body @{ grant_type = 'password'; username = $Username; password = $Password } `
		-ContentType 'application/x-www-form-urlencoded' `
		-SkipAuthorization

	if ($null -eq $tokenResponse -or [string]::IsNullOrWhiteSpace([string]$tokenResponse.access_token)) {
		throw 'Veeam token request succeeded but no access token was returned.'
	}

	$session.AccessToken = [string]$tokenResponse.access_token
	$session.RefreshToken = [string]$tokenResponse.refresh_token
	return $session
}

# Best-effort REST logout.
function Close-VeeamApiSession {
	param(
		[Parameter(Mandatory = $false)][AllowNull()][pscustomobject]$Session
	)

	if ($null -eq $Session) {
		return
	}

	if ([string]::IsNullOrWhiteSpace([string]$Session.AccessToken)) {
		return
	}

	try {
		Invoke-VeeamApiRequest -Method POST -Session $Session -RelativePath '/api/oauth2/logout' | Out-Null
	}
	catch {
		# Swallow logout failures so they do not hide the main operation status.
	}
}

# Gets all paged records from a Veeam endpoint that returns { data[], pagination }.
function Get-VeeamApiPagedData {
	param(
		[Parameter(Mandatory = $true)][pscustomobject]$Session,
		[Parameter(Mandatory = $true)][string]$RelativePath,
		[Parameter(Mandatory = $false)][AllowNull()][hashtable]$QueryParameters
	)

	$limit = 200
	$skip = 0
	$all = New-Object System.Collections.Generic.List[object]

	while ($true) {
		$query = @{}
		if ($null -ne $QueryParameters) {
			foreach ($key in $QueryParameters.Keys) {
				$query[$key] = $QueryParameters[$key]
			}
		}

		$query['skip'] = $skip
		$query['limit'] = $limit

		$page = Invoke-VeeamApiRequest -Method GET -Session $Session -RelativePath $RelativePath -QueryParameters $query
		if ($null -eq $page -or $null -eq $page.PSObject.Properties['data']) {
			throw "Unexpected paged response from '$RelativePath'."
		}

		$pageData = @($page.data)
		foreach ($item in $pageData) {
			$null = $all.Add([object]$item)
		}

		if ($pageData.Count -lt $limit) {
			break
		}

		$skip += $pageData.Count
	}

	return $all.ToArray()
}

# Waits for an async Veeam session to complete and fails on a failed result.
function Wait-VeeamApiSessionCompletion {
	param(
		[Parameter(Mandatory = $true)][pscustomobject]$Session,
		[Parameter(Mandatory = $true)][string]$SessionId,
		[int]$TimeoutSeconds = 300
	)

	$activeStates = @(
		'Starting'
		'Stopping'
		'Working'
		'Pausing'
		'Resuming'
		'WaitingTape'
		'Postprocessing'
		'WaitingRepository'
		'WaitingSlot'
	)

	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	while ($true) {
		$current = Invoke-VeeamApiRequest -Method GET -Session $Session -RelativePath ("/api/v1/sessions/{0}" -f $SessionId)

		$state = [string]$current.state
		$result = ''
		$message = ''
		if ($null -ne $current.result) {
			$result = [string]$current.result.result
			$message = [string]$current.result.message
		}

		if ($result -eq 'Failed') {
			if ([string]::IsNullOrWhiteSpace($message)) {
				$message = 'No additional details were returned by Veeam.'
			}
			throw "Veeam session '$SessionId' failed. $message"
		}

		if (-not ($activeStates -contains $state)) {
			return $current
		}

		if ((Get-Date) -gt $deadline) {
			throw "Timed out waiting for Veeam session '$SessionId' to complete. Last state: $state"
		}

		Start-Sleep -Seconds 2
	}
}

# Resolves a single backup repository used for NAS cache metadata.
function Get-VeeamBackupRepositoryByNameSingle {
	param(
		[Parameter(Mandatory = $true)][pscustomobject]$Session,
		[Parameter(Mandatory = $true)][string]$Name
	)

	$repos = @(Get-VeeamApiPagedData -Session $Session -RelativePath '/api/v1/backupInfrastructure/repositories' -QueryParameters @{ nameFilter = ("*{0}*" -f $Name) })
	$matching = @($repos | Where-Object { ([string]$_.name) -eq $Name })

	if ($matching.Count -eq 0) {
		throw "Veeam backup repository not found: '$Name' (used for NAS cache metadata)."
	}

	if ($matching.Count -gt 1) {
		throw "Multiple Veeam backup repositories matched name '$Name'. Please make the repository name unique."
	}

	return $matching[0]
}

# Resolves a single FileBackup job and loads the full job model.
function Get-VeeamFileBackupJobByNameSingle {
	param(
		[Parameter(Mandatory = $true)][pscustomobject]$Session,
		[Parameter(Mandatory = $true)][string]$Name
	)

	$jobs = @(Get-VeeamApiPagedData -Session $Session -RelativePath '/api/v1/jobs' -QueryParameters @{ typeFilter = 'FileBackup'; nameFilter = ("*{0}*" -f $Name) })
	$matching = @($jobs | Where-Object { ([string]$_.name) -eq $Name -and ([string]$_.type) -eq 'FileBackup' })

	if ($matching.Count -eq 0) {
		throw "Veeam FileBackup job not found: '$Name'. Create it first, or provide the correct existing job name."
	}

	if ($matching.Count -gt 1) {
		throw "Multiple Veeam FileBackup jobs matched name '$Name'. Please make the job name unique."
	}

	$jobId = [string]$matching[0].id
	$job = Invoke-VeeamApiRequest -Method GET -Session $Session -RelativePath ("/api/v1/jobs/{0}" -f $jobId)
	if ([string]$job.type -ne 'FileBackup') {
		throw "Job '$Name' was found, but it is type '$($job.type)' instead of 'FileBackup'."
	}

	return $job
}

# Finds an existing script-managed standard credentials record or creates one.
function Ensure-VeeamStandardCredentials {
	param(
		[Parameter(Mandatory = $true)][pscustomobject]$Session,
		[Parameter(Mandatory = $true)][string]$Username,
		[Parameter(Mandatory = $true)][string]$Password,
		[Parameter(Mandatory = $true)][string]$Description
	)

	$creds = @(Get-VeeamApiPagedData -Session $Session -RelativePath '/api/v1/credentials' -QueryParameters @{ nameFilter = ("*{0}*" -f $Username) })
	$matching = @(
		$creds | Where-Object {
			([string]$_.type) -eq 'Standard' -and
			([string]$_.username) -eq $Username -and
			([string]$_.description) -eq $Description
		}
	)

	if ($matching.Count -gt 1) {
		$matching = @($matching | Sort-Object -Property creationTime -Descending)
		Write-Log -Level WARN -Message "Multiple script-managed credentials matched '$Username'; using newest record."
	}

	if ($matching.Count -gt 0) {
		$credId = [string]$matching[0].id
		Invoke-VeeamApiRequest -Method POST -Session $Session -RelativePath ("/api/v1/credentials/{0}/changepassword" -f $credId) -Body @{ password = $Password } | Out-Null
		return $credId
	}

	$created = Invoke-VeeamApiRequest -Method POST -Session $Session -RelativePath '/api/v1/credentials' -Body @{
		username = $Username
		description = $Description
		type = 'Standard'
		password = $Password
	}

	if ($null -eq $created -or [string]::IsNullOrWhiteSpace([string]$created.id)) {
		throw 'Credentials record creation did not return an ID.'
	}

	return [string]$created.id
}

# Gets SMB-share inventory objects keyed by normalized path.
function Get-VeeamSmbShareServersByPath {
	param(
		[Parameter(Mandatory = $true)][pscustomobject]$Session
	)

	$allServers = @(Get-VeeamApiPagedData -Session $Session -RelativePath '/api/v1/inventory/unstructuredDataServers')
	$map = @{}

	foreach ($server in $allServers) {
		if ([string]$server.type -ne 'SMBShare') {
			continue
		}

		if ($null -eq $server.PSObject.Properties['path']) {
			continue
		}

		$normalized = Normalize-NasPath -Path ([string]$server.path)
		if ([string]::IsNullOrWhiteSpace($normalized)) {
			continue
		}

		if ($map.ContainsKey($normalized)) {
			throw "Multiple Veeam SMB share inventory items matched path '$($server.path)'."
		}

		$map[$normalized] = $server
	}

	return $map
}

# Adds an SMB share inventory object and waits for completion.
function Add-VeeamSmbShareServer {
	param(
		[Parameter(Mandatory = $true)][pscustomobject]$Session,
		[Parameter(Mandatory = $true)][string]$UncPath,
		[Parameter(Mandatory = $true)][string]$CredentialsId,
		[Parameter(Mandatory = $true)][string]$CacheRepositoryId
	)

	$sessionModel = Invoke-VeeamApiRequest -Method POST -Session $Session -RelativePath '/api/v1/inventory/unstructuredDataServers' -Body @{
		type = 'SMBShare'
		path = $UncPath
		accessCredentialsRequired = $true
		accessCredentialsId = $CredentialsId
		processing = @{
			backupProxies = @{
				autoSelectEnabled = $true
			}
			cacheRepositoryId = $CacheRepositoryId
		}
	}

	if ($null -eq $sessionModel -or [string]::IsNullOrWhiteSpace([string]$sessionModel.id)) {
		throw "Adding SMB share '$UncPath' did not return a session ID."
	}

	Wait-VeeamApiSessionCompletion -Session $Session -SessionId ([string]$sessionModel.id) | Out-Null
}

try {
	Start-ScriptTranscriptIfEnabled -Enabled:$EnableTranscript -Path $TranscriptPath
	Ensure-WebCmdletHomeDirectory
	Write-Log -Level INFO -Message ("Script version: {0}" -f $script:ScriptVersion)

	# Step 1: resolve runtime configuration from inline defaults and optional parameter overrides.
=======
try {
	Import-DotEnvIfPresent -DotEnvPath (Join-Path -Path $PSScriptRoot -ChildPath '.env')

	if ([string]::IsNullOrWhiteSpace($StorageAccountName)) { $StorageAccountName = $env:AZURE_STORAGE_ACCOUNT }
	if ([string]::IsNullOrWhiteSpace($StorageAccountKey)) { $StorageAccountKey = $env:AZURE_STORAGE_KEY }
	if ([string]::IsNullOrWhiteSpace($VeeamJobName)) { $VeeamJobName = $env:VEEAM_NAS_JOB_NAME }
	if ([string]::IsNullOrWhiteSpace($VeeamServer)) { $VeeamServer = $env:VEEAM_SERVER }
	if ([string]::IsNullOrWhiteSpace($AzureFilesSmbUsername)) { $AzureFilesSmbUsername = $env:AZURE_FILES_SMB_USERNAME }
	if ([string]::IsNullOrWhiteSpace($AzureFilesHostSuffix) -and -not [string]::IsNullOrWhiteSpace($env:AZURE_FILES_HOST_SUFFIX)) {
		$AzureFilesHostSuffix = $env:AZURE_FILES_HOST_SUFFIX
	}

>>>>>>> 6d5e6e0 (Initial Azure Files share discovery script)
	Assert-NonEmpty -Name 'AZURE_STORAGE_ACCOUNT (StorageAccountName)' -Value $StorageAccountName
	Assert-NonEmpty -Name 'AZURE_STORAGE_KEY (StorageAccountKey)' -Value $StorageAccountKey

	if ([string]::IsNullOrWhiteSpace($AzureFilesSmbUsername)) {
<<<<<<< HEAD
		$AzureFilesSmbUsername = "Azure\$StorageAccountName"
	}

	# Step 2: discover Azure Files shares and project them to UNC paths.
	Write-Log -Level INFO -Message "Enumerating Azure Files shares in storage account: $StorageAccountName"
	try {
		$shareNames = @(Get-AzureFileShareNames -AccountName $StorageAccountName -AccountKey $StorageAccountKey -AllowInsecureTls:$AllowInsecureVeeamTls)
	}
	catch {
		$azureDiscoveryFailure = Get-ExceptionMessageChain -Exception $_.Exception
		throw "Azure share discovery failed. Fail-fast mode is enforced to avoid stale inventory sync. Error: $azureDiscoveryFailure"
	}

	if ($shareNames.Count -eq 0) {
		Write-Log -Level WARN -Message 'No Azure Files shares found.'
		Exit-Script -Code 0
=======
		$AzureFilesSmbUsername = "Azure\\$StorageAccountName"
	}

	Write-Log -Level INFO -Message "Enumerating Azure Files shares in storage account: $StorageAccountName"
	$shareNames = Get-AzureFileShareNames -AccountName $StorageAccountName -AccountKey $StorageAccountKey

	if ($shareNames.Count -eq 0) {
		Write-Log -Level WARN -Message 'No Azure Files shares found.'
		exit 0
>>>>>>> 6d5e6e0 (Initial Azure Files share discovery script)
	}

	$uncPaths = @(
		foreach ($shareName in $shareNames) {
			Get-AzureFilesUncPath -AccountName $StorageAccountName -HostSuffix $AzureFilesHostSuffix -ShareName $shareName
		}
	)

	Write-Log -Level INFO -Message ("Found {0} share(s)." -f $uncPaths.Count)
	foreach ($unc in $uncPaths) {
		Write-Log -Level INFO -Message "Share: $unc"
	}

<<<<<<< HEAD
	# List-only mode is useful for validation without touching Veeam.
	if ($ListOnly) {
		Exit-Script -Code 0
	}

	Assert-NonEmpty -Name 'VEEAM_NAS_JOB_NAME (VeeamJobName)' -Value $VeeamJobName
	Assert-NonEmpty -Name 'VEEAM_USERNAME (VeeamUsername)' -Value $VeeamUsername
	Assert-NonEmpty -Name 'VEEAM_PASSWORD (VeeamPassword)' -Value $VeeamPassword
=======
	if ($ListOnly) {
		exit 0
	}

	Assert-NonEmpty -Name 'VEEAM_NAS_JOB_NAME (VeeamJobName)' -Value $VeeamJobName
>>>>>>> 6d5e6e0 (Initial Azure Files share discovery script)
	if ([string]::IsNullOrWhiteSpace($VeeamServer)) {
		$VeeamServer = 'localhost'
	}

<<<<<<< HEAD
	if ([string]::IsNullOrWhiteSpace($VeeamCacheRepositoryName)) {
		# Common default in many Veeam installs.
		$VeeamCacheRepositoryName = 'Default Backup Repository'
	}

	$veeamSession = $null
	try {
		Write-Log -Level INFO -Message "Connecting to Veeam REST API: $VeeamServer"
		$veeamSession = New-VeeamApiSession -Server $VeeamServer -Username $VeeamUsername -Password $VeeamPassword -AllowInsecureTls:$AllowInsecureVeeamTls

		# Step 3: perform add-only sync into Veeam inventory and job scope via REST.
		Write-Log -Level INFO -Message "Resolving Veeam NAS cache repository: $VeeamCacheRepositoryName"
		$cacheRepo = Get-VeeamBackupRepositoryByNameSingle -Session $veeamSession -Name $VeeamCacheRepositoryName

		$credentialsDescription = "Managed by auto_nas.ps1 for Azure Files account $StorageAccountName"
		Write-Log -Level INFO -Message "Ensuring Veeam credentials record for SMB user: $AzureFilesSmbUsername"
		$accessCredentialId = Ensure-VeeamStandardCredentials -Session $veeamSession -Username $AzureFilesSmbUsername -Password $StorageAccountKey -Description $credentialsDescription

		$addedToInventory = @()
		$addedToJob = @()
		$skippedAlreadyInJob = @()

		$smbServersByPath = Get-VeeamSmbShareServersByPath -Session $veeamSession

		$resolvedServerIdsByPath = @{}

		foreach ($unc in $uncPaths) {
			$normalizedUnc = Normalize-NasPath -Path $unc
			if ($smbServersByPath.ContainsKey($normalizedUnc)) {
				$resolvedServerIdsByPath[$normalizedUnc] = [string]$smbServersByPath[$normalizedUnc].id
				continue
			}

			Write-Log -Level INFO -Message "Adding share to Veeam inventory: $unc"
			Add-VeeamSmbShareServer -Session $veeamSession -UncPath $unc -CredentialsId $accessCredentialId -CacheRepositoryId ([string]$cacheRepo.id)
			$addedToInventory += $unc

			# Refresh index after async add operation.
			$smbServersByPath = Get-VeeamSmbShareServersByPath -Session $veeamSession
			if (-not $smbServersByPath.ContainsKey($normalizedUnc)) {
				throw "Share was added but could not be found in Veeam inventory afterwards: $unc"
			}

			$resolvedServerIdsByPath[$normalizedUnc] = [string]$smbServersByPath[$normalizedUnc].id
		}

		Write-Log -Level INFO -Message "Locating existing Veeam FileBackup job: $VeeamJobName"
		$job = Get-VeeamFileBackupJobByNameSingle -Session $veeamSession -Name $VeeamJobName

		$jobObjects = @()
		if ($null -ne $job.PSObject.Properties['objects']) {
			$jobObjects = @($job.objects)
		}

		$existingServerIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($obj in $jobObjects) {
			if ($null -eq $obj) { continue }
			if ($null -eq $obj.PSObject.Properties['fileServerId']) { continue }

			$fileServerId = [string]$obj.fileServerId
			if ([string]::IsNullOrWhiteSpace($fileServerId)) { continue }
			$null = $existingServerIds.Add($fileServerId)
		}

		foreach ($unc in $uncPaths) {
			$normalizedUnc = Normalize-NasPath -Path $unc
			if (-not $resolvedServerIdsByPath.ContainsKey($normalizedUnc)) {
				if ($smbServersByPath.ContainsKey($normalizedUnc)) {
					$resolvedServerIdsByPath[$normalizedUnc] = [string]$smbServersByPath[$normalizedUnc].id
				}
				else {
					throw "Unable to resolve Veeam inventory ID for share: $unc"
				}
			}

			$serverId = [string]$resolvedServerIdsByPath[$normalizedUnc]
			if ($existingServerIds.Contains($serverId)) {
				$skippedAlreadyInJob += $unc
				continue
			}

			Write-Log -Level INFO -Message "Adding share to job scope: $unc"
			$jobObjects += [pscustomobject]@{
				fileServerId = $serverId
				path = $unc
			}
			$null = $existingServerIds.Add($serverId)
			$addedToJob += $unc
		}

		if ($addedToJob.Count -gt 0) {
			# Commit all new file-share objects in one update.
			Write-Log -Level INFO -Message ("Updating job '{0}' with {1} new share(s)." -f $VeeamJobName, $addedToJob.Count)
			$job.objects = $jobObjects
			Invoke-VeeamApiRequest -Method PUT -Session $veeamSession -RelativePath ("/api/v1/jobs/{0}" -f ([string]$job.id)) -Body $job | Out-Null
		}
		else {
			Write-Log -Level INFO -Message "No job scope changes needed for '$VeeamJobName'."
		}

		Write-Log -Level INFO -Message ("Inventory additions: {0}; Job additions: {1}; Skipped (already in job): {2}." -f $addedToInventory.Count, $addedToJob.Count, $skippedAlreadyInJob.Count)
	}
	finally {
		Close-VeeamApiSession -Session $veeamSession
	}

	Stop-ScriptTranscriptIfStarted
}
catch {
	$lineSuffix = ''
	if ($null -ne $_.InvocationInfo -and $null -ne $_.InvocationInfo.ScriptLineNumber) {
		$lineSuffix = " (line $($_.InvocationInfo.ScriptLineNumber))"
	}

	Write-Log -Level ERROR -Message ("{0}{1}" -f $_.Exception.Message, $lineSuffix)
	if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
		$stackSingleLine = ($_.ScriptStackTrace -replace "`r?`n", ' | ')
		Write-Log -Level ERROR -Message ("Stack: {0}" -f $stackSingleLine)
	}

	Exit-Script -Code 1
=======
	throw "Veeam integration not yet wired in. Next step: confirm available Veeam PowerShell cmdlets and job type on the target Windows host."
}
catch {
	Write-Log -Level ERROR -Message $_.Exception.Message
	exit 1
>>>>>>> 6d5e6e0 (Initial Azure Files share discovery script)
}
