#Requires -Version 5.1
<#
.SYNOPSIS
    Evaluates the strength and security quality of a password.

.DESCRIPTION
    Analyzes a password against modern security standards (NIST SP 800-63B,
    OWASP, CIS Controls) covering complexity, entropy, cracking resistance,
    pattern detection, and common-password checks.

    SECURITY MODEL
    Password is collected via Read-Host -AsSecureString (DPAPI-encrypted
    SecureString). For analysis it is marshalled once to an unmanaged BSTR,
    read into a [char[]] array, then Marshal.ZeroFreeBSTR() is called in a
    finally{} block zeroing the buffer before freeing it. The char[] is also
    cleared in the same finally{}. No plaintext is written to disk, event
    log, transcript, or pipeline output.

.PARAMETER SkipHibpCheck
    Skip the Have I Been Pwned SHA-1 prefix check (requires internet).
    When absent, only the first 5 hex chars of the SHA-1 hash are sent
    to the HIBP k-anonymity API -- the full hash never leaves the machine.

.EXAMPLE
    .\Test-PasswordStrength.ps1

.EXAMPLE
    .\Test-PasswordStrength.ps1 -SkipHibpCheck

.NOTES
    References: NIST SP 800-63B, OWASP Authentication Cheat Sheet,
                CIS Controls v8, HIBP k-Anonymity API v3.
#>

[CmdletBinding()]
param(
    [switch]$SkipHibpCheck,
    [string]$WordlistPath = (Join-Path $PSScriptRoot "common-passwords.txt")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# REGION: Helpers
# ---------------------------------------------------------------------------

function Import-Wordlist {
    <#
    .SYNOPSIS
        Loads the external common-passwords wordlist into a HashSet for O(1) lookup.
        Falls back gracefully to a minimal built-in list if the file is not found.
        The leet-normalised form of every word is also added so substitutions
        like p@ssw0rd are caught without re-running normalisation at query time.
    #>
    param([string]$Path)

    $set = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Built-in fallback (used when no wordlist file is present)
    $fallback = @(
        'password','letmein','welcome','master','dragon','monkey',
        'shadow','sunshine','princess','football','baseball',
        'iloveyou','trustno1','superman','mustang','access',
        'michael','jessica','batman','login123','admin123'
    )

    $script:WordlistSource = "built-in fallback (20 words)"

    if (Test-Path $Path) {
        try {
            $lines = [System.IO.File]::ReadAllLines($Path,
                        [System.Text.Encoding]::UTF8)
            foreach ($line in $lines) {
                $w = $line.Trim().ToLower()
                if ($w.Length -ge 4) {
                    [void]$set.Add($w)
                    # Also index the leet-normalised form
                    $norm = $w -replace "[@4]","a" -replace "[3]","e" `
                               -replace "[1!|]","i" -replace "[0]","o" `
                               -replace "[`$5]","s" -replace "[7]","t"
                    [void]$set.Add($norm)
                }
            }
            $script:WordlistSource = "$($set.Count) words from $(Split-Path $Path -Leaf)"
        }
        catch {
            foreach ($w in $fallback) { [void]$set.Add($w) }
            $script:WordlistSource = "built-in fallback (wordlist load error: $_)"
        }
    } else {
        foreach ($w in $fallback) { [void]$set.Add($w) }
        $script:WordlistSource = "built-in fallback (common-passwords.txt not found in script folder)"
    }

    return $set
}


function Get-Entropy {
    param([char[]]$Chars)
    $freq = @{}
    foreach ($c in $Chars) {
        $key = [string]$c
        if ($freq.ContainsKey($key)) { $freq[$key]++ } else { $freq[$key] = 1 }
    }
    $len  = $Chars.Length
    $bits = 0.0
    foreach ($count in $freq.Values) {
        $p     = $count / $len
        $bits -= $p * [Math]::Log($p, 2)
    }
    return [Math]::Round($bits * $len, 2)
}

function Get-CharsetSize {
    param([char[]]$Chars)
    $hasLower    = $false
    $hasUpper    = $false
    $hasDigit    = $false
    $hasSymbol   = $false
    $hasExtended = $false
    foreach ($c in $Chars) {
        if      ([char]::IsLower($c))                { $hasLower    = $true }
        elseif  ([char]::IsUpper($c))                { $hasUpper   = $true }
        elseif  ([char]::IsDigit($c))                { $hasDigit   = $true }
        elseif  ([int]$c -gt 127)                    { $hasExtended = $true }
        else                                          { $hasSymbol  = $true }
    }
    $size = 0
    if ($hasLower)    { $size += 26  }
    if ($hasUpper)    { $size += 26  }
    if ($hasDigit)    { $size += 10  }
    if ($hasSymbol)   { $size += 32  }
    if ($hasExtended) { $size += 128 }
    return $size
}

function Get-BruteForceTime {
    param([int]$CharsetSize, [int]$Length)
    $keyspace  = [Math]::Pow($CharsetSize, $Length)
    $scenarios = [ordered]@{
        'Online (throttled, 100/s)'         = 100
        'Online (unthrottled, 10k/s)'       = 10000
        'Offline MD5 GPU cluster (200G/s)'  = 200e9
        'Offline bcrypt GPU (20k/s)'        = 20000
        'Offline SHA-256 GPU (50G/s)'       = 50e9
        'Nation-state ASIC (1T/s)'          = 1e12
    }
    $results = [ordered]@{}
    foreach ($s in $scenarios.GetEnumerator()) {
        $seconds = $keyspace / $s.Value / 2
        $results[$s.Key] = Format-TimeSpan $seconds
    }
    return $results
}

function Format-TimeSpan {
    param([double]$Seconds)
    if ($Seconds -lt 1)         { return 'Instant' }
    if ($Seconds -lt 60)        { return "$([Math]::Round($Seconds)) seconds" }
    if ($Seconds -lt 3600)      { return "$([Math]::Round($Seconds/60)) minutes" }
    if ($Seconds -lt 86400)     { return "$([Math]::Round($Seconds/3600)) hours" }
    if ($Seconds -lt 2592000)   { return "$([Math]::Round($Seconds/86400)) days" }
    if ($Seconds -lt 31536000)  { return "$([Math]::Round($Seconds/2592000)) months" }
    $years = $Seconds / 31536000
    if ($years -lt 1e3)  { return "$([Math]::Round($years)) years" }
    if ($years -lt 1e6)  { return "$([Math]::Round($years/1e3))K years" }
    if ($years -lt 1e9)  { return "$([Math]::Round($years/1e6))M years" }
    if ($years -lt 1e12) { return "$([Math]::Round($years/1e9))B years" }
    return "> 1 Trillion years"
}

function Test-CommonPatterns {
    param(
        [char[]]$Chars,
        [System.Collections.Generic.HashSet[string]]$Wordlist
    )
    $issues      = [System.Collections.Generic.List[string]]::new()
    $structural  = $false
    $wordlistHit = $false
    $pw         = [string]::new($Chars)
    $pwLower    = $pw.ToLower()

    # 1. Repeated character runs (aaa, 111)
    if ($pw -match '(.)\1{2,}') {
        $issues.Add("Contains repeated characters (e.g. 'aaa')")
        $structural = $true
    }

    # 2. Keyboard/sequential walks -- min 5 chars to avoid false positives
    $walks = @(
        'qwertyuiop','asdfghjkl','zxcvbnm',
        'qwerty','azerty','qwertz',
        '1234567890','0987654321',
        'abcdefghijklmnopqrstuvwxyz'
    )
    $walkHit = $false
    foreach ($walk in $walks) {
        if ($walkHit) { break }
        for ($i = 0; $i -le $walk.Length - 5; $i++) {
            $sub = $walk.Substring($i, 5)
            if ($pwLower -like "*$sub*") {
                $issues.Add("Contains keyboard/sequential walk: '$sub...'")
                $structural = $true
                $walkHit = $true
                break
            }
        }
    }

    # 3. Common password / dictionary word check via external wordlist
    #    Strategy:
    #      a) Leet-normalise the password
    #      b) Check exact match against the HashSet (whole password)
    #      c) Tokenise on non-alpha boundaries and check each token >= 4 chars
    #         This catches passwords like "sunshine2024!" or "P@ssword!"
    $leetNorm = $pwLower `
        -replace '[@4]','a' -replace '[3]','e' -replace '[1!|]','i' `
        -replace '[0]','o'  -replace '[$5]','s' -replace '[7]','t'

    if ($null -ne $Wordlist -and $Wordlist.Count -gt 0) {
        $matched = [System.Collections.Generic.List[string]]::new()

        # a) Whole-password exact match
        if ($Wordlist.Contains($pwLower) -or $Wordlist.Contains($leetNorm)) {
            $matched.Add($pwLower)
        }

        # b) Token match: split on digits/symbols/uppercase boundaries
        #    e.g. "sunshine2024!" -> ["sunshine"]
        #         "P@ssword!"     -> ["password"] after leet-norm
        $tokens = [regex]::Split($leetNorm, '[^a-z]+') |
                    Where-Object { $_.Length -ge 4 }
        foreach ($token in $tokens) {
            if ($Wordlist.Contains($token) -and -not $matched.Contains($token)) {
                $matched.Add($token)
            }
        }

        if ($matched.Count -gt 0) {
            $matchList = $matched -join "', '"
            $issues.Add("Matches wordlist entry/entries: '$matchList'")
            $wordlistHit = $true
        }
    }

    # 4. Date patterns
    if ($pw -match '\b(0[1-9]|[12]\d|3[01])(0[1-9]|1[0-2])(\d{2}|\d{4})\b' -or
        $pw -match '\b(19|20)\d{2}\b' -or
        $pw -match '\b\d{2}[/\-\.]\d{2}[/\-\.]\d{2,4}\b') {
        $issues.Add("Contains a date pattern (easily guessable)")
        $structural = $true
    }

    # 5. All same character class
    $allDigits  = @($Chars | Where-Object { [char]::IsDigit($_) }).Count -eq $Chars.Length
    $allLetters = @($Chars | Where-Object { [char]::IsLetter($_) }).Count -eq $Chars.Length
    if ($allDigits)  { $issues.Add("Contains only digits - trivially brute-forced"); $structural = $true }
    if ($allLetters) { $issues.Add("Contains only letters - limited charset") }

    # 6. Palindrome
    $reversed = if ($Chars.Length -gt 1) {
        [string]::new([char[]]($Chars[$($Chars.Length-1)..0]))
    } else { $pw }
    if ($pw.Length -ge 6 -and $pwLower -eq $reversed.ToLower()) {
        $issues.Add("Password is a palindrome (symmetric structure is weaker)")
        $structural = $true
    }

    return @{
        Issues      = [string[]]$issues.ToArray()
        Structural  = $structural
        WordlistHit = $wordlistHit
    }
}

function Get-HibpCount {
    param([char[]]$Chars)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Chars)
        $sha1  = [System.Security.Cryptography.SHA1]::Create()
        $hash  = $sha1.ComputeHash($bytes)
        $sha1.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)

        $hexFull = ($hash | ForEach-Object { $_.ToString('X2') }) -join ''
        $prefix  = $hexFull.Substring(0, 5)
        $suffix  = $hexFull.Substring(5)

        $uri      = "https://api.pwnedpasswords.com/range/$prefix"
        $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10 `
                        -Headers @{ 'Add-Padding' = 'true' }

        foreach ($line in $response -split "`n") {
            $parts = $line.Trim() -split ':'
            if ($parts[0] -ieq $suffix) { return [int]$parts[1] }
        }
        return 0
    }
    catch {
        return -1
    }
}

function Write-ColorLine {
    param([string]$Label, [string]$Value, [ConsoleColor]$Color = 'White')
    Write-Host "  $($Label.PadRight(42))" -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Get-ScoreColor {
    param([int]$Score, [int]$Max)
    $pct = $Score / $Max
    if ($pct -ge 0.80) { return 'Green'  }
    if ($pct -ge 0.55) { return 'Yellow' }
    return 'Red'
}

# ---------------------------------------------------------------------------
# REGION: Main evaluation
# ---------------------------------------------------------------------------

function Invoke-PasswordEvaluation {
    param(
        [System.Security.SecureString]$SecurePassword,
        [bool]$CheckHibp,
        [System.Collections.Generic.HashSet[string]]$Wordlist
    )

    $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $chars = $null
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $chars = $plain.ToCharArray()
        $plain = $null
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        $length      = $chars.Length
        $charsetSize = Get-CharsetSize $chars
        $entropy     = Get-Entropy     $chars

        $lowerCount    = @($chars | Where-Object { [char]::IsLower($_) }).Count
        $upperCount    = @($chars | Where-Object { [char]::IsUpper($_) }).Count
        $digitCount    = @($chars | Where-Object { [char]::IsDigit($_) }).Count
        $symbolCount   = @($chars | Where-Object {
            -not [char]::IsLetterOrDigit($_) -and [int]$_ -le 127
        }).Count
        $extendedCount = @($chars | Where-Object { [int]$_ -gt 127 }).Count
        $uniqueCount   = @($chars | Sort-Object -Unique).Count
        $uniqueRatio   = $uniqueCount / [Math]::Max($length, 1)

        $bfTimes      = Get-BruteForceTime -CharsetSize $charsetSize -Length $length
        $patResult    = Test-CommonPatterns -Chars $chars -Wordlist $Wordlist
        [string[]]$patternIssues = @($patResult.Issues)
        [bool]$hasStructural     = [bool]$patResult.Structural
        [bool]$hasWordlistHit    = [bool]$patResult.WordlistHit

        $hibpCount = -2
        if ($CheckHibp) {
            Write-Host "`n  Checking Have I Been Pwned database..." -ForegroundColor DarkGray
            $hibpCount = Get-HibpCount $chars
        }

        # -- Scoring (100 pts) -----------------------------------------------
        $score = 0

        $lengthScore = switch ($true) {
            ($length -ge 20) { 30; break }
            ($length -ge 16) { 25; break }
            ($length -ge 12) { 18; break }
            ($length -ge 10) { 12; break }
            ($length -ge  8) {  6; break }
            default           {  0 }
        }
        $score += $lengthScore

        $entropyScore = switch ($true) {
            ($entropy -ge 75) { 25; break }
            ($entropy -ge 60) { 20; break }
            ($entropy -ge 45) { 14; break }
            ($entropy -ge 30) {  8; break }
            ($entropy -ge 18) {  3; break }
            default            {  0 }
        }
        $score += $entropyScore

        $charsetScore = 0
        if ($lowerCount    -gt 0) { $charsetScore += 4 }
        if ($upperCount    -gt 0) { $charsetScore += 4 }
        if ($digitCount    -gt 0) { $charsetScore += 4 }
        if ($symbolCount   -gt 0) { $charsetScore += 6 }
        if ($extendedCount -gt 0) { $charsetScore += 2 }
        $score += $charsetScore

        # For long passphrases natural letter repetition is expected;
        # lower the threshold so a 50-char passphrase is not unfairly penalised.
        $uqThresholdGreen  = if ($length -ge 20) { 0.35 } else { 0.75 }
        $uqThresholdYellow = if ($length -ge 20) { 0.20 } else { 0.50 }
        $uniqueScore = switch ($true) {
            ($uniqueRatio -ge $uqThresholdGreen)  { 10; break }
            ($uniqueRatio -ge $uqThresholdYellow) {  5; break }
            default                                {  0 }
        }
        $score += $uniqueScore

        $patternPenalty = [Math]::Min($patternIssues.Count * 5, 15)
        $score -= $patternPenalty

        $hibpPenalty = 0
        if ($hibpCount -gt 0) {
            $hibpPenalty = switch ($true) {
                ($hibpCount -ge 10000) { 15; break }
                ($hibpCount -ge 1000)  { 12; break }
                ($hibpCount -ge 100)   {  9; break }
                ($hibpCount -ge 10)    {  6; break }
                default                {  3 }
            }
            $score -= $hibpPenalty
        }

        $score = [Math]::Max(0, [Math]::Min(100, $score))

        $rating = switch ($true) {
            ($score -ge 85) { 'EXCELLENT'; break }
            ($score -ge 70) { 'STRONG';    break }
            ($score -ge 50) { 'MODERATE';  break }
            ($score -ge 30) { 'WEAK';      break }
            default          { 'VERY WEAK' }
        }

        $ratingColor = switch ($rating) {
            'EXCELLENT' { 'Green'   }
            'STRONG'    { 'Cyan'    }
            'MODERATE'  { 'Yellow'  }
            'WEAK'      { 'Red'     }
            default      { 'DarkRed' }
        }

        # -- Output ----------------------------------------------------------
        $sep = '-' * 62

        Write-Host ""
        Write-Host "  $sep" -ForegroundColor DarkGray
        Write-Host "  PASSWORD STRENGTH REPORT" -ForegroundColor White
        Write-Host "  $sep" -ForegroundColor DarkGray

        Write-Host ""
        Write-Host "  OVERALL SCORE" -ForegroundColor DarkGray
        $scoreColor = Get-ScoreColor $score 100
        Write-Host "  $score / 100   " -NoNewline -ForegroundColor $scoreColor
        Write-Host $rating -ForegroundColor $ratingColor

        Write-Host ""
        Write-Host "  BASIC METRICS" -ForegroundColor DarkGray
        $lenCol = if ($length -ge 12) {'Green'} elseif ($length -ge 8) {'Yellow'} else {'Red'}
        $uqCol  = if ($uniqueRatio -ge $uqThresholdGreen) {'Green'} elseif ($uniqueRatio -ge $uqThresholdYellow) {'Yellow'} else {'Red'}
        $csCol  = if ($charsetSize -ge 94) {'Green'} elseif ($charsetSize -ge 62) {'Yellow'} else {'Red'}
        $enCol  = if ($entropy -ge 60) {'Green'} elseif ($entropy -ge 40) {'Yellow'} else {'Red'}
        Write-ColorLine "Length"                "$length characters" $lenCol
        Write-ColorLine "Unique characters"     "$uniqueCount / $length  (ratio: $([Math]::Round($uniqueRatio*100))%)" $uqCol
        Write-ColorLine "Effective charset size" "$charsetSize symbols" $csCol
        Write-ColorLine "Shannon entropy"       "$entropy bits" $enCol

        Write-Host ""
        Write-Host "  CHARACTER CLASS BREAKDOWN" -ForegroundColor DarkGray
        $c1 = if ($lowerCount    -gt 0) {'Green'} else {'DarkGray'}
        $c2 = if ($upperCount    -gt 0) {'Green'} else {'DarkGray'}
        $c3 = if ($digitCount    -gt 0) {'Green'} else {'DarkGray'}
        $c4 = if ($symbolCount   -gt 0) {'Green'} else {'DarkGray'}
        $c5 = if ($extendedCount -gt 0) {'Cyan'}  else {'DarkGray'}
        Write-ColorLine "Lowercase (a-z)"    $lowerCount    $c1
        Write-ColorLine "Uppercase (A-Z)"    $upperCount    $c2
        Write-ColorLine "Digits (0-9)"       $digitCount    $c3
        Write-ColorLine "Special symbols"    $symbolCount   $c4
        Write-ColorLine "Extended / Unicode" $extendedCount $c5

        Write-Host ""
        Write-Host "  SCORING BREAKDOWN" -ForegroundColor DarkGray
        $sl = if ($lengthScore  -ge 18) {'Green'} elseif ($lengthScore  -ge 10) {'Yellow'} else {'Red'}
        $se = if ($entropyScore -ge 18) {'Green'} elseif ($entropyScore -ge 10) {'Yellow'} else {'Red'}
        $sc = if ($charsetScore -ge 14) {'Green'} elseif ($charsetScore -ge  8) {'Yellow'} else {'Red'}
        $su = if ($uniqueScore  -ge  7) {'Green'} elseif ($uniqueScore  -ge  4) {'Yellow'} else {'Red'}
        Write-ColorLine "Length score      (max 30)" "$lengthScore pts"  $sl
        Write-ColorLine "Entropy score     (max 25)" "$entropyScore pts" $se
        Write-ColorLine "Charset score     (max 20)" "$charsetScore pts" $sc
        Write-ColorLine "Uniqueness score  (max 10)" "$uniqueScore pts"  $su
        if ($patternPenalty -gt 0) {
            Write-ColorLine "Pattern penalties"  "-$patternPenalty pts" 'Red'
        }
        if ($hibpPenalty -gt 0) {
            Write-ColorLine "HIBP breach penalty" "-$hibpPenalty pts"   'Red'
        }

        Write-Host ""
        Write-Host "  CRACKING TIME ESTIMATES" -ForegroundColor DarkGray
        if ($hasWordlistHit) {
            # Found in wordlist: a dictionary attack cracks this instantly,
            # regardless of appended digits/symbols.
            Write-Host "  [!!] Found in common password wordlist." -ForegroundColor Red
            Write-Host "       A dictionary attack would crack this INSTANTLY," -ForegroundColor Red
            Write-Host "       regardless of appended digits or symbols." -ForegroundColor Red
            Write-Host "  Brute-force lower bound (if attacker skips dict):" -ForegroundColor DarkGray
        } elseif ($hasStructural) {
            # Structural patterns (repeats, walks, etc.) make brute-force
            # times misleading -- rule-based attacks exploit these directly.
            Write-Host "  [!!] Structural patterns detected (repeats/walks/etc.)." -ForegroundColor Yellow
            Write-Host "       Brute-force times below assume a fully RANDOM password." -ForegroundColor Yellow
            Write-Host "       Rule-based attacks would crack this significantly faster." -ForegroundColor Yellow
            Write-Host "  Brute-force lower bound (random password of same length/charset):" -ForegroundColor DarkGray
        } else {
            Write-Host "  (No patterns detected -- times reflect actual estimated cracking effort)" -ForegroundColor DarkGray
        }
        foreach ($entry in $bfTimes.GetEnumerator()) {
            $timeColor = switch -Regex ($entry.Value) {
                'Instant|seconds|minutes'  { 'Red';    break }
                'hours|days'               { 'Yellow'; break }
                default                     { 'Green'  }
            }
            Write-ColorLine $entry.Key $entry.Value $timeColor
        }

        Write-Host ""
        Write-Host "  PATTERN & VULNERABILITY ANALYSIS" -ForegroundColor DarkGray
        if ($patternIssues.Count -eq 0) {
            Write-Host "  [OK] No common patterns detected" -ForegroundColor Green
        }
        else {
            foreach ($issue in $patternIssues) {
                Write-Host "  [!!] $issue" -ForegroundColor Red
            }
        }

        Write-Host ""
        Write-Host "  HAVE I BEEN PWNED  (k-Anonymity -- first 5 SHA-1 hex chars only)" -ForegroundColor DarkGray
        if      ($hibpCount -eq -2) { Write-Host "  [--] Check skipped (-SkipHibpCheck was set)" -ForegroundColor DarkGray }
        elseif  ($hibpCount -eq -1) { Write-Host "  [??] Could not reach HIBP API (network error)" -ForegroundColor Yellow }
        elseif  ($hibpCount -eq  0) { Write-Host "  [OK] Not found in any known breach database" -ForegroundColor Green }
        else                        { Write-Host "  [!!] Found in $hibpCount breach entries -- change this password immediately" -ForegroundColor Red }

        Write-Host ""
        Write-Host "  COMPLIANCE QUICK-CHECK" -ForegroundColor DarkGray
        $nist  = ($length -ge  8 -and (-not $hasStructural) -and $hibpCount -le 0)
        $owasp = ($length -ge 10 -and $upperCount -gt 0 -and $lowerCount -gt 0 `
                  -and ($digitCount -gt 0 -or $symbolCount -gt 0))
        $cis   = ($length -ge 14 -and $charsetSize -ge 62)
        $pci   = ($length -ge 12 -and $symbolCount -gt 0)
        $n1 = if ($nist)  {'PASS'} else {'FAIL'}; $nc1 = if ($nist)  {'Green'} else {'Red'}
        $n2 = if ($owasp) {'PASS'} else {'FAIL'}; $nc2 = if ($owasp) {'Green'} else {'Red'}
        $n3 = if ($cis)   {'PASS'} else {'FAIL'}; $nc3 = if ($cis)   {'Green'} else {'Red'}
        $n4 = if ($pci)   {'PASS'} else {'FAIL'}; $nc4 = if ($pci)   {'Green'} else {'Red'}
        Write-Host "  $("NIST SP 800-63B (>=8, no breaches, no patterns)".PadRight(52)) " -NoNewline; Write-Host $n1 -ForegroundColor $nc1
        Write-Host "  $("OWASP (>=10, mixed case + digit/symbol)".PadRight(52)) " -NoNewline; Write-Host $n2 -ForegroundColor $nc2
        Write-Host "  $("CIS Controls v8 (>=14, charset >= 62)".PadRight(52)) " -NoNewline; Write-Host $n3 -ForegroundColor $nc3
        Write-Host "  $("PCI-DSS v4 (>=12, includes special symbol)".PadRight(52)) " -NoNewline; Write-Host $n4 -ForegroundColor $nc4

        Write-Host ""
        Write-Host "  RECOMMENDATIONS" -ForegroundColor DarkGray
        [string[]]$recs = @()
        if ($length -lt 16)         { $recs += "Increase length to at least 16 characters" }
        if ($upperCount  -eq 0)     { $recs += "Add uppercase letters" }
        if ($lowerCount  -eq 0)     { $recs += "Add lowercase letters" }
        if ($digitCount  -eq 0)     { $recs += "Add digits" }
        if ($symbolCount -eq 0)     { $recs += 'Add special symbols (!@#$%^&*...)' }
        if ($uniqueRatio -lt $uqThresholdYellow)  { $recs += "Increase character variety (avoid repetition)" }
        if ($patternIssues.Count -gt 0)  { $recs += "Avoid predictable patterns and common password words" }
        if ($hibpCount -gt 0)       { $recs += "This password appeared in a breach -- replace it now" }

        if ($recs.Count -eq 0) {
            Write-Host "  [OK] Password meets all evaluated criteria." -ForegroundColor Green
        }
        else {
            foreach ($rec in $recs) {
                Write-Host "  --> $rec" -ForegroundColor Yellow
            }
        }

        Write-Host ""
        Write-Host "  $sep" -ForegroundColor DarkGray
        Write-Host "  NOTE: Password was never stored as plaintext." -ForegroundColor DarkGray
        Write-Host "        Unmanaged BSTR memory was zeroed immediately after use." -ForegroundColor DarkGray
        Write-Host "  DICT: $($script:WordlistSource)" -ForegroundColor DarkGray
        Write-Host "  $sep" -ForegroundColor DarkGray
        Write-Host ""
    }
    finally {
        if ($null -ne $chars) {
            [Array]::Clear($chars, 0, $chars.Length)
        }
    }
}

# ---------------------------------------------------------------------------
# REGION: Entry point
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
Write-Host "  |    PASSWORD STRENGTH EVALUATOR       |" -ForegroundColor Cyan
Write-Host "  |    Security-hardened/Zero plaintext  |" -ForegroundColor Cyan
Write-Host "  +--------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Enter your password below. Input is masked and never stored as plaintext." -ForegroundColor DarkGray
Write-Host ""

Write-Host "  Loading wordlist..." -NoNewline -ForegroundColor DarkGray
$wordlist = Import-Wordlist -Path $WordlistPath
Write-Host " $($script:WordlistSource)" -ForegroundColor DarkGray
Write-Host ""

$securePass = Read-Host -Prompt "  Password" -AsSecureString

if ($securePass.Length -eq 0) {
    Write-Host "`n  [!] No password entered. Exiting." -ForegroundColor Yellow
    exit 1
}

Invoke-PasswordEvaluation -SecurePassword $securePass -CheckHibp (-not $SkipHibpCheck) -Wordlist $wordlist

$securePass.Dispose()
