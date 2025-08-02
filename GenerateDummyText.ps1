# This script allows you to specify the length of the text by using the -Length parameter.
# Example: .\GenerateDummyText.ps1 -Length 100

param(
    [Parameter(Mandatory = $true)]
    [int]$Length
)

# Sample words to create the dummy text.
$words = @(
    "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
    "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
    "magna", "aliqua", "ut", "enim", "ad", "minim", "veniam", "quis", "nostrud",
    "exercitation", "ullamco", "laboris", "nisi", "ut", "aliquip", "ex", "ea",
    "commodo", "consequat"
)

# Initialize variables.
$outputText = ""

# Generate text until the desired length is reached.
while ($outputText.Length -lt $Length) {
    $randomWord = $words | Get-Random
    if (($outputText.Length + $randomWord.Length + 1) -le $Length) {
        $outputText += "$randomWord "
    } else {
        break
    }
}

# Trim any trailing space and output the result.
$outputText = $outputText.TrimEnd()
Write-Output $outputText
