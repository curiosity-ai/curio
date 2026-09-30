# Install curio, the Curiosity Studio shell, from the latest GitHub release.
#
#   irm https://curiosity.sh/install.ps1 | iex
#
# Puts the self-contained binary at ~\.curiosity\bin\curio.exe, next to curio's own config and
# credentials in ~\.curiosity\curio, and adds the folder to the user PATH. Runs on Windows PowerShell
# 5.1 and on PowerShell 7 on Windows, macOS and Linux (where the binary is ~/.curiosity/bin/curio).
#
# Settings, all optional, as environment variables (or parameters when the script is run as a file):
#   $env:CURIO_VERSION = 'v26.9.6085'   a release tag instead of the latest release
#   $env:CURIO_INSTALL = 'D:\tools\curiosity'   where to install; the binary goes in its bin folder
#   $env:CURIO_NO_MODIFY_PATH = '1'     leave PATH alone
#
# Everything is inside Install-Curio, called on the last line: a download cut off halfway runs nothing.

param(
    [string] $Version     = $env:CURIO_VERSION,
    [string] $InstallRoot = $env:CURIO_INSTALL,
    [switch] $NoModifyPath
)

function Install-Curio {
    param([string] $Version, [string] $InstallRoot, [bool] $NoModifyPath)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'   # Windows PowerShell 5.1 downloads many times slower with the progress bar on.
    $repo = 'curiosity-ai/curio'

    # Windows PowerShell 5.1 does not offer TLS 1.2 by default, and GitHub accepts nothing older.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    # $IsWindows only exists from PowerShell 6; Windows PowerShell 5.1 is Windows by definition.
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    if ($onWindows)  { $os = 'win' }
    elseif ($IsMacOS) { $os = 'osx' }
    elseif ($IsLinux) { $os = 'linux' }
    else { throw "unsupported operating system. Install with: dotnet tool install --global Curiosity.Shell" }

    # The OS architecture, not the process's: a 32-bit or emulated PowerShell should still get the native build.
    $arch = $null
    try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { }
    if (-not $arch -and $onWindows) {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    if ($os -eq 'osx' -and $arch -eq 'X64') {
        # A PowerShell running under Rosetta on an Apple silicon Mac.
        if ((& sysctl -n sysctl.proc_translated 2>$null) -eq '1') { $arch = 'Arm64' }
    }
    switch -Regex ($arch) {
        '^(X64|AMD64)$' { $arch = 'x64' }
        '^(Arm64|ARM64)$' { $arch = 'arm64' }
        default { throw "unsupported CPU architecture: $arch. Install with: dotnet tool install --global Curiosity.Shell" }
    }

    $exe   = if ($os -eq 'win') { 'curio.exe' } else { 'curio' }
    $asset = if ($os -eq 'win') { "curio-$os-$arch.exe" } else { "curio-$os-$arch" }

    if (-not $InstallRoot) { $InstallRoot = Join-Path $HOME '.curiosity' }
    $binDir = Join-Path $InstallRoot 'bin'
    $target = Join-Path $binDir $exe

    Write-Host "Installing curio ($os-$arch)"

    if ($Version) {
        $tag    = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        $api    = "https://api.github.com/repos/$repo/releases/tags/$tag"
        $direct = "https://github.com/$repo/releases/download/$tag"
    } else {
        $tag    = $null
        $api    = "https://api.github.com/repos/$repo/releases/latest"
        $direct = "https://github.com/$repo/releases/latest/download"
    }

    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers @{ Accept = 'application/vnd.github+json' }
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int] $_.Exception.Response.StatusCode }
        if ($status -eq 404 -and $tag) { throw "there is no curio release $tag; see https://github.com/$repo/releases" }
        Write-Warning "could not read the release from the GitHub API ($($_.Exception.Message)); downloading $asset directly"
    }

    $digest = $null
    if ($release) {
        $label = $release.tag_name
        $found = $release.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1
        if (-not $found -and $os -eq 'win' -and $arch -eq 'arm64') {
            # Windows on Arm runs x64 programs through its emulator.
            $found = $release.assets | Where-Object { $_.name -eq 'curio-win-x64.exe' } | Select-Object -First 1
            if ($found) { Write-Warning "no Windows Arm64 build in $label yet; installing the x64 one, which Windows runs emulated" }
        }
        if (-not $found) {
            $names = ($release.assets | ForEach-Object { $_.name }) -join ', '
            throw "release $label has no build for $os-$arch (it has: $names). Install with the .NET SDK instead: dotnet tool install --global Curiosity.Shell"
        }
        $asset = $found.name
        $url   = $found.browser_download_url
        if ($found.digest -and $found.digest.StartsWith('sha256:')) { $digest = $found.digest.Substring(7) }
    } else {
        # The API refused (rate limit, proxy): the release download URL redirects to the asset by name.
        $label = if ($tag) { $tag } else { '(latest)' }
        $url   = "$direct/$asset"
    }

    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    # Downloaded into the destination folder, so the final move stays on one volume.
    $tmp = Join-Path $binDir ".curio-download-$([guid]::NewGuid().ToString('N'))"
    try {
        Write-Host "  downloading ${label}: $url"
        try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing }
        catch { throw "download failed: $url ($($_.Exception.Message)). Releases: https://github.com/$repo/releases" }

        if ($digest) {
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
            if ($actual -ne $digest.ToLowerInvariant()) { throw "checksum mismatch for ${asset}: expected $digest, got $actual" }
            Write-Host '  sha256 verified'
        }

        if ($os -ne 'win') {
            & chmod 755 $tmp
            if ($os -eq 'osx') { & xattr -d com.apple.quarantine $tmp 2>$null }
        }

        if (Test-Path -LiteralPath $target) {
            # Windows cannot replace a running .exe, but it can rename one; the old copy goes next time.
            $old = "$target.old"
            Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
            if ($os -eq 'win') { Move-Item -LiteralPath $target -Destination $old -Force -ErrorAction SilentlyContinue }
        }
        Move-Item -LiteralPath $tmp -Destination $target -Force
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  installed $target"

    $sep     = [IO.Path]::PathSeparator
    $onPath  = ($env:PATH -split [regex]::Escape($sep)) -contains $binDir
    $newPath = $false

    if (-not $onPath -and -not $NoModifyPath) {
        if ($os -eq 'win') {
            # Read and written raw, so %VARIABLES% other installers left in the user PATH stay unexpanded.
            $key  = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            $user = [string] $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $parts = @($user -split ';' | Where-Object { $_ })
            if ($parts -notcontains $binDir) {
                $key.SetValue('Path', (($parts + $binDir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
                # Setting any user variable through .NET broadcasts WM_SETTINGCHANGE, so new terminals see the PATH.
                [Environment]::SetEnvironmentVariable('CURIO_INSTALLER', '1', 'User')
                [Environment]::SetEnvironmentVariable('CURIO_INSTALLER', $null, 'User')
                Write-Host "  added $binDir to your user PATH"
            }
            $key.Close()
        } else {
            # PowerShell on macOS and Linux has no persistent user PATH; its profile is the place.
            $profileFile = $PROFILE.CurrentUserAllHosts
            $line = "`$env:PATH = '$binDir' + [IO.Path]::PathSeparator + `$env:PATH"
            if (-not ((Test-Path -LiteralPath $profileFile) -and (Select-String -LiteralPath $profileFile -SimpleMatch $line -Quiet))) {
                New-Item -ItemType Directory -Force -Path (Split-Path $profileFile) | Out-Null
                Add-Content -LiteralPath $profileFile -Value "`n# curio`n$line"
                Write-Host "  added $binDir to PATH in $profileFile"
            }
            Write-Host "  for bash or zsh, add this to your shell profile: export PATH=`"$binDir`:`$PATH`""
        }
        $newPath = $true
    }
    # This session, too.
    if (-not $onPath) { $env:PATH = "$binDir$sep$env:PATH" }

    $first = Get-Command curio -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($first -and $first.Source -ne $target) {
        Write-Warning "another curio comes first on your PATH: $($first.Source)"
        Write-Warning "remove it (a .NET tool install: dotnet tool uninstall --global Curiosity.Shell) or put $binDir before it"
    }

    Write-Host ''
    Write-Host "curio $label is installed."
    if ($newPath) { Write-Host 'It is on PATH in this window now; other open terminals need restarting.' }
    Write-Host 'Start it with: curio'
}

Install-Curio -Version $Version -InstallRoot $InstallRoot -NoModifyPath ($NoModifyPath.IsPresent -or $env:CURIO_NO_MODIFY_PATH -eq '1')
