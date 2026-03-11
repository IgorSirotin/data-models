[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GeneratedRoot,

    [Parameter(Mandatory = $true)]
    [string]$SpecRoot,

    [Parameter(Mandatory = $true)]
    [string]$PackageName
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-TagDescriptions {
    param(
        [string]$Root
    )

    $descriptions = @{}

    Get-ChildItem -Path $Root -Filter *.yaml -File |
        Where-Object { $_.Name -ne "merged.yaml" } |
        ForEach-Object {
            $content = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
            $match = [regex]::Match(
                $content,
                "(?ms)^tags:\s*\r?\n\s*-\s*name:\s*(?<name>[^\r\n#]+)\s*\r?\n\s*description:\s*(?<description>[^\r\n]+)"
            )

            if ($match.Success) {
                $descriptions[$match.Groups["name"].Value.Trim()] = $match.Groups["description"].Value.Trim()
            }
        }

    return $descriptions
}

function Get-NamespaceName {
    param(
        [string]$Content
    )

    $match = [regex]::Match($Content, "(?m)^namespace\s+(?<namespace>[A-Za-z0-9_.]+)\s*$")
    if (-not $match.Success) {
        throw "Namespace not found in generated file."
    }

    return $match.Groups["namespace"].Value
}

function Remove-InlineEnums {
    param(
        [string]$ModelsDirectory
    )

    Get-ChildItem -Path $ModelsDirectory -Filter *.cs -File | ForEach-Object {
        $path = $_.FullName
        $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $namespace = Get-NamespaceName -Content $content

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.AddRange([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8))

        $enumBlocks = [System.Collections.Generic.List[hashtable]]::new()

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -notmatch '^\[JsonConverter\(typeof\(JsonStringEnumConverter<(?<name>[A-Za-z0-9_]+)>\)\)\]$') {
                continue
            }

            $enumName = $Matches["name"]
            $start = $i
            while ($start -gt 0 -and $lines[$start - 1].Trim().StartsWith("///")) {
                $start--
            }

            if ($start -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$start - 1])) {
                $start--
            }

            $enumLineIndex = $i + 1
            while ($enumLineIndex -lt $lines.Count -and $lines[$enumLineIndex] -notmatch '^\s*public enum ') {
                $enumLineIndex++
            }

            if ($enumLineIndex -ge $lines.Count) {
                throw "Enum declaration for $enumName not found in $path"
            }

            $braceDepth = 0
            $end = $enumLineIndex
            $foundOpeningBrace = $false
            for (; $end -lt $lines.Count; $end++) {
                $braceDepth += ([regex]::Matches($lines[$end], '\{')).Count
                if ($lines[$end] -match '\{') {
                    $foundOpeningBrace = $true
                }

                $braceDepth -= ([regex]::Matches($lines[$end], '\}')).Count

                if ($foundOpeningBrace -and $braceDepth -eq 0) {
                    break
                }
            }

            if ($end -ge $lines.Count) {
                throw "Enum block for $enumName not closed in $path"
            }

            while (($end + 1) -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$end + 1])) {
                $end++
            }

            $blockLines = $lines.GetRange($start, $end - $start + 1)
            $enumBlocks.Add(@{
                Name = $enumName
                Start = $start
                End = $end
                Lines = [string[]]$blockLines
            })

            $i = $end
        }

        if ($enumBlocks.Count -eq 0) {
            return
        }

        for ($index = $enumBlocks.Count - 1; $index -ge 0; $index--) {
            $block = $enumBlocks[$index]
            $lines.RemoveRange($block.Start, $block.End - $block.Start + 1)
        }

        [System.IO.File]::WriteAllLines($path, $lines, $Utf8NoBom)

        $headerMatch = [regex]::Match(
            $content,
            "(?s)\A(?<header>.*?)(?=^namespace\s+[A-Za-z0-9_.]+\s*$)",
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        )

        if (-not $headerMatch.Success) {
            throw "Header not found in $path"
        }

        $header = $headerMatch.Groups["header"].Value.TrimEnd()

        foreach ($block in $enumBlocks) {
            $enumFilePath = Join-Path $ModelsDirectory ($block.Name + ".cs")
            $enumContent = @(
                $header
                ""
                "namespace $namespace"
                "{"
                $block.Lines
                "}"
                ""
            )

            [System.IO.File]::WriteAllLines($enumFilePath, $enumContent, $Utf8NoBom)
        }
    }
}

function Normalize-Controllers {
    param(
        [string]$ControllersDirectory,
        [hashtable]$TagDescriptions
    )

    Get-ChildItem -Path $ControllersDirectory -Filter *.cs -File | ForEach-Object {
        $path = $_.FullName
        $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

        $classMatch = [regex]::Match($content, "(?m)^(?<indent>\s*)public\s+[^{\r\n]*class\s+(?<className>[A-Za-z0-9_]+)\s*:\s*ControllerBase\s*$")
        if (-not $classMatch.Success) {
            return
        }

        $currentClassName = $classMatch.Groups["className"].Value
        $stem = $currentClassName -replace 'Controller$', ''
        $stem = $stem -replace 'Api$', ''
        $expectedClassName = "$stem" + "Controller"

        $updatedContent = $content
        if ($currentClassName -ne $expectedClassName) {
            $updatedContent = [regex]::Replace(
                $updatedContent,
                "(?m)^(\s*public\s+[^{\r\n]*class\s+)$([regex]::Escape($currentClassName))(\s*:\s*ControllerBase\s*)$",
                ('${1}' + $expectedClassName + '${2}'),
                1
            )
        }

        if ($TagDescriptions.ContainsKey($stem)) {
            $summary = $TagDescriptions[$stem]
            $updatedContent = [regex]::Replace(
                $updatedContent,
                "(?ms)^(?<indent>\s*)/// <summary>\r?\n.*?\r?\n\k<indent>/// </summary>\r?\n(?=\k<indent>\[ApiController\])",
                {
                    param($match)
                    $indent = $match.Groups["indent"].Value
                    return $indent + "/// <summary>`r`n" +
                        $indent + "/// " + $summary + "`r`n" +
                        $indent + "/// </summary>`r`n"
                },
                1
            )
        }

        if ($updatedContent -ne $content) {
            [System.IO.File]::WriteAllText($path, $updatedContent, $Utf8NoBom)
        }

        $expectedPath = Join-Path $ControllersDirectory ($expectedClassName + ".cs")
        if ($path -ne $expectedPath) {
            if (Test-Path -Path $expectedPath) {
                Remove-Item -Path $expectedPath -Force
            }

            Move-Item -Path $path -Destination $expectedPath
        }
    }
}

$srcRoot = Join-Path $GeneratedRoot ("src\" + $PackageName)
$modelsDirectory = Join-Path $srcRoot "Models"
$controllersDirectory = Join-Path $srcRoot "Controllers"
$tagDescriptions = Get-TagDescriptions -Root $SpecRoot

Remove-InlineEnums -ModelsDirectory $modelsDirectory
Normalize-Controllers -ControllersDirectory $controllersDirectory -TagDescriptions $tagDescriptions
