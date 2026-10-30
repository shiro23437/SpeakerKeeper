param([switch]$Minimized)

$ErrorActionPreference = 'Stop'

$script:root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:engine = Join-Path $script:root 'SpeakerKeeper.ps1'
$script:settingsFile = Join-Path $script:root 'settings.txt'
$script:launcher = Join-Path $script:root 'Launch-GUI.vbs'
$script:dataDir = Join-Path $env:LOCALAPPDATA 'NZXT-Relay-Keeper'
$script:logFile = Join-Path $script:dataDir 'SpeakerKeeper.log'
$script:guiSettingsFile = Join-Path $script:dataDir 'gui.json'
$script:stopFile = Join-Path $script:dataDir ('stop-' + $PID + '.signal')
. (Join-Path $script:root 'tools\Settings.ps1')
. (Join-Path $script:root 'tools\Startup.Common.ps1')
$script:worker = $null
$script:exiting = $false
$script:lastLogLength = -1

# Reject duplicate launches before loading WPF and WinForms.
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\SpeakerKeeper_GUI_SingleInstance', [ref]$created)
if (-not $created) { $script:mutex.Dispose(); exit }
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
    New-Item -ItemType Directory -Force -Path $script:dataDir | Out-Null
} catch {
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
    throw
}
$script:appListLoaded = $false
$script:deviceListLoaded = $false
$script:startupComplete = $false

function Read-KeeperSettings {
    $s = Read-KeeperConfiguration $script:settingsFile
    foreach ($key in @('Frequency', 'Amplitude', 'LingerSeconds', 'Threshold')) {
        $s[$key] = $s[$key].ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $s
}

function Write-KeeperSettings([hashtable]$updates) {
    $lines = if (Test-Path -LiteralPath $script:settingsFile) {
        [System.IO.File]::ReadAllLines($script:settingsFile)
    } else {
        @('# SpeakerKeeper GUI settings', 'SoundKeeper=SoundKeeper64.exe')
    }
    $out = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*([A-Za-z]+)\s*=') {
            $key = $Matches[1]
            if ($updates.ContainsKey($key)) {
                $out.Add($key + '=' + $updates[$key])
                $seen[$key] = $true
                continue
            }
        }
        $out.Add($line)
    }
    foreach ($key in $updates.Keys) {
        if (-not $seen.ContainsKey($key)) { $out.Add($key + '=' + $updates[$key]) }
    }
    $tmp = $script:settingsFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllLines($tmp, $out, (New-Object System.Text.UTF8Encoding($true)))
        if ([System.IO.File]::Exists($script:settingsFile)) {
            [System.IO.File]::Replace($tmp, $script:settingsFile, [System.Management.Automation.Language.NullString]::Value)
        } else { [System.IO.File]::Move($tmp, $script:settingsFile) }
    } finally {
        if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) }
    }
}

function Get-GuiTheme {
    if (Test-Path -LiteralPath $script:guiSettingsFile) {
        try {
            $p = Get-Content -LiteralPath $script:guiSettingsFile -Raw | ConvertFrom-Json
            if ($p.theme -in @('Light', 'Dark', 'System')) { return [string]$p.theme }
        } catch { }
    }
    return 'System'
}

function Save-GuiTheme([string]$theme) {
    @{ theme = $theme } | ConvertTo-Json | Set-Content -LiteralPath $script:guiSettingsFile -Encoding UTF8
}

function Is-Monitoring {
    return ($null -ne $script:worker -and -not $script:worker.HasExited)
}

function Start-Monitoring {
    if (Is-Monitoring) { return }
    if ($null -ne $script:worker) { $script:worker.Dispose(); $script:worker = $null }
    if (-not (Test-Path -LiteralPath $script:engine)) {
        [System.Windows.MessageBox]::Show('SpeakerKeeper.ps1 was not found.') | Out-Null
        return
    }
    Remove-Item -LiteralPath $script:stopFile -Force -ErrorAction SilentlyContinue
    $ps = Join-Path $PSHOME 'powershell.exe'
    $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StopFile "{1}" -LogFile "{2}"' -f $script:engine, $script:stopFile, $script:logFile
    try {
        $script:worker = Start-Process -FilePath $ps -ArgumentList $args -WindowStyle Hidden -PassThru
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Unable to start monitoring') | Out-Null
    }
    Update-Status
}

function Stop-Monitoring {
    if ($null -eq $script:worker) { return }
    if ($script:worker.HasExited) {
        $script:worker.Dispose()
        $script:worker = $null
        Remove-Item -LiteralPath $script:stopFile -Force -ErrorAction SilentlyContinue
        Update-Status
        return
    }
    $signaled = $false
    try {
        [System.IO.File]::WriteAllText($script:stopFile, 'stop')
        $signaled = $true
    } catch { }
    if (-not $signaled -or -not $script:worker.WaitForExit(3000)) {
        # Only clean up the SoundKeeper children of our worker, never all soundkeepers on the PC.
        try {
            $children = @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $script:worker.Id) -ErrorAction SilentlyContinue)
            foreach ($child in $children) {
                if ($child.Name -like 'SoundKeeper*.exe') {
                    Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
        try { $script:worker.Kill() } catch { }
    }
    $script:worker.Dispose()
    $script:worker = $null
    Remove-Item -LiteralPath $script:stopFile -Force -ErrorAction SilentlyContinue
    Update-Status
}

function Set-Startup([bool]$enabled) {
    $mode = if ($enabled) { 'add' } else { 'remove' }
    Set-KeeperStartup -Root $script:root -Kind Gui -Mode $mode
}

function Refresh-AppList([string]$selectedName, [switch]$SavedOnly) {
    $script:appBox.Items.Clear()
    $script:appBox.Items.Add([pscustomobject]@{ Display = 'すべてのアプリ'; ProcessName = '' }) | Out-Null
    $names = @{}
    # Keep startup independent of the number of desktop processes.
    if (-not $SavedOnly) {
        foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
            try {
                if ($p.MainWindowHandle -ne [IntPtr]::Zero -and -not [string]::IsNullOrWhiteSpace($p.ProcessName)) {
                    $names[$p.ProcessName] = $true
                }
            } catch { }
            finally { $p.Dispose() }
        }
        $script:appListLoaded = $true
    }
    foreach ($name in @($names.Keys | Sort-Object)) {
        $script:appBox.Items.Add([pscustomobject]@{ Display = $name; ProcessName = $name }) | Out-Null
    }
    if ($selectedName -and -not $names.ContainsKey($selectedName)) {
        $script:appBox.Items.Add([pscustomobject]@{
            Display = $(if ($SavedOnly) { $selectedName } else { $selectedName + ' (起動していません)' })
            ProcessName = $selectedName
        }) | Out-Null
    }
    $script:appBox.SelectedValue = $selectedName
    if ($script:appBox.SelectedIndex -lt 0) { $script:appBox.SelectedIndex = 0 }
}

function Get-OutputDeviceNames {
    # Compile only on demand, keeping normal and tray startup lightweight.
    if (-not ('SpeakerKeeperDevicePicker.Devices' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SpeakerKeeperDevicePicker
{
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint states, out IMMDeviceCollection devices);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int context, IntPtr parameters, out IntPtr instance);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey { public Guid format; public uint id; }
    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant
    {
        public ushort type, reserved1, reserved2, reserved3;
        public IntPtr value, extra;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class EnumeratorCom { }

    public static class Devices
    {
        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant value);

        // Active render endpoints use the same friendly names as the audio engine.
        public static string[] GetNames()
        {
            object enumerator = new EnumeratorCom();
            IMMDeviceCollection devices = null;
            var names = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                Marshal.ThrowExceptionForHR(((IMMDeviceEnumerator)enumerator).EnumAudioEndpoints(0, 1, out devices));
                uint count;
                Marshal.ThrowExceptionForHR(devices.GetCount(out count));
                for (uint i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    IPropertyStore store = null;
                    try
                    {
                        Marshal.ThrowExceptionForHR(devices.Item(i, out device));
                        Marshal.ThrowExceptionForHR(device.OpenPropertyStore(0, out store));
                        PropertyKey key = new PropertyKey();
                        key.format = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
                        key.id = 14; // PKEY_Device_FriendlyName
                        PropVariant value;
                        Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
                        try
                        {
                            string name = value.type == 31 ? Marshal.PtrToStringUni(value.value) : null;
                            if (!String.IsNullOrWhiteSpace(name)) names.Add(name);
                        }
                        finally { PropVariantClear(ref value); }
                    }
                    catch (COMException) { } // An endpoint may disappear during enumeration.
                    finally
                    {
                        if (store != null) Marshal.ReleaseComObject(store);
                        if (device != null) Marshal.ReleaseComObject(device);
                    }
                }
                var result = new string[names.Count];
                names.CopyTo(result);
                return result;
            }
            finally
            {
                if (devices != null) Marshal.ReleaseComObject(devices);
                Marshal.ReleaseComObject(enumerator);
            }
        }
    }
}
'@
    }
    return [SpeakerKeeperDevicePicker.Devices]::GetNames()
}

function Refresh-DeviceList([string]$selectedName, [switch]$SavedOnly) {
    # Fetch before clearing so errors never discard the user's current selection.
    $names = @()
    if (-not $SavedOnly) {
        try { $names = @(Get-OutputDeviceNames) }
        catch {
            [System.Windows.MessageBox]::Show(
                ('出力デバイス一覧を取得できませんでした。更新から再試行してください。' + [Environment]::NewLine + $_.Exception.Message),
                '出力デバイス') | Out-Null
            return
        }
    }
    $script:deviceBox.Items.Clear()
    $script:deviceBox.Items.Add([pscustomobject]@{ Display = 'すべての出力デバイス'; DeviceName = '' }) | Out-Null
    foreach ($name in $names) {
        $script:deviceBox.Items.Add([pscustomobject]@{ Display = $name; DeviceName = $name }) | Out-Null
    }
    if ($selectedName -and $selectedName -notin $names) {
        # Keep legacy partial-name filters and temporarily disconnected devices.
        $script:deviceBox.Items.Add([pscustomobject]@{ Display = $selectedName; DeviceName = $selectedName }) | Out-Null
    }
    $script:deviceBox.SelectedValue = $selectedName
    if ($script:deviceBox.SelectedIndex -lt 0) { $script:deviceBox.SelectedIndex = 0 }
    $script:deviceListLoaded = -not $SavedOnly
}

function Update-Status {
    if ($null -eq $script:statusText) { return }
    if (Is-Monitoring) {
        $script:statusText.Text = '監視中'
        $script:toggleButton.Content = '監視を停止'
        $script:tray.Text = 'NZXT Relay Keeper - Monitoring'
    } else {
        $script:statusText.Text = '停止中'
        $script:toggleButton.Content = '監視を開始'
        $script:tray.Text = 'NZXT Relay Keeper - Stopped'
    }
}

function Update-Log {
    if (-not (Test-Path -LiteralPath $script:logFile)) { return }
    try {
        $size = (Get-Item -LiteralPath $script:logFile).Length
        if ($size -eq $script:lastLogLength) { return }
        $script:lastLogLength = $size
        $lines = @(Get-Content -LiteralPath $script:logFile -Tail 120 -Encoding UTF8)
        $script:consoleBox.Text = $lines -join [Environment]::NewLine
        $script:consoleBox.ScrollToEnd()
    } catch { }
}

function Apply-Theme([string]$theme) {
    if ($theme -eq 'System') {
        try {
            $light = [Microsoft.Win32.Registry]::GetValue(
                'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
                'AppsUseLightTheme', 1)
            $theme = if ($light -eq 0) { 'Dark' } else { 'Light' }
        } catch { $theme = 'Light' }
    }
    # Reuse the current brushes unless the effective Windows/app theme changes.
    if ($script:appliedTheme -eq $theme) { return }
    if ($theme -eq 'Light') {
        $palette = @{
            WindowBrush = '#F2F5F9'; CardBrush = '#FFFFFF'; FieldBrush = '#E9EDF4'
            TextBrush = '#182334'; SubtleBrush = '#5D6B7D'; BorderBrush = '#D7DFE9'
        }
    } else {
        $palette = @{
            WindowBrush = '#101827'; CardBrush = '#1B2739'; FieldBrush = '#29384D'
            TextBrush = '#EDF3FA'; SubtleBrush = '#A7B5C5'; BorderBrush = '#3A4960'
        }
    }
    foreach ($name in $palette.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$name])
        $script:window.Resources[$name] = [System.Windows.Media.SolidColorBrush]::new($color)
    }
    $script:appliedTheme = $theme
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NZXT Relay Keeper" Width="440" Height="670" MinWidth="410" MinHeight="550"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBrush}">
  <Window.Resources>
    <SolidColorBrush x:Key="WindowBrush" Color="#101827"/>
    <SolidColorBrush x:Key="CardBrush" Color="#1B2739"/>
    <SolidColorBrush x:Key="FieldBrush" Color="#29384D"/>
    <SolidColorBrush x:Key="TextBrush" Color="#EDF3FA"/>
    <SolidColorBrush x:Key="SubtleBrush" Color="#A7B5C5"/>
    <SolidColorBrush x:Key="BorderBrush" Color="#3A4960"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#417DDC"/>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource FieldBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <!-- Native Windows combo templates keep a light background even in app dark mode.
         Keep their text and item surfaces light-theme matched in every app theme. -->
    <Style TargetType="ComboBox">
      <Style.Resources>
        <!-- Override the window TextBlock style for generated selection/item text. -->
        <Style TargetType="TextBlock">
          <Setter Property="Foreground" Value="#182334"/>
          <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
      </Style.Resources>
      <Setter Property="Background" Value="#E9EDF4"/>
      <Setter Property="Foreground" Value="#182334"/>
      <Setter Property="BorderBrush" Value="#D7DFE9"/>
      <Setter Property="Padding" Value="8,3"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#182334"/>
      <Setter Property="Background" Value="#FFFFFF"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
  </Window.Resources>
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="120"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="NZXT Relay Keeper" FontSize="23" FontWeight="SemiBold"/>
        <TextBlock Text="Speaker Power Management" Foreground="{DynamicResource SubtleBrush}" FontSize="12"/>
      </StackPanel>
      <ComboBox x:Name="ThemeBox" Grid.Column="1" Margin="6,4,0,4" SelectedValuePath="Tag">
        <ComboBoxItem Content="ライト" Tag="Light"/>
        <ComboBoxItem Content="ダーク" Tag="Dark"/>
        <ComboBoxItem Content="システム" Tag="System"/>
      </ComboBox>
    </Grid>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderBrush}"
                BorderThickness="1" CornerRadius="12" Padding="14" Margin="0,0,0,12">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock x:Name="StatusText" Text="停止中" FontSize="17" FontWeight="SemiBold"/>
              <TextBlock Text="検出対象アプリの音声を監視します" Foreground="{DynamicResource SubtleBrush}" FontSize="11"/>
            </StackPanel>
            <Button x:Name="ToggleButton" Grid.Column="1" Content="監視を開始" Margin="10,0,0,0"/>
          </Grid>
        </Border>
        <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderBrush}"
                BorderThickness="1" CornerRadius="12" Padding="14">
          <StackPanel>
            <TextBlock Text="音声を検出するアプリ" FontSize="13" FontWeight="SemiBold"/>
            <Grid Margin="0,7,0,13">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ComboBox x:Name="AppBox" Grid.Column="0" DisplayMemberPath="Display" SelectedValuePath="ProcessName" MaxDropDownHeight="240"/>
              <Button x:Name="RefreshApps" Grid.Column="1" Content="更新" Margin="8,0,0,0" Height="32" Padding="12,3" VerticalAlignment="Center"/>
            </Grid>
            <TextBlock Text="対象の出力デバイス" FontSize="12"/>
            <Grid Margin="0,6,0,13">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ComboBox x:Name="DeviceBox" Grid.Column="0" DisplayMemberPath="Display" SelectedValuePath="DeviceName"
                        MaxDropDownHeight="240" ToolTip="選んだデバイスがWindowsの既定の出力先になっているときに動作します"/>
              <Button x:Name="RefreshDevices" Grid.Column="1" Content="更新" Margin="8,0,0,0" Height="32" Padding="12,3" VerticalAlignment="Center"/>
            </Grid>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Margin="0,0,6,0">
                <TextBlock Text="余韻時間 (秒)"/>
                <TextBox x:Name="LingerBox" Margin="0,5,0,10"/>
                <TextBlock Text="音量 (%)"/>
                <TextBox x:Name="AmplitudeBox" Margin="0,5,0,10"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="6,0,0,0">
                <TextBlock Text="周波数 (Hz)"/>
                <TextBox x:Name="FrequencyBox" Margin="0,5,0,10"/>
                <TextBlock Text="検出しきい値"/>
                <TextBox x:Name="ThresholdBox" Margin="0,5,0,10"/>
              </StackPanel>
            </Grid>
            <CheckBox x:Name="AutostartBox" Content="Windowsログイン時に起動 (トレイに収納)" Margin="0,1,0,12"/>
            <Button x:Name="SaveButton" Content="設定を保存"/>
          </StackPanel>
        </Border>
        <Expander x:Name="ConsoleExpander" Header="  Console / 動作履歴" Margin="0,14,0,0">
          <Border Background="{DynamicResource CardBrush}" Padding="8" CornerRadius="9" Margin="0,8,0,0">
            <TextBox x:Name="ConsoleBox" Height="160" FontFamily="Consolas" FontSize="11"
                     IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"
                     HorizontalScrollBarVisibility="Auto"/>
          </Border>
        </Expander>
        <TextBlock Text="× でトレイに収納・トレイメニューから終了" Foreground="{DynamicResource SubtleBrush}"
                   HorizontalAlignment="Center" FontSize="11" Margin="0,14,0,6"/>
      </StackPanel>
    </ScrollViewer>
  </Grid>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $script:window = [Windows.Markup.XamlReader]::Load($reader)
    $script:themeBox = $script:window.FindName('ThemeBox')
    $script:appBox = $script:window.FindName('AppBox')
    $script:deviceBox = $script:window.FindName('DeviceBox')
    $script:lingerBox = $script:window.FindName('LingerBox')
    $script:frequencyBox = $script:window.FindName('FrequencyBox')
    $script:amplitudeBox = $script:window.FindName('AmplitudeBox')
    $script:thresholdBox = $script:window.FindName('ThresholdBox')
    $script:autostartBox = $script:window.FindName('AutostartBox')
    $script:statusText = $script:window.FindName('StatusText')
    $script:toggleButton = $script:window.FindName('ToggleButton')
    $script:consoleBox = $script:window.FindName('ConsoleBox')
    $script:consoleExpander = $script:window.FindName('ConsoleExpander')

    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Icon = [System.Drawing.SystemIcons]::Application
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $showItem = $menu.Items.Add('ウィンドウを表示')
    $monitorItem = $menu.Items.Add('監視を開始/停止')
    $quitItem = $menu.Items.Add('終了')
    $script:tray.ContextMenuStrip = $menu
    $script:tray.Visible = $true

    $settings = Read-KeeperSettings
    Refresh-DeviceList $settings.DeviceName -SavedOnly
    $script:lingerBox.Text = $settings.LingerSeconds
    $script:frequencyBox.Text = $settings.Frequency
    $script:amplitudeBox.Text = $settings.Amplitude
    $script:thresholdBox.Text = $settings.Threshold
    Refresh-AppList $settings.AppName -SavedOnly
    $script:autostartBox.IsChecked = $false
    foreach ($name in @(Get-KeeperStartupNames 'Gui')) {
        if (Test-KeeperShortcut (Join-Path (Get-KeeperStartupFolder) $name) $script:root 'Gui') {
            $script:autostartBox.IsChecked = $true
        }
    }
    $script:themePreference = Get-GuiTheme
    $script:themeBox.SelectedValue = $script:themePreference
    Apply-Theme $script:themePreference

    $script:themeBox.Add_SelectionChanged({
        if ($null -eq $script:window) { return }
        $script:themePreference = [string]$script:themeBox.SelectedValue
        Apply-Theme $script:themePreference
        try { Save-GuiTheme $script:themePreference }
        catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Unable to save theme') | Out-Null }
    })

    $script:appBox.Add_DropDownOpened({
        if (-not $script:appListLoaded) {
            Refresh-AppList ([string]$script:appBox.SelectedValue)
        }
    })
    $script:deviceBox.Add_DropDownOpened({
        if (-not $script:deviceListLoaded) {
            Refresh-DeviceList ([string]$script:deviceBox.SelectedValue)
        }
    })
    $script:window.FindName('RefreshDevices').Add_Click({
        Refresh-DeviceList ([string]$script:deviceBox.SelectedValue)
    })
    $script:consoleExpander.Add_Expanded({ Update-Log })

    $script:window.FindName('RefreshApps').Add_Click({
        Refresh-AppList ([string]$script:appBox.SelectedValue)
    })

    $script:window.FindName('SaveButton').Add_Click({
        try {
            $values = @{}
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            foreach ($entry in @(
                @('Frequency', $script:frequencyBox.Text, 1.0, 20000.0),
                @('Amplitude', $script:amplitudeBox.Text, 0.0, 100.0),
                @('LingerSeconds', $script:lingerBox.Text, 0.0, 3600.0),
                @('Threshold', $script:thresholdBox.Text, 0.0, 1.0)
            )) {
                $n = 0.0
                if (-not [double]::TryParse([string]$entry[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$n) -or
                    [double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -lt $entry[2] -or $n -gt $entry[3]) {
                    throw ('Invalid value: ' + $entry[0])
                }
                $values[$entry[0]] = $n.ToString($inv)
            }
            $values['DeviceName'] = [string]$script:deviceBox.SelectedValue
            $values['AppName'] = [string]$script:appBox.SelectedValue
            Set-Startup ([bool]$script:autostartBox.IsChecked)
            Write-KeeperSettings $values
            [System.Windows.MessageBox]::Show('設定を保存しました。', 'NZXT Relay Keeper') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, '設定エラー') | Out-Null
        }
    })

    $script:toggleButton.Add_Click({
        if (Is-Monitoring) { Stop-Monitoring } else { Start-Monitoring }
    })
    $showItem.add_Click({ $script:window.Show(); $script:window.Activate() | Out-Null })
    $script:tray.add_DoubleClick({ $script:window.Show(); $script:window.Activate() | Out-Null })
    $monitorItem.add_Click({ if (Is-Monitoring) { Stop-Monitoring } else { Start-Monitoring } })
    $quitItem.add_Click({
        $script:exiting = $true
        $script:window.Close()
    })
    $script:window.Add_Closing({
        param($sender, $e)
        if (-not $script:exiting) {
            $e.Cancel = $true
            $script:window.Hide()
        }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(900)
    $timer.Add_Tick({
        if ($script:themePreference -eq 'System') { Apply-Theme 'System' }
        Update-Status
        if ($script:window.IsVisible -and $script:consoleExpander.IsExpanded) { Update-Log }
    })
    $timer.Start()
    Update-Status
    # Start the engine after the first frame; tray startup never scans apps or reads logs.
    $script:window.Add_ContentRendered({
        if ($script:startupComplete) { return }
        $script:startupComplete = $true
        if ($Minimized) { $script:window.Hide() }
        Start-Monitoring
    })
    $script:application = New-Object System.Windows.Application
    $script:application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
    [void]$script:application.Run($script:window)
} catch {
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'SpeakerKeeper GUI error') | Out-Null
    throw
} finally {
    if ($null -ne $timer) { $timer.Stop() }
    try { Stop-Monitoring } catch { }
    if ($null -ne $script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() }
    if ($null -ne $menu) { $menu.Dispose() }
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
}
