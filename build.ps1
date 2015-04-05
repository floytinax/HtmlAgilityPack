param(
    [string]$config = "Release",
    [ValidateSet("quiet", "minimal", "normal", "detailed", "diagnostic")]
    [string]$verbosity = "diagnostic"
)

# Diagnostic 
function Write-Diagnostic {
    param([string]$message)

    Write-Host
    Write-Host $message -ForegroundColor Green
    Write-Host
}

function Die([string]$message, [object[]]$output) {
    if ($output) {
        Write-Output $output
        $message += ". See output above."
    }
    Write-Error $message
    exit 1
}

function Create-Folder-Safe {
    param(
        [string]$folder = $(throw "-folder is required.")
    )

    if(-not (Test-Path $folder)) {
        [System.IO.Directory]::CreateDirectory($folder) | Out-Null
    }

}

# Build
function Build-Clean {
    param(
        [string]$rootFolder = $(throw "-rootFolder is required."),
        [string]$folders = "bin,obj"
    )

    Write-Diagnostic "Build: Clean"

    Get-ChildItem $rootFolder -Include $folders -Recurse | ForEach-Object {
       Remove-Item $_.fullname -Force -Recurse 
    }
}

function Build-Bootstrap {
    param(
        [string]$solutionFile = $(throw "-solutionFile is required."),
        [string]$nugetExe = $(throw "-nugetExe is required.")
    )

    Write-Diagnostic "Build: Bootstrap"

    $solutionFolder = [System.IO.Path]::GetDirectoryName($solutionFile)

    . $nugetExe config -Set Verbosity=quiet
    . $nugetExe restore $solutionFile -NonInteractive

    Get-ChildItem $solutionFolder -filter packages.config -recurse | 
        Where-Object { -not ($_.PSIsContainer) } | 
        ForEach-Object {

        . $nugetExe restore $_.FullName -NonInteractive -SolutionDirectory $solutionFolder

    }
}

function Build-Nupkg {
    param(
        [string]$rootFolder = $(throw "-rootFolder is required."),
        [string]$project = $(throw "-project is required."),
        [string]$nugetExe = $(throw "-nugetExe is required."),
        [string]$outputFolder = $(throw "-outputFolder is required."),
        [string]$config = $(throw "-config is required."),
        [string]$version = $(throw "-version is required."),
        [string]$platform = $(throw "-platform is required.")
    )

    $outputFolder = Join-Path $outputFolder "$config"
    $nuspecFilename = [System.IO.Path]::GetFullPath($project) -ireplace ".csproj$", ".nuspec"

    if(-not (Test-Path $nuspecFilename)) {
        Die("Could not find nuspec: $nuspecFilename")
    }

    Write-Diagnostic "Creating nuget package for platform $platform"

    # http://docs.nuget.org/docs/reference/command-line-reference#Pack_Command
    . $nugetExe pack $nuspecFilename -OutputDirectory $outputFolder -Symbols -NonInteractive `
        -Properties "Configuration=$config;Bin=$outputFolder;Platform=$platform" -Version $version

    if($LASTEXITCODE -ne 0) {
        Die("Build failed: $projectName")
    }

    # Support for multiple build runners
    if(Test-Path env:BuildRunner) {
        $buildRunner = Get-Content env:BuildRunner

        switch -Wildcard ($buildRunner.ToString().ToLower()) {
            "myget" {

                $mygetBuildFolder = Join-Path $rootFolder "Build"

                Create-Folder-Safe -folder $mygetBuildFolder

                Get-ChildItem $outputFolder -filter *.nupkg | 
                Where-Object { -not ($_.PSIsContainer) } | 
                ForEach-Object {
                    $fullpath = $_.FullName
                    $filename = $_.Name

                    cp $fullpath $mygetBuildFolder\$filename
                }

            }
        }
    }
}

Function Get-MSBuild {
    $lib = [System.Runtime.InteropServices.RuntimeEnvironment]
    $rtd = $lib::GetRuntimeDirectory()
    Join-Path $rtd msbuild.exe
}

function Build-Project {
    param(
        [string]$rootFolder = $(throw "-rootFolder is required."),
        [string]$project = $(throw "-project is required."),
        [string]$config = $(throw "-config is required."),
        [string]$target = $(throw "-target is required.")
    )

    $project = Join-Path $rootFolder $project
    $projectPath = [System.IO.Path]::GetFullPath($project)
    $projectName = [System.IO.Path]::GetFileName($projectPath)

    if(-not (Test-Path $projectPath)) {
        Die("Could not find csproj: $projectPath")
    }

    $logFolder = Join-Path $rootFolder "log"

    Create-Folder-Safe -folder $logFolder

    Write-Diagnostic "Build: $projectName"

    & "$(Get-Content env:windir)\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe" `
        $projectPath `
        /t:$target `
        /p:Configuration=$config `
        /m `
        /v:$verbosity `
        /fl `
        /flp:LogFile=$logFolder\msbuild.log `
        /nr:false

    if($LASTEXITCODE -ne 0) {
        Die("Build failed: $projectName")
    }
}


# Bootstrap
$rootFolder = Split-Path -parent $script:MyInvocation.MyCommand.Definition
$outputFolder = Join-Path $rootFolder "bin"
$testsFolder = Join-Path $outputFolder "tests"

$config = $config.substring(0, 1).toupper() + $config.substring(1)

# Myget
$currentVersion = if(Test-Path env:PackageVersion) { Get-Content env:PackageVersion } else { $packageVersion }

if($currentVersion -eq "") {
    #Die("Package version cannot be empty")
}

$project = "CI.Build.proj"
$target = "Build"

Build-Project `
    -rootFolder $rootFolder `
    -project $project `
    -target $target `
    -config $config `
