# Check-PwnedPassword

A secure PowerShell function that checks if passwords have been compromised in known data breaches using the [Have I Been Pwned](https://haveibeenpwned.com/) Pwned Passwords API.

## Features

- 🔒 **Maximum Privacy**: Uses k-anonymity model - only the first 5 characters of the password hash are sent to the API
- 🛡️ **Secure Input**: Prompts for passwords using `SecureString` to prevent exposure in console history
- 🧹 **Memory Safety**: Automatically cleans sensitive data from memory after use
- 📊 **Flexible Output**: Multiple output modes for different use cases (interactive, quiet, object)
- 🔄 **Pipeline Support**: Can process passwords from pipeline for batch operations
- 📝 **Comprehensive Logging**: Verbose and debug output available for troubleshooting
- ⚡ **Modern PowerShell**: Follows best practices with proper parameter validation and error handling

## How It Works

1. Accepts password input (securely prompted or via parameter)
2. Computes SHA-1 hash of the password **locally on your machine**
3. Sends only the first 5 characters (prefix) of the hash to the HIBP API
4. Receives a list of hash suffixes that match the prefix
5. Searches locally for your full hash in the results
6. Reports whether the password has been compromised and how many times

**Your actual password never leaves your machine in plain text.**

## Installation

Simply download the script or copy the function into your PowerShell profile.

```powershell
# Download the script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Peterlingin/scripts/refs/heads/main/Check-PwnedPassword/Check-PwnedPassword.ps1" -OutFile "Check-PwnedPassword.ps1"

# Run it
.\Check-PwnedPassword.ps1
```

## Usage

### Interactive Mode (Secure Prompt)
```powershell
.\Check-PwnedPassword.ps1
# You'll be prompted to enter password securely (no echo)
```

### Direct Password Check
```powershell
# Dot-source to load the function
. .\Check-PwnedPassword.ps1

# Check a specific password
Test-PwnedPassword -Password "mypassword123"
```

### Quiet Mode (Boolean Result)
```powershell
# Returns $true if compromised, $false if safe
$isCompromised = Test-PwnedPassword -Password "test123" -Quiet

if ($isCompromised) {
    Write-Host "Password is compromised!"
}
```

### Object Output (Structured Data)
```powershell
# Returns an object with detailed information
$result = Test-PwnedPassword -Password "test123" -AsObject

if ($result.IsCompromised) {
    Write-Host "Found in $($result.BreachCount) breaches"
    Write-Host "Hash: $($result.HashSHA1)"
    Write-Host "Checked: $($result.DateChecked)"
}
```

### Verbose/Debug Output
```powershell
# See detailed processing information
Test-PwnedPassword -Password "test123" -Verbose

# See debug information including full hash
Test-PwnedPassword -Password "test123" -Debug
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Password` | String | The password to check. If omitted, you'll be prompted securely |
| `-Quiet` | Switch | Returns only a boolean ($true if compromised, $false if safe) |
| `-AsObject` | Switch | Returns a PSCustomObject with IsCompromised, BreachCount, HashSHA1, and DateChecked |
| `-Verbose` | Switch | Shows detailed processing information |
| `-Debug` | Switch | Shows debug information including hash values |

## Output Examples

### Compromised Password
```
==================== MATCH FOUND ====================
Full Hash: 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8
Times seen in breaches: 3861493
=====================================================

WARNING: This password has been found in data breaches!
It is strongly recommended to change this password immediately.
```

### Safe Password
```
==================== RESULT ====================
Good news! This password was NOT found in known data breaches.
===============================================
```

## Requirements

- PowerShell 5.1 or later
- Internet connection to access the HIBP API
- Windows, Linux, or macOS (PowerShell Core supported)

## Security & Privacy

This script implements the [Pwned Passwords API v3](https://haveibeenpwned.com/API/v3#PwnedPasswords) using k-anonymity:

- ✅ Password is hashed locally using SHA-1
- ✅ Only the first 5 characters of the hash are sent to the API
- ✅ Full hash comparison happens locally on your machine
- ✅ Secure password input using `SecureString`
- ✅ Sensitive variables are cleared from memory after use
- ✅ No password is ever transmitted in plain text

The k-anonymity model ensures that even the API provider cannot determine which specific password you're checking.

## API Rate Limiting

The Have I Been Pwned API is free but has rate limits. If you need to check many passwords:
- Add delays between requests
- Consider the [API's usage policy](https://haveibeenpwned.com/API/v3#AcceptableUse)
- For high-volume usage, consider downloading the full Pwned Passwords database

## Contributing

Contributions are welcome!

## Acknowledgments

- [Troy Hunt](https://www.troyhunt.com/) for creating and maintaining [Have I Been Pwned](https://haveibeenpwned.com/)
- The cybersecurity community for promoting password security awareness

## Disclaimer

This tool is provided as-is for security awareness and password checking purposes. Always follow your organization's security policies regarding password handling and verification.

---

**⚠️ Important**: If you find that a password has been compromised, change it immediately on all services where you've used it. Consider using a password manager to generate and store unique, strong passwords for each service. **Remember**: just because a password hasn’t been pwned doesn’t mean it’s secure.
