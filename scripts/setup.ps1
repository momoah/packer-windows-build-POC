$ErrorActionPreference = 'Stop'

# Find a file on any CD drive (drive letters vary between builds)
function Find-OnCd([string]$Name) {
    $cds = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { $_.DeviceID + '\' }
    foreach ($cd in $cds) {
        $hit = Get-ChildItem -Path $cd -Filter $Name -Recurse -Depth 2 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "Could not find $Name on any CD drive"
}

# Install an MSI and FAIL THE BUILD if it doesn't work
function Install-Msi([string]$Name) {
    $msi = Find-OnCd $Name
    Write-Output "Installing $msi ..."
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "$Name failed with exit code $($p.ExitCode)" }
}

Install-Msi 'qemu-ga-x86_64.msi'

# Fails the build if the service doesn't exist
Get-Service QEMU-GA | Format-Table Name, Status, StartType -AutoSize
Write-Output "QEMU guest agent installed."
