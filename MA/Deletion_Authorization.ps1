. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
# Version 226. Reauthenticate the current Windows account for user-requested deletions.
function Get-DeletionText {
    param([string]$English,[string]$Portuguese)
    if($script:UiLanguage -eq 'pt'){return $Portuguese};return $English
}
function Initialize-DeletionPasswordSetting {
    param([string]$ConfigPath=(Join-Path $PSScriptRoot 'config.json'))
    $path=[IO.Path]::GetFullPath($ConfigPath)
    $exists=Test-Path -LiteralPath $path -PathType Leaf
    $config=[pscustomobject]@{}
    if($exists){
        $config=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if($null -eq $config -or $config -isnot [pscustomobject]){throw 'config.json: expected a JSON object / esperado um objeto JSON.'}
    }
    if($null -eq $config.PSObject.Properties['RequirePasswordForDeletion']){
        $config | Add-Member NoteProperty RequirePasswordForDeletion $true
        $temporary=Join-Path (Split-Path $path -Parent) ('.deletion-config-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{
            [IO.File]::WriteAllText($temporary,($config | ConvertTo-Json -Depth 100),(New-Object Text.UTF8Encoding($false)))
            if($exists){[IO.File]::Copy($temporary,$path,$true)}else{[IO.File]::Move($temporary,$path)}
        }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    }
    return $config
}
function Test-DeletionPasswordRequired {
    param([string]$ConfigPath=(Join-Path $PSScriptRoot 'config.json'))
    # Missing/invalid settings keep protection enabled. Only JSON boolean false opts out.
    try{
        $config=Initialize-DeletionPasswordSetting $ConfigPath
        if($config.RequirePasswordForDeletion -is [bool]){return $config.RequirePasswordForDeletion}
    }catch{}
    return $true
}
# Persist the default when either application imports this helper.
try{[void](Initialize-DeletionPasswordSetting)}catch{Write-Warning (Get-DeletionText 'Could not initialize the deletion password setting. Password protection remains enabled.' 'Não foi possível inicializar a opção de palavra-passe para eliminações. A proteção mantém-se ativa.')}
function Initialize-WindowsDeletionAuthentication {
    if('MachiningMonitor.DeletionAuthentication' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
namespace MachiningMonitor {
 public static class DeletionAuthentication {
  [DllImport("advapi32.dll", EntryPoint="LogonUserW", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  static extern bool LogonUserW(string user, string domain, IntPtr password, int type, int provider, out IntPtr token);
  [DllImport("kernel32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  static extern bool CloseHandle(IntPtr token);
  public static bool Verify(SecureString password) {
   if(password==null || password.Length==0) return false;
   IntPtr secret=IntPtr.Zero, token=IntPtr.Zero;
   try {
    using(WindowsIdentity current=WindowsIdentity.GetCurrent()) {
     string account=current.Name, domain=null, user=account;
     int slash=account.IndexOf('\\');
     if(slash>=0) {domain=account.Substring(0,slash);user=account.Substring(slash+1);}
     secret=Marshal.SecureStringToGlobalAllocUnicode(password);
     if(!LogonUserW(user,domain,secret,2,0,out token)) return false;
     using(WindowsIdentity authenticated=new WindowsIdentity(token)) {
      return current.User!=null && authenticated.User!=null && current.User.Equals(authenticated.User);
     }
    }
   } catch {return false;}
   finally {
    if(token!=IntPtr.Zero) CloseHandle(token);
    if(secret!=IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(secret);
   }
  }
 }
}
'@ -ErrorAction Stop
}
function Test-WindowsDeletionPassword {
    param([Security.SecureString]$Password)
    Initialize-WindowsDeletionAuthentication
    return [MachiningMonitor.DeletionAuthentication]::Verify($Password)
}
function Confirm-DeletionAuthorization {
    param($Owner,[string]$Action)
    if(-not(Test-DeletionPasswordRequired)){return $true}
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    $dialog=New-Object Windows.Forms.Form
    try{
        $dialog.Text=Get-DeletionText 'Confirm deletion' 'Confirmar eliminação'
        $dialog.ClientSize=New-Object Drawing.Size(400,260);$dialog.StartPosition='CenterParent'
        $dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
        $dialog.Font=New-Object Drawing.Font('Segoe UI',10)
        $label=New-Object Windows.Forms.Label;$label.SetBounds(16,16,368,60)
        $label.Text=$Action+[Environment]::NewLine+(Get-DeletionText 'Enter the password for your Windows account:' 'Introduza a palavra-passe da sua conta Windows:')
        $account=New-Object Windows.Forms.Label;$account.AutoEllipsis=$true;$account.SetBounds(16,78,368,25)
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$account.Text=$identity.Name}finally{$identity.Dispose()}
        $password=New-Object Windows.Forms.TextBox;$password.SetBounds(16,110,368,28);$password.UseSystemPasswordChar=$true
        $errorLabel=New-Object Windows.Forms.Label;$errorLabel.SetBounds(16,146,368,52);$errorLabel.ForeColor=[Drawing.Color]::Firebrick
        $ok=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $ok;$ok.Text=Get-DeletionText 'Confirm' 'Confirmar';$ok.SetBounds(156,210,110,32)
        $cancel=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $cancel;$cancel.Text=Get-DeletionText 'Cancel' 'Cancelar';$cancel.SetBounds(274,210,110,32);$cancel.DialogResult='Cancel'
        $dialog.Controls.AddRange(@($label,$account,$password,$errorLabel,$ok,$cancel));$dialog.AcceptButton=$ok;$dialog.CancelButton=$cancel
        $dialog.Tag=@{Password=$password;ErrorLabel=$errorLabel;Confirm=$ok;Authenticated=$false}
        $dialog.Add_Shown({param($sender,$eventArgs) [void]$sender.Tag.Password.Focus()})
        $ok.Add_Click({param($sender,$eventArgs)
            $d=$sender.FindForm();$c=$d.Tag
            if([string]::IsNullOrEmpty($c.Password.Text)){$c.ErrorLabel.Text=Get-DeletionText 'Enter your Windows password.' 'Introduza a palavra-passe do Windows.';[void]$c.Password.Focus();return}
            $secure=$null;$c.Confirm.Enabled=$false
            try{
                $secure=ConvertTo-SecureString $c.Password.Text -AsPlainText -Force
                $c.Password.Clear()
                if(Test-WindowsDeletionPassword $secure){$c.Authenticated=$true;$d.DialogResult='OK';$d.Close()}
                else{$c.ErrorLabel.Text=Get-DeletionText 'Windows could not validate the password. Deletion was not authorized.' 'O Windows não conseguiu validar a palavra-passe. A eliminação não foi autorizada.'}
            }catch{$c.ErrorLabel.Text=Get-DeletionText 'Could not validate the Windows password. Deletion was not authorized.' 'Não foi possível validar a palavra-passe do Windows. A eliminação não foi autorizada.'}
            finally{if($secure){$secure.Dispose()};$c.Password.Clear();if(-not $d.IsDisposed){$c.Confirm.Enabled=$true;[void]$c.Password.Focus()}}
        })
        $result=if($null -ne $Owner){$dialog.ShowDialog($Owner)}else{$dialog.ShowDialog()}
        return $result -eq [Windows.Forms.DialogResult]::OK -and $dialog.Tag.Authenticated
    }finally{if($dialog.Tag){$dialog.Tag.Password.Clear()};$dialog.Dispose()}
}
