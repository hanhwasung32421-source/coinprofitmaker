$ErrorActionPreference = 'Stop'

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$target = Join-Path $PSScriptRoot 'run_window_tiler.bat'
# PowerShell 5는 스크립트 파일 인코딩에 따라 한글 파일명이 깨질 수 있어,
# 기본은 영문 파일명으로 생성합니다(아이콘/이름은 바탕화면에서 바꿔도 됩니다).
$shortcutPath = Join-Path $desktop 'Window Tiler (10).lnk'

if (-not (Test-Path $target)) {
  throw "대상 실행 파일을 찾을 수 없습니다: $target"
}

$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath = $target
$sc.WorkingDirectory = $PSScriptRoot
# 아이콘(원하면 바꿀 수 있음): 기본 cmd 아이콘 사용
$sc.IconLocation = "$env:SystemRoot\System32\cmd.exe,0"
$sc.Save()

Write-Host "바탕화면 바로가기를 만들었습니다: $shortcutPath"
