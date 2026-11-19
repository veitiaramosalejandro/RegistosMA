. (Join-Path $PSScriptRoot 'Button_Tooltips.ps1')
<#
Recording_Header.ps1 - documented version 123.
Shared recording header with folder selection, current path and language controls. Return control references so the caller can attach behavior.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
# Create folder selection, path display and language controls shared by recording windows.
function New-RecordingHeader {
    param($Parent,[string]$Root)
    $width=$Parent.ClientSize.Width
    $choose=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $choose; $choose.SetBounds(12,10,164,28)
    $path=New-Object Windows.Forms.Label; $path.Text=$Root; $path.AutoEllipsis=$true
    $path.SetBounds(184,14,($width-612),24); $path.Anchor='Top,Left,Right'
    $label=New-Object Windows.Forms.Label; $label.Text='Idioma / Language'
    $label.SetBounds(($width-420),14,124,24); $label.Anchor='Top,Right'
    $language=New-Object Windows.Forms.ComboBox; $language.DropDownStyle='DropDownList'
    $language.Items.AddRange(@('Português','English'))
    $language.SelectedIndex=$(if($script:UiLanguage -eq 'en'){1}else{0})
    $language.SetBounds(($width-292),10,150,28); $language.Anchor='Top,Right'
    $apply=New-Object Windows.Forms.Button; Register-ButtonActionTooltip $apply
    $apply.SetBounds(($width-134),10,122,28); $apply.Anchor='Top,Right'
    $choose.TabIndex=0; $language.TabIndex=1; $apply.TabIndex=2
    $Parent.Controls.AddRange(@($choose,$path,$label,$language,$apply))
    return @{ChooseFolder=$choose;PathLabel=$path;LanguageLabel=$label;Language=$language;ApplyLanguage=$apply}
}
