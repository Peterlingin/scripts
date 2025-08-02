# Virtual Magic 8-Ball (July 2025)
# Ref.: https://en.wikipedia.org/wiki/Magic_8_Ball

# Ask for the person's name and store it in a variable
$name = Read-Host "Enter the person's name"

# Define expanded set of Magic 8-Ball answers (20 responses like the classic toy)
$answers = @(
    # Positive responses
    "It is certain.",
    "Without a doubt.",
    "Yes definitely.",
    "You may rely on it.",
    "As I see it, yes.",
    "Most likely.",
    "Outlook good.",
    "Yes.",
    "Signs point to yes.",
    "Go for it!",
    "Bonus!",
    
    # Negative responses
    "Don't count on it.",
    "My reply is no.",
    "My sources say no.",
    "Outlook not so good.",
    "Very doubtful.",
    "No.",
    "You are fired!",
    "Go home!",
    
    # Non-committal responses
    "Reply hazy, try again.",
    "Ask again later.",
    "Better not tell you now.",
    "Cannot predict now.",
    "Concentrate and ask again.",
    "Maybe.",
    "Take a break.",
    "Get a job!"
)

# Pick one answer at random
$chosenAnswer = Get-Random -InputObject $answers

# Use string formatting instead of relying on variable expansion
$output = "You asked for {0}? This is the answer: {1}" -f $name, $chosenAnswer

# Show a Magic 8-Ball style "thinking" animation (reduced to 3 seconds)
Write-Host "`nShaking the Magic 8-Ball..." -ForegroundColor Yellow
for ($i = 1; $i -le 100; $i++) {
    Write-Progress -Activity "Consulting the mystical sphere..." -Status "Revealing your fortune... $i% Complete" -PercentComplete $i
    Start-Sleep -Milliseconds 30
}

# Clear the progress bar and show the result
Write-Progress -Activity "Complete" -Completed
Write-Host "`n$output" -ForegroundColor Green

# Add a dramatic pause and closing
Start-Sleep -Seconds 1
Write-Host "`nThe Magic 8-Ball has spoken!" -ForegroundColor Cyan
