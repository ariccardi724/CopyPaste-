@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$dir = '%~dp0'.TrimEnd('\'); " ^
  "$desktop = [Environment]::GetFolderPath('Desktop'); " ^
  "$lnkPath = Join-Path $desktop 'ClipQueue.lnk'; " ^
  "$ws = New-Object -ComObject WScript.Shell; " ^
  "$sc = $ws.CreateShortcut($lnkPath); " ^
  "$sc.TargetPath = 'wscript.exe'; " ^
  "$sc.Arguments = '\"' + (Join-Path $dir 'Launch_ClipQueue.vbs') + '\"'; " ^
  "$sc.WorkingDirectory = $dir; " ^
  "$sc.IconLocation = (Join-Path $dir 'ClipQueue.ico') + ',0'; " ^
  "$sc.Description = 'ClipQueue - Floating Sequential Clipboard Manager'; " ^
  "$sc.Save(); " ^
  "Add-Type -AssemblyName System.Windows.Forms; " ^
  "[System.Windows.Forms.MessageBox]::Show('ClipQueue shortcut created on your Desktop!', 'ClipQueue', 'OK', 'Information') | Out-Null"
