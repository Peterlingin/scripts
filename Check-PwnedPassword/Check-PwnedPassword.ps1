function Test-PwnedPassword {
    <#
    .SYNOPSIS
        Checks if a password has been compromised in data breaches using the Have I Been Pwned API.
    
    .DESCRIPTION
        This function securely checks if a password appears in known data breaches by querying
        the Have I Been Pwned API using k-anonymity (only sends first 5 chars of hash).
    
    .PARAMETER Password
        The password to check. If not provided, you'll be prompted securely.
    
    .PARAMETER Quiet
        Returns only a boolean result without detailed output.
    
    .PARAMETER AsObject
        Returns a custom object with detailed information instead of formatted output.
    
    .EXAMPLE
        Test-PwnedPassword
        Prompts for password and displays detailed results.
    
    .EXAMPLE
        Test-PwnedPassword -Password "mypassword123" -Quiet
        Returns $true if compromised, $false if safe.
    
    .EXAMPLE
        Test-PwnedPassword -AsObject
        Returns an object with IsCompromised, BreachCount, and Hash properties.
    
    .NOTES
        Uses SHA-1 hashing locally and the HIBP Pwned Passwords API v3.
        Your password never leaves your machine in plain text.
    #>
    
    [CmdletBinding()]
    [OutputType([PSCustomObject], [System.Boolean])]
    param(
        [Parameter(ValueFromPipeline = $true, Position = 0)]
        [string]$Password,
        
        [Parameter()]
        [switch]$Quiet,
        
        [Parameter()]
        [switch]$AsObject
    )
    
    begin {
        $apiBase = "https://api.pwnedpasswords.com/range"
        $userAgent = "PowerShell-Password-Checker/2.0"
    }
    
    process {
        try {
            if ([string]::IsNullOrEmpty($Password)) {
                if ($Quiet -or $AsObject) {
                    throw "Password parameter is required when using -Quiet or -AsObject switches."
                }
                
                $securePassword = Read-Host "Enter the password to check" -AsSecureString
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
                $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
            }
            
            if ([string]::IsNullOrWhiteSpace($Password)) {
                throw "Password cannot be empty or whitespace."
            }
            
            Write-Verbose "Computing SHA-1 hash..."
            $sha1 = [System.Security.Cryptography.SHA1]::Create()
            $hashBytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Password))
            $fullHash = ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ""
            
            $prefix = $fullHash.Substring(0, 5)
            $suffix = $fullHash.Substring(5)
            
            Write-Verbose "Hash prefix: $prefix"
            Write-Debug "Full hash: $fullHash"
            
            $apiUrl = "$apiBase/$prefix"
            Write-Verbose "Querying HIBP API: $apiUrl"
            
            $headers = @{
                "User-Agent" = $userAgent
            }
            
            $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -ErrorAction Stop
            
            $lines = $response -split "`r?`n" | Where-Object { $_ -match '\S' }
            Write-Verbose "Received $($lines.Count) hash suffixes from API"
            
            $found = $false
            $breachCount = 0
            
            foreach ($line in $lines) {
                $line = $line.Trim()
                if ($line.StartsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $parts = $line -split ':', 2
                    if ($parts[0] -eq $suffix) {
                        $found = $true
                        $breachCount = [int]$parts[1]
                        Write-Debug "Match found: $suffix with count $breachCount"
                        break
                    }
                }
            }
            
            if ($Quiet) {
                return $found
            }
            elseif ($AsObject) {
                return [PSCustomObject]@{
                    IsCompromised = $found
                    BreachCount = $breachCount
                    HashSHA1 = $fullHash
                    DateChecked = Get-Date
                }
            }
            else {
                if ($found) {
                    Write-Host "`n==================== MATCH FOUND ====================" -ForegroundColor Red
                    Write-Host "Full Hash: $fullHash" -ForegroundColor Red
                    Write-Host "Times seen in breaches: $breachCount" -ForegroundColor Red
                    Write-Host "=====================================================" -ForegroundColor Red
                    Write-Host "`nWARNING: This password has been found in data breaches!" -ForegroundColor Red
                    Write-Host "It is strongly recommended to change this password immediately.`n" -ForegroundColor Yellow
                } else {
                    Write-Host "`n==================== RESULT ====================" -ForegroundColor Green
                    Write-Host "Good news! This password was NOT found in known data breaches." -ForegroundColor Green
                    Write-Host "===============================================`n" -ForegroundColor Green
                }
            }
            
        }
        catch {
            Write-Error "Error checking password: $_"
            if ($Quiet) { return $null }
            if ($AsObject) { return $null }
        }
        finally {
            if ($Password) {
                Clear-Variable -Name Password -ErrorAction SilentlyContinue
            }
            if ($fullHash) {
                Clear-Variable -Name fullHash -ErrorAction SilentlyContinue
            }
            if ($suffix) {
                Clear-Variable -Name suffix -ErrorAction SilentlyContinue
            }
            if ($BSTR) {
                Clear-Variable -Name BSTR -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Test-PwnedPassword
}
