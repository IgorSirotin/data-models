[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("generate-sources", "package")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$OpenApiRoot,

    [Parameter(Mandatory = $true)]
    [string]$PackagesRoot,

    [Parameter(Mandatory = $true)]
    [string]$TemplateDirectory,

    [Parameter(Mandatory = $true)]
    [string]$IgnoreFile,

    [Parameter(Mandatory = $true)]
    [string]$GeneratorVersion,

    [Parameter(Mandatory = $true)]
    [string]$PackageVersion,

    [string]$NugetOutput = "",

    [string]$PackageAuthors = "Codex"
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Remove-PathRobust {
    param(
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        return
    }

    $attempts = 5
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq $attempts) {
                throw
            }

            Start-Sleep -Milliseconds 750
        }
    }
}

function ConvertTo-PascalCase {
    param(
        [string]$Value
    )

    $parts = $Value -split '[^A-Za-z0-9]+'
    $tokens = foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        if ($part.Length -eq 1) {
            $part.ToUpperInvariant()
            continue
        }

        $part.Substring(0, 1).ToUpperInvariant() + $part.Substring(1).ToLowerInvariant()
    }

    return ($tokens -join "")
}

function Get-ApiSpecs {
    param(
        [string]$Root
    )

    Get-ChildItem -Path $Root -Directory | Sort-Object Name | ForEach-Object {
        $slug = $_.Name
        $mergedSpec = Join-Path $_.FullName "merged.yaml"
        if (-not (Test-Path -Path $mergedSpec)) {
            throw "Spec directory '$slug' does not contain merged.yaml"
        }

        [PSCustomObject]@{
            Slug = $slug
            ShortName = ConvertTo-PascalCase -Value $slug
            SpecRoot = $_.FullName
            MergedSpec = $mergedSpec
        }
    }
}

function Get-SpecTitle {
    param(
        [string]$MergedSpecPath,
        [string]$FallbackName
    )

    $content = [System.IO.File]::ReadAllText($MergedSpecPath, [System.Text.Encoding]::UTF8)
    $match = [regex]::Match($content, '(?m)^\s*title:\s*(?<title>.+?)\s*$')
    if ($match.Success) {
        return $match.Groups["title"].Value.Trim()
    }

    return "$FallbackName API"
}

function Remove-GeneratedArtifacts {
    param(
        [string]$GeneratedRoot,
        [string]$PackageName
    )

    $srcRoot = Join-Path $GeneratedRoot ("src\" + $PackageName)
    $pathsToDelete = @(
        (Join-Path $GeneratedRoot "build.bat"),
        (Join-Path $GeneratedRoot "build.sh"),
        (Join-Path $GeneratedRoot ($PackageName + ".sln")),
        (Join-Path $GeneratedRoot ".openapi-generator-ignore"),
        (Join-Path $GeneratedRoot ".openapi-generator"),
        (Join-Path $srcRoot ".gitignore"),
        (Join-Path $srcRoot ($PackageName + ".nuspec")),
        (Join-Path $srcRoot "Attributes"),
        (Join-Path $srcRoot "Authentication"),
        (Join-Path $srcRoot "Converters"),
        (Join-Path $srcRoot "Formatters"),
        (Join-Path $srcRoot "OpenApi")
    )

    foreach ($path in $pathsToDelete) {
        if (Test-Path -Path $path) {
            Remove-PathRobust -Path $path
        }
    }
}

function Remove-BuildArtifacts {
    param(
        [string]$GeneratedRoot,
        [string]$PackageName
    )

    $srcRoot = Join-Path $GeneratedRoot ("src\" + $PackageName)
    $pathsToDelete = @(
        (Join-Path $GeneratedRoot "README.md"),
        (Join-Path $srcRoot "bin"),
        (Join-Path $srcRoot "obj")
    )

    foreach ($path in $pathsToDelete) {
        if (Test-Path -Path $path) {
            Remove-PathRobust -Path $path
        }
    }
}

function Invoke-MavenGeneration {
    param(
        [string]$ProjectRootPath,
        [string]$SpecRoot,
        [string]$MergedSpec,
        [string]$GeneratedRoot,
        [string]$TemplateDirectoryPath,
        [string]$IgnoreFilePath,
        [string]$GeneratorVersionValue,
        [string]$PackageVersionValue,
        [string]$PackageName,
        [string]$PackageAuthorsValue,
        [string]$PackageDescription
    )

    $tempDir = Join-Path $ProjectRootPath "target\generated-package-poms"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    $pomPath = Join-Path $tempDir ($PackageName + ".pom.xml")
    $apiPackage = $PackageName + ".Controllers"
    $modelPackage = $PackageName + ".Models"

    $pomContent = @"
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.example</groupId>
    <artifactId>$PackageName-generator</artifactId>
    <version>$PackageVersionValue</version>
    <packaging>pom</packaging>
    <build>
        <plugins>
            <plugin>
                <groupId>org.openapitools</groupId>
                <artifactId>openapi-generator-maven-plugin</artifactId>
                <version>$GeneratorVersionValue</version>
                <executions>
                    <execution>
                        <id>generate</id>
                        <phase>generate-sources</phase>
                        <goals>
                            <goal>generate</goal>
                        </goals>
                        <configuration>
                            <generatorName>aspnetcore</generatorName>
                            <inputSpec>$MergedSpec</inputSpec>
                            <output>$GeneratedRoot</output>
                            <templateDirectory>$TemplateDirectoryPath</templateDirectory>
                            <ignoreFileOverride>$IgnoreFilePath</ignoreFileOverride>
                            <apiPackage>$apiPackage</apiPackage>
                            <modelPackage>$modelPackage</modelPackage>
                            <generateApiDocumentation>false</generateApiDocumentation>
                            <generateModelDocumentation>false</generateModelDocumentation>
                            <generateApiTests>false</generateApiTests>
                            <generateModelTests>false</generateModelTests>
                            <generateSupportingFiles>true</generateSupportingFiles>
                            <configOptions>
                                <packageName>$PackageName</packageName>
                                <packageVersion>$PackageVersionValue</packageVersion>
                                <packageDescription>$PackageDescription</packageDescription>
                                <packageAuthors>$PackageAuthorsValue</packageAuthors>
                                <targetFramework>net8.0</targetFramework>
                                <aspnetCoreVersion>8.0</aspnetCoreVersion>
                                <buildTarget>library</buildTarget>
                                <nullableReferenceTypes>true</nullableReferenceTypes>
                                <returnICollection>true</returnICollection>
                                <useDateTimeOffset>true</useDateTimeOffset>
                                <generateDocumentation>true</generateDocumentation>
                                <useSwashbuckle>false</useSwashbuckle>
                                <useNewtonsoft>false</useNewtonsoft>
                            </configOptions>
                        </configuration>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
"@

    [System.IO.File]::WriteAllText($pomPath, $pomContent, $Utf8NoBom)

    $previousMavenOpts = $env:MAVEN_OPTS
    $encodingFlags = "-Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8"
    if ([string]::IsNullOrWhiteSpace($previousMavenOpts)) {
        $env:MAVEN_OPTS = $encodingFlags
    }
    else {
        $env:MAVEN_OPTS = "$previousMavenOpts $encodingFlags"
    }

    try {
        & mvn "-f" $pomPath "generate-sources"
        if ($LASTEXITCODE -ne 0) {
            throw "Maven generation failed for package '$PackageName'"
        }
    }
    finally {
        $env:MAVEN_OPTS = $previousMavenOpts
    }

    & powershell "-ExecutionPolicy" "Bypass" "-File" (Join-Path $ProjectRootPath "scripts\PostProcess-GeneratedCode.ps1") `
        "-GeneratedRoot" $GeneratedRoot `
        "-SpecRoot" $SpecRoot `
        "-PackageName" $PackageName

    if ($LASTEXITCODE -ne 0) {
        throw "Post-processing failed for package '$PackageName'"
    }
}

function Invoke-DotnetPack {
    param(
        [string]$CsprojPath,
        [string]$NugetOutputPath
    )

    & dotnet "pack" $CsprojPath "-c" "Release" "-o" $NugetOutputPath "/p:ContinuousIntegrationBuild=true"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet pack failed for '$CsprojPath'"
    }
}

$specs = @(Get-ApiSpecs -Root $OpenApiRoot)

if ($specs.Count -eq 0) {
    throw "No OpenAPI spec directories were found in '$OpenApiRoot'"
}

switch ($Mode) {
    "generate-sources" {
        foreach ($spec in $specs) {
            $generatedRoot = Join-Path $PackagesRoot $spec.ShortName
            $packageName = "DataModels." + $spec.ShortName
            $packageDescription = "Generated ASP.NET Core abstractions for " + (Get-SpecTitle -MergedSpecPath $spec.MergedSpec -FallbackName $spec.ShortName) + "."

            if (Test-Path -Path $generatedRoot) {
                Remove-PathRobust -Path $generatedRoot
            }

            Invoke-MavenGeneration `
                -ProjectRootPath $ProjectRoot `
                -SpecRoot $spec.SpecRoot `
                -MergedSpec $spec.MergedSpec `
                -GeneratedRoot $generatedRoot `
                -TemplateDirectoryPath $TemplateDirectory `
                -IgnoreFilePath $IgnoreFile `
                -GeneratorVersionValue $GeneratorVersion `
                -PackageVersionValue $PackageVersion `
                -PackageName $packageName `
                -PackageAuthorsValue $PackageAuthors `
                -PackageDescription $packageDescription

            Remove-GeneratedArtifacts -GeneratedRoot $generatedRoot -PackageName $packageName
        }
    }
    "package" {
        if ([string]::IsNullOrWhiteSpace($NugetOutput)) {
            throw "NugetOutput is required for package mode"
        }

        New-Item -Path $NugetOutput -ItemType Directory -Force | Out-Null

        foreach ($spec in $specs) {
            $generatedRoot = Join-Path $PackagesRoot $spec.ShortName
            $packageName = "DataModels." + $spec.ShortName
            $csprojPath = Join-Path $generatedRoot ("src\" + $packageName + "\" + $packageName + ".csproj")

            if (-not (Test-Path -Path $csprojPath)) {
                throw "Generated project '$csprojPath' not found. Run generate-sources first."
            }

            Invoke-DotnetPack -CsprojPath $csprojPath -NugetOutputPath $NugetOutput
            Remove-BuildArtifacts -GeneratedRoot $generatedRoot -PackageName $packageName
        }
    }
}
