# NATO Phonetic Alphabet converter for word initials

# Define the NATO phonetic alphabet
$natoAlphabet = @{
    'A' = 'Alpha'
    'B' = 'Bravo'
    'C' = 'Charlie'
    'D' = 'Delta'
    'E' = 'Echo'
    'F' = 'Foxtrot'
    'G' = 'Golf'
    'H' = 'Hotel'
    'I' = 'India'
    'J' = 'Juliett'
    'K' = 'Kilo'
    'L' = 'Lima'
    'M' = 'Mike'
    'N' = 'November'
    'O' = 'Oscar'
    'P' = 'Papa'
    'Q' = 'Quebec'
    'R' = 'Romeo'
    'S' = 'Sierra'
    'T' = 'Tango'
    'U' = 'Uniform'
    'V' = 'Victor'
    'W' = 'Whiskey'
    'X' = 'X-ray'
    'Y' = 'Yankee'
    'Z' = 'Zulu'
}

# Prompt for input
$phrase = Read-Host "Enter a phrase"

# Split the phrase into words
$words = $phrase -split '\s+'

# Process each word and convert the first letter
$result = @()
foreach ($word in $words) {
    if ($word.Length -gt 0) {
        $firstLetter = $word.Substring(0, 1).ToUpper()
        if ($natoAlphabet.ContainsKey($firstLetter)) {
            $result += $natoAlphabet[$firstLetter]
        } else {
            # If not a letter (number or special character), keep it as is
            $result += $firstLetter
        }
    }
}

# Display the result
Write-Host "`nNATO Phonetic Output:" -ForegroundColor Cyan
Write-Host ($result -join ' - ')