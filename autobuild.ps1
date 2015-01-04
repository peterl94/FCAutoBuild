param(
    [switch]$runall,
    [switch]$update,
    [switch]$clean,
    [switch]$build,
    [switch]$test,
    [switch]$package,
    [switch]$upload,
    [switch]$fcver,
    [string[]]$arch = @("x64"),
    [string[]]$vcversion = @("12")
)

$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

. "$scriptPath\config.ps1"

$workDir = "$scriptPath\var"

function ExitIfError($message) {
    if ($LastExitCode -gt 0) {
        Write-Output "Error: $message"
        exit 1
    }
}

function Main
{
    if (! (Test-Path $workDir)) { md $workDir | Out-Null }
    
    foreach ($a in $arch) {
        if (! ($a -eq "x86" -or $a -eq "x64")) {
            Write-Error "Invalid architecture '$a': must be either x86 or x64"
        }
    }
    foreach ($v in $vcversion) {
        if (! ($v -eq "9" -or $v -eq "11" -or $v -eq "12")) {
            Write-Error "Unsupported Visual C version '$v': must be either 9, 11, or 12"
        }
    }
    
    $originalEnvPath = $env:Path
    
    if ($runall -or $update) {
        GetSource
    }
        
    foreach ($v in $vcversion) {
        foreach ($a in $arch) {
            $libPack = "$libPackPath\FreeCADLibs_${libPackVer}_${a}_VC${v}"
            $buildDir = "$workDir\build_${a}_VC$v"
            if (! (Test-Path $buildDir)) { md $buildDir | Out-Null }
            
            $env:Path = "$libPack\bin;" + $env:Path
            
            if ($runall -or $build) {
                Build $a $v $buildDir $libPack
            }
            
            $buildName = $nameTemplate -f (GetFCVersion $buildDir),$a,$v
            if ($v -eq "9") { 
                $buildName = $nameTemplateXP -f (GetFCVersion $buildDir),$a,$v
            }
            
            if ($runall) {
                Test $buildDir
                Package $buildName $buildDir
                Upload $buildName $buildDir
            } else {
                if ($test) { Test $buildDir }
                if ($package) { Package $buildName $buildDir }
                if ($upload) { Upload $buildName $buildDir }
            }
            
            $env:Path = $originalEnvPath
        }
    }
}

function GetSource
{
    $srcDir = "$workDir\freecad-git"
    if (! (Test-Path $srcDir)) {
        & $git clone git://git.code.sf.net/p/free-cad/code $srcDir
    }
    
    Push-Location $srcDir
    
    $oldRev = & $git rev-parse HEAD
    & $git pull
    $newRev = & $git rev-parse HEAD
    
    Pop-Location
    
    if ($newRev -eq $oldRev) {
        Write-Output "Info: No new commits"
        exit 0
    }
}

function Configure($arch, $vcVersion, $buildDir, $libPack)
{
    $vcYearMap = @{
       "9" = "2008"
       "11" = "2012"
       "12" = "2013"
    }
    $generator = "Visual Studio $vcVersion $($vcYearMap[$vcVersion])"
    if ($arch -eq "x64") { $generator = "$generator Win64" }
    
    $env:Path = "$gitBin;" + $env:Path
    Push-Location $buildDir
    
    & $cmake "-DFREECAD_LIBPACK_DIR=$libPack" -DFREECAD_USE_EXTERNAL_PIVY=ON -DFREECAD_USE_FREETYPE=ON -G $generator ..\freecad-git
    
    Pop-Location
    
    ExitIfError "CMake did not finish successfully"
}

function CopyLibs($arch, $vcVersion, $buildDir, $libPack)
{
    $patternBin = [regex]'^.+(?<!debug|[dD]4?|gd-[\w]+)\.dll$|^assistant.exe$|^TK[GV][23]d.dll$'
    $patternPy = [regex]'.*[^_][^d].pyd$|.*.py$'
    $folders = "DLLs", "PySide", "accessible", "codecs", "iconengines", "imageformats", "sqldrivers"
    
    if (! (Test-Path $buildDir)) { md "$buildDir\bin" | Out-Null }
    
    Get-ChildItem "$libPack\bin" | Where-Object {$_.Name -match $patternBin} | Copy-Item -Destination "$buildDir\bin" -Force 
    Copy-Item "$libPack\bin\Lib" "$buildDir\bin" -Recurse -Force
    foreach ($folder in $folders) {
        #create dest folder
        New-Item "$buildDir\bin\$folder" -Type Directory -Force | Out-Null
        
        $pattern = $patternBin
        if ("DLLs","PySide" -contains $folder) {
            $pattern = $patternPy
        }
        Get-ChildItem "$libPack\bin\$folder" | Where-Object {$_.Name -match $pattern} | Copy-Item -Destination "$buildDir\bin\$folder" -Force
    }
    
    #VC redist dlls
    $redistPath = "$vsPath$vcVersion.0\VC\redist\$arch"
    if ($vcVersion -ne "9") {
        Copy-Item "$redistPath\Microsoft.VC${vcVersion}0.CRT\*" "$buildDir\bin" -Force
        Copy-Item "$redistPath\Microsoft.VC${vcVersion}0.OpenMP\*" "$buildDir\bin" -Force
    }
    #use redistributable installer for VC 9
}

function Clean($buildDir)
{
    del -Recurse $buildDir
}

function Build($arch, $vcVersion, $buildDir, $libPack)
{
    if ($clean) { Clean $buildDir }
    Configure $arch $vcVersion $buildDir $libPack
    
    $platform = "Win32"
    if ($arch -eq "x64") { $platform = "x64" }
    
    if ($vcVersion -eq "9") {
        #fix for vcbuild not detecting header change
        #http://social.msdn.microsoft.com/Forums/en/msbuild/thread/072c8832-2ecf-4739-b4e2-35cf536c7091
        $env:Path = "$vsPath$vcVersion.0\Common7\IDE;" + $env:Path
        
        & $vcbuild "$buildDir\FreeCAD_trunk.sln" /M2 /nologo "Release|$platform"
    } else {
        & $msbuild "$buildDir\FreeCAD_trunk.sln" /m /nologo /verbosity:minimal /p:Configuration=Release "/p:Platform=$platform"
    }
    ExitIfError "Build did not complete successfully"
    
    if (! (Test-Path "$buildDir\bin\QtCore4.dll")) {
        #probably means that no libs have been copied
        CopyLibs $arch $vcVersion $buildDir $libPack
    }
}

function Test($buildDir)
{
    $env:PYTHONPATH = "$buildDir\bin"
    & python -c "import unittest,sys,FreeCAD,TestApp;sys.exit(not unittest.TextTestRunner().run(TestApp.All()).wasSuccessful())"
    ExitIfError "Test failed"
}

function GetFCVersion($buildDir, $full=$TRUE)
{
    
    $env:PYTHONPATH = "$buildDir\bin"
    $FCVer = & python -c "import FreeCAD;print(';'+' '.join(FreeCAD.Version()[:3]))"
    $FCVerSplit = ([string]$FCVer).Split(';')[1].Split()
    $FCVerMain = "$($FCVerSplit[0]).$($FCVerSplit[1])"
    $FCVerFull = "$FCVerMain.$($FCVerSplit[2])"
    
    if ($full) {
        return $FCVerFull
    } else {
        return $FCVerMain
    }
}

function Package($buildName, $buildDir)
{
   Rename-Item $buildDir "$workDir\$buildName"
   Push-Location $workDir
   
   & "$7z" a "$buildName.7z" "$buildName\bin\" "$buildName\Mod\" "$buildName\data\Mod\" "$buildName\data\examples\*.FCStd" "$buildName\data\examples\*.stp"
   
   Rename-Item "$workDir\$buildName" $buildDir
   Pop-Location
   ExitIfError "Archive was not created successfully"
}

function Upload($buildName, $buildDir)
{
    $archive = "$buildName.7z"
    $remoteDir = "/home/pfs/p/free-cad/FreeCAD Windows/FreeCAD $(GetFCVersion $buildDir -full $FALSE) development"
    $remoteFile = "$remoteDir/$archive"
    
    Push-Location $workDir
    
    "mkdir `"$remoteDir`"`r`nput $archive `"$remoteFile`"" | Out-File sftp_batch.txt -Encoding Ascii
    & $psftp -be -b sftp_batch.txt -pw $sfPassword "$sfUsername,free-cad@frs.sourceforge.net"
    
    Pop-Location
}

Main