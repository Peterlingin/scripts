# Password Strength Evaluator

A security-hardened PowerShell script that evaluates the quality of a password against modern security standards. The password is collected and processed without ever being stored as plaintext, using .NET's `SecureString` and careful unmanaged memory handling.

The script is designed for personal use, internal tooling, and security awareness training. It is not a replacement for a dedicated identity provider or a production-grade credential validation library, but it goes significantly further than most online password checkers in both accuracy and security.

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- .NET Framework 4.5+ (included with Windows 8 and later)
- Internet access (optional, for the Have I Been Pwned check)
- A wordlist file (optional, but strongly recommended -- see [Wordlist Setup](#wordlist-setup))

---

## Usage

```powershell
# Standard run (includes HIBP breach check)
.\Test-PasswordStrength.ps1

# Skip the network check (fully offline)
.\Test-PasswordStrength.ps1 -SkipHibpCheck

# Use a custom wordlist path
.\Test-PasswordStrength.ps1 -WordlistPath "C:\path\to\mylist.txt"
```

If your execution policy blocks unsigned scripts, run this first in the same session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

---

## Security Model

Protecting the password in memory was a primary design goal. The approach uses several layers:

### Input collection

The password is collected via `Read-Host -AsSecureString`. PowerShell stores it internally as a .NET `SecureString`, which is backed by the Windows Data Protection API (DPAPI). The characters are encrypted in memory and are never held as a plain `[string]` at the point of entry.

### Processing

To perform character-level analysis, the `SecureString` must be briefly converted into something readable. The script uses `Marshal.SecureStringToBSTR()` to copy the content into an unmanaged memory buffer (a BSTR), then reads that buffer character by character into a `[char[]]` array. This is done inside a `try/finally` block.

The unmanaged buffer is immediately zeroed and freed via `Marshal.ZeroFreeBSTR()` in the `finally` block, which executes even if an exception is thrown. This is the most secure approach available in managed .NET code.

### Cleanup

After analysis completes, `Array.Clear()` is called on the `[char[]]` work array, also inside a `finally` block, overwriting every character with a zero value before the array is garbage collected.

### Limitations

- The intermediate .NET `string` created during BSTR-to-array conversion is immutable and subject to garbage collection timing. It is set to `$null` immediately, but the GC decides when the memory is actually overwritten. This is a fundamental constraint of managed .NET and cannot be fully solved in PowerShell without a native C extension.
- If the user pastes the password, it passed through the clipboard before reaching the script. The script has no control over that.
- No data is written to disk, the event log, transcript output, or the PowerShell pipeline at any point.

---

## Wordlist Setup

The dictionary detection module loads an external plaintext wordlist at startup. Without it, the script falls back to a minimal 20-word built-in list, which is not meaningful for real-world use.

### Recommended source

The **SecLists** project on GitHub provides curated, real-world password lists derived from breach data:

```
https://github.com/danielmiessler/SecLists/tree/master/Passwords/Common-Credentials
```

The recommended starting file is:

```
10k-most-common.txt
```

You can download it directly with PowerShell:

```powershell
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10k-most-common.txt" `
  -OutFile "$PSScriptRoot\common-passwords.txt"
```

Place the file in the same folder as the script and name it `common-passwords.txt`. A custom path can also be passed via `-WordlistPath`.

### Larger lists

For broader coverage, the same SecLists folder contains:

| File | Size | Coverage |
|------|------|----------|
| `100k-most-used-passwords-NCSC.txt` | ~800 KB | UK NCSC curated list |
| `xato-net-10-million-passwords.txt` | ~46 MB | High coverage |

### Multilingual coverage

The default SecLists files are English-centric. Users whose passwords may contain words from other languages (Italian, French, German, Spanish, etc.) will get better detection by merging additional language-specific wordlists into `common-passwords.txt`. The SecLists repository includes language-specific lists under:

```
Passwords/
Passwords/Common-Credentials/Language-Specific/
```

To merge two lists on Windows:

```powershell
Get-Content list1.txt, list2.txt | Sort-Object -Unique | Set-Content common-passwords.txt
```

### How the wordlist is loaded

At startup, every line in the file is:

1. Trimmed and lowercased
2. Added to a `HashSet[string]` using `OrdinalIgnoreCase` comparison (O(1) lookup, no performance penalty regardless of list size)
3. Also indexed in its leet-normalised form (so `p@ssw0rd` matches the entry `password` without re-running normalisation at query time)

The script reports the active wordlist source at both startup and in the report footer, so there is no ambiguity about which list was used.

---

## Scoring

The overall score is out of 100 points, built from four positive components and up to two penalties.

### Length (0 to 30 points)

| Length | Points |
|--------|--------|
| 20+ characters | 30 |
| 16-19 characters | 25 |
| 12-15 characters | 18 |
| 10-11 characters | 12 |
| 8-9 characters | 6 |
| Below 8 characters | 0 |

Length is the single most important factor in password strength, which is why it carries the highest weight. NIST SP 800-63B sets 8 characters as the absolute minimum for user-chosen passwords; 16+ is the current practical recommendation.

### Shannon Entropy (0 to 25 points)

Shannon entropy measures the information content of the password based on character frequency distribution. A password where every character is different and unpredictable scores higher than one where the same characters repeat, even at the same length.

| Entropy (bits) | Points |
|----------------|--------|
| 75+ | 25 |
| 60-74 | 20 |
| 45-59 | 14 |
| 30-44 | 8 |
| 18-29 | 3 |
| Below 18 | 0 |

Note: Shannon entropy is calculated on raw character frequency. For passphrases (long sequences of natural-language words), this metric underestimates true entropy because it does not model word-level structure. The length score partially compensates for this.

### Charset Diversity (0 to 20 points)

Points are awarded for each character class present in the password:

| Class | Points |
|-------|--------|
| Lowercase letters (a-z) | 4 |
| Uppercase letters (A-Z) | 4 |
| Digits (0-9) | 4 |
| Special symbols (!@#$...) | 6 |
| Extended / Unicode characters | 2 |

Symbols receive the highest weight because they expand the effective alphabet the most relative to the number of characters added.

### Unique Character Ratio (0 to 10 points)

Measures the proportion of distinct characters relative to total length. This penalises passwords with heavy repetition (e.g. `aaaabbbb`).

The thresholds are **length-aware**. For passwords of 20 characters or more, the thresholds are relaxed because natural language inherently repeats common letters (`a`, `e`, `i`, `l`, etc.). A 54-character Italian passphrase at 48% unique characters is not weak -- applying short-password thresholds to it would be misleading.

| Condition | Points |
|-----------|--------|
| Above green threshold | 10 |
| Above yellow threshold | 5 |
| Below yellow threshold | 0 |

### Penalties

**Pattern penalty:** up to -15 points, applied at -5 per detected issue (capped at 3 issues).

**HIBP breach penalty:** applied if the password is found in the Have I Been Pwned database:

| Breach count | Penalty |
|--------------|---------|
| 10,000+ | -15 |
| 1,000+ | -12 |
| 100+ | -9 |
| 10+ | -6 |
| 1-9 | -3 |

### Rating bands

| Score | Rating |
|-------|--------|
| 85-100 | EXCELLENT |
| 70-84 | STRONG |
| 50-69 | MODERATE |
| 30-49 | WEAK |
| 0-29 | VERY WEAK |

---

## Pattern and Vulnerability Analysis

The script runs six independent pattern checks. Results are separated into **structural** findings (hard flaws that directly reduce keyspace or enable rule-based attacks) and **soft** findings (wordlist matches that are serious but do not imply structural predictability).

### 1. Repeated character runs

Detects three or more consecutive identical characters (e.g. `aaa`, `111`, `!!!`). Structural.

### 2. Keyboard and sequential walks

Detects substrings of 5 or more characters that appear in keyboard row sequences or the alphabet:

- QWERTY rows: `qwertyuiop`, `asdfghjkl`, `zxcvbnm`
- Common layouts: `azerty`, `qwertz`
- Numeric: `1234567890`, `0987654321`
- Alphabet: `abcdefghijklmnopqrstuvwxyz`

The minimum match length is 5 characters. A threshold of 4 produced too many false positives on innocent word fragments (`grid`, `riva`, `anna`). Structural.

### 3. Dictionary and wordlist detection

The leet-normalised form of the password is checked against the loaded wordlist using two strategies:

**Whole-password match:** the entire leet-normalised password is looked up directly. Catches passwords like `P@ssw0rd` (normalises to `password`).

**Token match:** the leet-normalised password is split on non-alphabetic characters (digits, symbols, spaces). Each alphabetic token of 4 or more characters is looked up independently. This catches constructions like `sunshine2024!` (token: `sunshine`) or `pass123!` (token: `pass`).

The minimum token length is 4 characters. This is intentionally short: `pass`, `love`, `dogs` are genuinely weak bases regardless of what is appended to them.

Wordlist hits are **not marked structural**. They are serious warnings but do not imply keyboard patterns or repetition.

### 4. Date patterns

Detects common date formats embedded in the password using regex:

- `DDMMYYYY` / `MMDDYYYY` compact forms
- Four-digit years matching `19xx` or `20xx`
- Delimited dates: `DD/MM/YY`, `DD-MM-YYYY`, etc.

Dates are among the most common personal information patterns used in passwords. Structural.

### 5. Single character class

Flags passwords composed entirely of digits or entirely of letters. All-digit passwords are the weakest possible case for a given length. Structural (all-digit), soft (all-letter).

### 6. Palindromes

Detects passwords of 6 or more characters that read the same forwards and backwards (case-insensitive). While palindromes are not trivially guessable, their symmetric structure reduces effective entropy. Structural.

---

## Cracking Time Estimates

Six attacker scenarios are modelled, covering a realistic range from rate-limited online services to nation-state hardware:

| Scenario | Guesses per second |
|----------|--------------------|
| Online, throttled | 100 /s |
| Online, unthrottled | 10,000 /s |
| Offline bcrypt GPU | 20,000 /s |
| Offline SHA-256 GPU cluster | 50,000,000,000 /s |
| Offline MD5 GPU cluster | 200,000,000,000 /s |
| Nation-state ASIC | 1,000,000,000,000 /s |

Times represent the **average case** (half the keyspace traversed). The keyspace is calculated from the effective charset size (only character classes actually present in the password) raised to the power of the password length.

### Important caveats displayed in the report

The script displays one of three contextual notes above the time table:

**If a wordlist hit was detected:**
The times are technically correct for a random password of that length and charset, but they are irrelevant. A dictionary attack would crack the password instantly regardless of appended digits or symbols, because attackers apply mutation rules (capitalisation, number appending, symbol substitution) to every word in their list automatically.

**If structural patterns were detected (but no wordlist hit):**
The times assume a fully random password. Rule-based attacks that exploit the detected patterns (e.g. repeating character rules, keyboard walk rules in Hashcat) would perform significantly faster.

**If no patterns were detected:**
The times reflect the actual estimated cracking effort for that password.

---

## Have I Been Pwned Integration

The script queries the [Have I Been Pwned](https://haveibeenpwned.com) API created by Troy Hunt, using the **k-anonymity model** to ensure the full password hash never leaves the machine.

### How k-anonymity works

1. A SHA-1 hash of the password is computed locally
2. Only the **first 5 hexadecimal characters** of that hash are sent to the API (e.g. `5BAA6`)
3. The API returns all hash suffixes in its database that begin with those 5 characters (typically several hundred entries)
4. The script checks locally whether the full hash suffix matches any returned entry
5. The server learns only that someone queried a prefix shared by hundreds of hashes -- it cannot determine which password was being checked

The full hash, the raw password bytes, and the char array are all cleared before the HTTP request is made.

To skip this check entirely (fully offline operation), use the `-SkipHibpCheck` switch.

---

## Compliance Quick-Check

Four widely referenced standards are evaluated:

### NIST SP 800-63B

**Pass conditions:** length >= 8, no structural patterns detected, not found in breach database.

NIST's 2017 guidelines deliberately moved away from complexity rules (mandatory uppercase, symbols, etc.) and towards length and breach checking as the primary criteria. The script reflects this: NIST compliance fails on structural flaws and breaches, not on missing character classes. Soft wordlist warnings do not cause a NIST failure.

### OWASP Authentication Cheat Sheet

**Pass conditions:** length >= 10, at least one uppercase letter, at least one lowercase letter, at least one digit or symbol.

OWASP maintains practical web application security guidance. Its password requirements are more prescriptive than NIST's, reflecting the reality that many applications cannot enforce passphrase-style passwords.

### CIS Controls v8

**Pass conditions:** length >= 14, effective charset size >= 62 (meaning at least three character classes are present).

The Center for Internet Security targets enterprise environments and sets a higher baseline.

### PCI-DSS v4

**Pass conditions:** length >= 12, at least one special symbol present.

The Payment Card Industry Data Security Standard applies to any system handling payment card data. Version 4 (2022) raised the minimum length from 7 to 12 characters.

---

## Output Color Coding

Throughout the report, color indicates how each individual metric compares to its threshold -- not whether the password as a whole passes or fails.

| Color | Meaning |
|-------|---------|
| Green | This metric is strong |
| Yellow | This metric is acceptable but improvable |
| Red | This metric is below the recommended threshold |

A red uniqueness ratio on a 54-character passphrase does not mean the password is weak -- it means that specific metric, in isolation, is below the short-password threshold. The overall score and rating reflect the complete picture.

---

## Known Limitations

Being transparent about what the script cannot do is part of using it responsibly.

**No personal context:** the script cannot know that a password contains the user's name, their child's name, a birthdate, or a hometown. Targeted attacks against known individuals try personal information first. This is the single largest gap between automated scoring and real-world risk.

**Finite wordlist:** even a 100,000-word list is small compared to what serious attackers use. A password based on an uncommon word not in the list will pass the dictionary check. Merging multilingual and domain-specific wordlists improves coverage.

**Static hardware benchmarks:** GPU performance improves continuously. The cracking time figures are based on approximately 2023-era hardware and will become more optimistic over time.

**Passphrase entropy underestimation:** Shannon entropy measured on character frequency does not model word-level unpredictability. A correctly generated Diceware passphrase has far higher entropy than the character-level score suggests.

**Managed memory:** the intermediate .NET string created during SecureString unmarshalling cannot be guaranteed to be overwritten before garbage collection. The BSTR is properly zeroed, but the managed string lingers until the GC runs. This is a fundamental limitation of PowerShell and .NET managed code.

**No clipboard control:** if the password was pasted, it transited the clipboard before the script received it.

---

## References

- [NIST SP 800-63B -- Digital Identity Guidelines](https://pages.nist.gov/800-63-3/sp800-63b.html)
- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [CIS Controls v8](https://www.cisecurity.org/controls/v8)
- [PCI-DSS v4.0](https://www.pcisecuritystandards.org/document_library/)
- [Have I Been Pwned k-Anonymity API](https://haveibeenpwned.com/API/v3#SearchingPwnedPasswordsByRange)
- [SecLists -- Common Credentials](https://github.com/danielmiessler/SecLists/tree/master/Passwords/Common-Credentials)
- [Dropbox zxcvbn -- realistic password strength estimation](https://github.com/dropbox/zxcvbn)
