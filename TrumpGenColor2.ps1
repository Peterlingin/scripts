# Generate phrases in the style of President Trump

$subjects = @(
    "People are saying",
    "Let me tell you",
    "Believe me",
    "I've always said",
    "Nobody knows",
    "A lot of people don't know",
    "It's true, folks",
    "Many people are talking about",
    "I know more than the experts",
    "Mark my words",
    "Everybody knows",
    "You won't hear this from the media",
    "Smart people tell me",
    "They never talk about it",
    "It's the truth, folks",
    "I hear it all the time",
    "People come up to me and say",
    "I said it before",
    "So many people agree",
    "Everybody is watching",
    "Experts are amazed",
    "The fake news won't report this",
    "Even my critics admit",
    "I've been told this many times",
    "Everybody agrees with me",
    "They call me and say",
    "It's being talked about everywhere",
    "We all know",
    "Ask anybody",
    "I hear it constantly",
    "It's common knowledge",
    "People are shocked by this",
    "You won't read this anywhere",
    "I've got to tell you",
    "Very smart people know this",
    "I was the first to say it",
    "History shows this",
    "It's obvious to everyone",
    "I've seen it first hand",
    "This isn't new to me",
    "I've heard this from the best",
    "Top people tell me",
    "Folks, it's everywhere",
    "Just look around",
    "People can't stop talking about it",
    "I've seen this over and over"
)

$claims = @(
    "we have the best",
    "this is the greatest",
    "nobody thought it was possible",
    "the numbers are incredible",
    "we're winning big time",
    "the system is rigged",
    "they don't want you to know",
    "we're making history",
    "it's all because of me",
    "they're trying to stop us",
    "our economy is the strongest",
    "no one saw this coming",
    "we're doing better than anyone else",
    "things are going perfectly",
    "everybody's amazed",
    "it's absolutely fantastic",
    "I've done more than anyone",
    "no president has done this before",
    "we are fixing everything",
    "people love what we're doing",
    "it's breaking all the records",
    "the crowds have never been bigger",
    "it was supposed to be impossible",
    "they said it couldn't be done",
    "we proved them all wrong",
    "nobody believed we could do it",
    "we solved problems no one else could",
    "it's beyond expectations",
    "the results are speaking for themselves",
    "it's better than anyone predicted",
    "we set new records",
    "we made the impossible possible",
    "it's the biggest success ever",
    "nobody does it like we do",
    "everybody wants to copy us",
    "we've changed everything",
    "it's a total game changer",
    "it's a complete turnaround",
    "we broke all expectations",
    "we shocked the experts",
    "the difference is night and day",
    "we turned things around",
    "everyone is winning now",
    "everything is back on track",
    "this is what success looks like",
    "we've hit new highs",
    "no one believed us at first"
)

$opinions = @(
    "In history.",
    "You wouldn't believe it.",
    "It's unbelievable.",
    "But we're fixing it.",
    "And everyone agrees.",
    "So true.",
    "We'll see what happens.",
    "Big league.",
    "The best you've ever seen.",
    "Tremendous things are happening.",
    "This will be remembered forever.",
    "We are making America great again.",
    "That's 100% true.",
    "You can't deny it.",
    "Everyone agrees.",
    "It's happening, folks.",
    "More than ever before.",
    "Just watch.",
    "We're winning, big time.",
    "History will remember this.",
    "It's a beautiful thing.",
    "That I can tell you.",
    "Total success.",
    "The results speak for themselves.",
    "Plain and simple.",
    "People are shocked.",
    "It keeps getting better.",
    "More proof every day.",
    "It's all true, folks.",
    "Everyone's talking about it.",
    "This is only the beginning.",
    "You'll be hearing more.",
    "We're only getting started.",
    "The future is looking great.",
    "Mark it down.",
    "Wait and see.",
    "Nobody can deny it.",
    "That's what the numbers show.",
    "People will remember this.",
    "The facts don't lie.",
    "Write it in the history books.",
    "Watch closely.",
    "This changes everything."
)

$fillerStart = @(
    "Look,",
    "Frankly,",
    "Honestly,",
    "I'm serious,",
    "No joke,",
    "Let me be clear,",
    "Here's the thing,",
    "This is important,",
    "You have to understand,",
    "It's simple,",
    "I'll tell you,",
    "Without question,",
    "You know,",
    "I've said it before and I'll say it again,",
    "Listen to me,",
    "And let me remind you,",
    "Clear as day,",
    "Make no mistake,",
    "You better believe it,",
    "And here's why,",
    "Let me explain,",
    "You can write this down,",
    "It's as clear as it gets,"
)

$fillerEnd = @(
    "Period.",
    "End of story.",
    "Remember that.",
    "Write it down.",
    "Believe it.",
    "Take it to the bank.",
    "That's the way it is.",
    "And that's final.",
    "No doubt about it.",
    "100 percent.",
    "You heard it here first.",
    "That's what's happening.",
    "And that's the truth.",
    "It's as simple as that.",
    "That's the fact.",
    "I couldn't be more right.",
    "Everyone knows it.",
    "Undeniable.",
    "Absolutely true.",
    "Case closed.",
    "Simple as that.",
    "It doesn't get clearer than this."
)

$colors = @("Green", "Cyan", "Yellow", "Magenta", "Blue", "White")

function Generate-TrumpPhrase {
    param(
        [int]$count = 1
    )
    $phrases = @{}
    while ($phrases.Count -lt $count) {
        $subject = Get-Random -InputObject $subjects
        $claim = Get-Random -InputObject $claims
        $opinion = Get-Random -InputObject $opinions
        $fillerPrefix = if ((Get-Random -Minimum 0 -Maximum 3) -eq 1) { "$(Get-Random -InputObject $fillerStart) " } else { "" }
        $fillerSuffix = if ((Get-Random -Minimum 0 -Maximum 3) -eq 1) { " $(Get-Random -InputObject $fillerEnd)" } else { "" }
        $connectors = @(", ", " - ", ". ")
        $connector = Get-Random -InputObject $connectors
        $phrase = "$fillerPrefix$subject says $claim$connector$opinion$fillerSuffix"
        if (-not $phrases.ContainsKey($phrase)) {
            $phrases[$phrase] = $true
        }
    }
    return $phrases.Keys
}

while ($true) {
    $num_phrases = Read-Host "Enter the number of phrases to generate"
    if ($num_phrases -match '^[0-9]+$' -and [int]$num_phrases -gt 0) {
        $num_phrases = [int]$num_phrases
        break
    }
    Write-Host "Invalid input. Please enter a positive number."
}

Generate-TrumpPhrase -count $num_phrases | ForEach-Object {
    $color = Get-Random -InputObject $colors
    Write-Host $_ -ForegroundColor $color
}
