# Shows a Windows toast. Windows PowerShell 5.1 only (Common.ps1's Show-Notification calls it that way).
param([Parameter(Mandatory)] [string] $Title, [Parameter(Mandatory)] [string] $Message, [string] $Open)
$ErrorActionPreference = 'Stop'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$escape = { param($text) [Security.SecurityElement]::Escape($text) }
$launch = if ($Open) { " activationType=`"protocol`" launch=`"$(& $escape ([Uri]$Open).AbsoluteUri)`"" } else { '' }
$xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
$xml.LoadXml("<toast$launch scenario=`"reminder`"><visual><binding template=`"ToastGeneric`"><text>$(& $escape $Title)</text><text>$(& $escape $Message)</text></binding></visual><actions><action content=`"Dismiss`" arguments=`"dismiss`" activationType=`"system`"/></actions></toast>")
# Windows PowerShell's own app id, so no shortcut or registration is needed.
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
