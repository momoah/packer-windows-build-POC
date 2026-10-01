$ErrorActionPreference = 'Stop'

function Find-OnCd([string]$Name) {
    $cds = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { $_.DeviceID + '\' }
    foreach ($cd in $cds) {
        $hit = Get-ChildItem -Path $cd -Filter $Name -Recurse -Depth 2 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "Could not find $Name on any CD drive"
}

function Install-Msi([string]$Name, [string]$Extra = '') {
    $msi = Find-OnCd $Name
    $log = "C:\Windows\Temp\$Name.log"
    Write-Output "Installing $msi ..."
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$log`" $Extra" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "$Name failed with exit code $($p.ExitCode) - see $log" }
}

# 1. QEMU guest agent
Install-Msi 'qemu-ga-x86_64.msi'
Get-Service QEMU-GA | Format-Table Name, Status, StartType -AutoSize

# 2. Cloudbase-Init: runs as LocalSystem, logs to COM1
Install-Msi 'CloudbaseInitSetup_Stable_x64.msi' 'RUN_SERVICE_AS_LOCAL_SYSTEM=1 LOGGINGSERIALPORTNAME=COM1'
# It should only run on clones, not inside the build VM
Stop-Service cloudbase-init -ErrorAction SilentlyContinue
Set-Service cloudbase-init -StartupType Automatic
Get-Service cloudbase-init | Format-Table Name, Status, StartType -AutoSize

Write-Output "Guest agent and Cloudbase-Init installed."
