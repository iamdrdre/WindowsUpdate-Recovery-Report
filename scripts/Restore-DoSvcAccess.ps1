# EXPERIMENTAL reconstructed example, NOT the exact historical script.
# Modification and rollback paths have NOT been validated on a disposable test system.
# Default mode is read-only; -Apply requires an explicit operator decision.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [switch]$Apply,
    [string]$BackupDirectory,
    [string]$RestoreAclFrom
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run in an elevated PowerShell window.'
}
$keyPath = 'SYSTEM\CurrentControlSet\Services\DoSvc'
$psPath = 'Registry::HKEY_LOCAL_MACHINE\' + $keyPath
$original = Get-Acl -LiteralPath $psPath
$values = Get-ItemProperty -LiteralPath $psPath
$sections = [Security.AccessControl.AccessControlSections]'Access,Owner,Group'
if (-not $Apply) {
    $values | Select-Object Start,WubLock
    $original | Format-List Owner,AccessToString
    Write-Output 'Read-only mode. See docs/command-playbook.md before using -Apply.'
    return
}
if (-not $RestoreAclFrom) {
    if ($values.Start -ne 4 -or $values.WubLock -ne 1) {
        throw 'This example requires Start=4 and WubLock=1. Do not apply to another configuration.'
    }
    if ($original.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-18') {
        throw 'Owner differs from the recorded case (SYSTEM). Stop and investigate.'
    }
    $rules = @($original.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -eq 0 -or @($rules | Where-Object {
        $_.AccessControlType -ne 'Allow' -or $_.RegistryRights -ne [Security.AccessControl.RegistryRights]::ReadKey
    }).Count -gt 0) { throw 'ACL differs from the read-only case. Stop and investigate.' }
    if (-not $BackupDirectory) { throw 'Specify a new -BackupDirectory on a writable local drive.' }
    if (Test-Path -LiteralPath $BackupDirectory) { throw 'Backup directory already exists. Choose a new name.' }
} else {
    $restoreSddl = (Get-Content -LiteralPath $RestoreAclFrom -Raw).Trim()
    $restoreSecurity = [Security.AccessControl.RegistrySecurity]::new()
    $restoreSecurity.SetSecurityDescriptorSddlForm($restoreSddl,$sections)
}
if (-not $PSCmdlet.ShouldProcess($psPath,'Back up and modify the DoSvc root key ACL/owner')) { return }
if (-not $RestoreAclFrom) {
    New-Item -ItemType Directory -Path $BackupDirectory | Out-Null
    $original.GetSecurityDescriptorSddlForm($sections) |
        Set-Content -LiteralPath (Join-Path $BackupDirectory 'DoSvc-acl.sddl') -Encoding UTF8
    & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc' (Join-Path $BackupDirectory 'DoSvc.reg') /y
    if ($LASTEXITCODE -ne 0) { throw 'Registry export failed. No ACL change performed.' }
    $serviceConfig = & sc.exe qc DoSvc 2>&1
    $serviceConfigExit = $LASTEXITCODE
    if ($serviceConfigExit -ne 0) {
        throw "Service configuration query failed (exit $serviceConfigExit). No ACL change performed."
    }
    $serviceConfig | Out-File -LiteralPath (Join-Path $BackupDirectory 'DoSvc-config.txt') -ErrorAction Stop
}
if (-not ('DoSvcRepair.TokenPrivileges' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DoSvcRepair {
 public static class TokenPrivileges {
  [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] struct TP { public uint Count; public LUID Id; public uint Attributes; }
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint a,out IntPtr t);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string s,string n,out LUID l);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr t,bool d,ref TP n,uint z,IntPtr p,IntPtr r);
  public static void Enable(string name) {
   IntPtr token;
   if(!OpenProcessToken(GetCurrentProcess(),0x28,out token)) throw new System.ComponentModel.Win32Exception();
   try {
    LUID id;
    if(!LookupPrivilegeValue(null,name,out id)) throw new System.ComponentModel.Win32Exception();
    TP tp=new TP {Count=1,Id=id,Attributes=2};
    if(!AdjustTokenPrivileges(token,false,ref tp,0,IntPtr.Zero,IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
    int error=Marshal.GetLastWin32Error();
    if(error!=0) throw new System.ComponentModel.Win32Exception(error);
   } finally { CloseHandle(token); }
  }
 }
}
'@
}
[DoSvcRepair.TokenPrivileges]::Enable('SeTakeOwnershipPrivilege')
[DoSvcRepair.TokenPrivileges]::Enable('SeRestorePrivilege')
$ownerBefore = $original.GetOwner([Security.Principal.SecurityIdentifier])
$ownerChanged = $false
try {
    $takeKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [Security.AccessControl.RegistryRights]::TakeOwnership)
    if (-not $takeKey) { throw 'DoSvc key not found.' }
    try {
        $ownerSecurity = [Security.AccessControl.RegistrySecurity]::new()
        $ownerSecurity.SetOwner($identity.User)
        $takeKey.SetAccessControl($ownerSecurity)
        $ownerChanged = $true
    } finally { $takeKey.Dispose() }
    $writeKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [Security.AccessControl.RegistryRights]'ReadPermissions,ChangePermissions,TakeOwnership')
    try {
        if ($RestoreAclFrom) {
            $writeKey.SetAccessControl($restoreSecurity)
            $ownerChanged = $false
        } else {
            $security = $writeKey.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
            foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
                $rule = [Security.AccessControl.RegistryAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new($sid),
                    [Security.AccessControl.RegistryRights]::FullControl,
                    [Security.AccessControl.InheritanceFlags]::None,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow)
                $security.AddAccessRule($rule)
            }
            $writeKey.SetAccessControl($security)
        }
    } finally { if ($writeKey) { $writeKey.Dispose() } }
} finally {
    if ($ownerChanged) {
        $restoreOwnerKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [Security.AccessControl.RegistryRights]::TakeOwnership)
        try {
            $ownerSecurity = [Security.AccessControl.RegistrySecurity]::new()
            $ownerSecurity.SetOwner($ownerBefore)
            $restoreOwnerKey.SetAccessControl($ownerSecurity)
        } finally { if ($restoreOwnerKey) { $restoreOwnerKey.Dispose() } }
    }
}
Get-Acl -LiteralPath $psPath | Format-List Owner,AccessToString
Write-Output 'ACL operation completed. Start value was NOT changed. Close this PowerShell window to release enabled token privileges.'
