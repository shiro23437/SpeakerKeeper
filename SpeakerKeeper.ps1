param([string]$StopFile = '', [string]$LogFile = '')

# ============================================================
#  SpeakerKeeper
#  他のアプリ(ブラウザ・ゲームなど)から音が出ている間だけ
#  SoundKeeper で小さなサイン波を流し、スピーカーのオートスリープを防ぐ。
#  音が止まってから「余韻時間」が過ぎたら SoundKeeper を止める。
#
#  設定は同じフォルダの settings.txt で変更できます(保存すると自動で反映)。
# ============================================================

$ErrorActionPreference = 'Stop'
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $scriptDir 'settings.txt'
. (Join-Path $scriptDir 'tools\Settings.ps1')

# ---- Optional GUI console logging; direct BAT entrypoints still use stdout ----
function Write-Event([string]$message) {
    $entry = ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message)
    Write-Host $entry
    if ($LogFile -ne '') {
        try {
            $parent = Split-Path -Parent $LogFile
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            # Keep at most the current 1 MiB log and one rotated log.
            if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -ge 1MB) {
                Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
            }
            Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8
        } catch { }
    }
}

# ---- 二重起動防止 ----
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\SpeakerKeeper_SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    Write-Event 'SpeakerKeeper はすでに起動しています。'
    $mutex.Dispose()
    exit
}

try {
# ---- Windowsの音声セッション(アプリごとの音量メーター)を読むための部品 ----
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SpeakerKeeperAudio
{
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IPropertyStore store);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey
    {
        public Guid fmtid;
        public int pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant
    {
        public ushort vt;
        public ushort r1, r2, r3;
        public IntPtr p1;
        public IntPtr p2;
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(IntPtr sessionGuid, int streamFlags, out IntPtr sessionControl);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr sessionGuid, int streamFlags, out IntPtr audioVolume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        // IAudioSessionControl
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(IntPtr name);
        [PreserveSig] int SetDisplayName(IntPtr name, IntPtr ctx);
        [PreserveSig] int GetIconPath(IntPtr path);
        [PreserveSig] int SetIconPath(IntPtr path, IntPtr ctx);
        [PreserveSig] int GetGroupingParam(IntPtr param);
        [PreserveSig] int SetGroupingParam(IntPtr param, IntPtr ctx);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        // IAudioSessionControl2
        [PreserveSig] int GetSessionIdentifier(IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCom { }

    public static class Meter
    {
        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant pvar);

        // 今の既定の出力デバイスの名前(例: スピーカー (Realtek(R) Audio))を返す
        public static string GetDefaultDeviceName()
        {
            object enumObj = new MMDeviceEnumeratorCom();
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)enumObj;
            IMMDevice device = null;
            IPropertyStore store = null;
            try
            {
                if (enumerator.GetDefaultAudioEndpoint(0, 1, out device) != 0 || device == null) return "";
                if (device.OpenPropertyStore(0 /* STGM_READ */, out store) != 0 || store == null) return "";
                PropertyKey key = new PropertyKey();
                key.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); // PKEY_Device_FriendlyName
                key.pid = 14;
                PropVariant v;
                if (store.GetValue(ref key, out v) != 0) return "";
                string name = (v.vt == 31 /* VT_LPWSTR */) ? Marshal.PtrToStringUni(v.p1) : "";
                PropVariantClear(ref v);
                return name ?? "";
            }
            finally
            {
                if (store != null) Marshal.ReleaseComObject(store);
                if (device != null) Marshal.ReleaseComObject(device);
                Marshal.ReleaseComObject(enumObj);
            }
        }

        // 指定したプロセスID以外のアプリが出している音の最大レベル(0〜1)を返す
        public static float GetOtherAppsPeak(HashSet<uint> excludePids, string selectedAppName)
        {
            float max = 0f;
            object enumObj = new MMDeviceEnumeratorCom();
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)enumObj;
            IMMDevice device = null;
            object mgrObj = null;
            IAudioSessionEnumerator sessions = null;
            try
            {
                // 0 = eRender(再生), 1 = eMultimedia
                if (enumerator.GetDefaultAudioEndpoint(0, 1, out device) != 0 || device == null) return 0f;
                Guid iid = typeof(IAudioSessionManager2).GUID;
                if (device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out mgrObj) != 0) return 0f;
                IAudioSessionManager2 mgr = (IAudioSessionManager2)mgrObj;
                if (mgr.GetSessionEnumerator(out sessions) != 0 || sessions == null) return 0f;

                int count;
                sessions.GetCount(out count);
                for (int i = 0; i < count; i++)
                {
                    object s = null;
                    try
                    {
                        sessions.GetSession(i, out s);
                        if (s == null) continue;
                        uint pid = 0;
                        IAudioSessionControl2 ctl = s as IAudioSessionControl2;
                        if (ctl != null) ctl.GetProcessId(out pid);
                        if (excludePids.Contains(pid)) continue;
                        IAudioMeterInformation meter = s as IAudioMeterInformation;
                        if (meter == null) continue;
                        float p;
                        if (meter.GetPeakValue(out p) != 0 || p <= max) continue;
                        // Inspect only processes with audio sessions, rather than scanning
                        // every process on the machine on each polling interval.
                        try
                        {
                            using (var appProcess = System.Diagnostics.Process.GetProcessById((int)pid))
                            {
                                string processName = appProcess.ProcessName;
                                if (processName.StartsWith("SoundKeeper", StringComparison.OrdinalIgnoreCase)) continue;
                                if (!String.IsNullOrWhiteSpace(selectedAppName) &&
                                    !String.Equals(processName, selectedAppName, StringComparison.OrdinalIgnoreCase)) continue;
                            }
                        }
                        catch
                        {
                            // All-app monitoring must still include sessions whose
                            // process name is inaccessible (including system audio).
                            if (!String.IsNullOrWhiteSpace(selectedAppName)) continue;
                        }
                        max = p;
                    }
                    catch { }
                    finally
                    {
                        if (s != null && Marshal.IsComObject(s)) Marshal.ReleaseComObject(s);
                    }
                }
            }
            finally
            {
                if (sessions != null) Marshal.ReleaseComObject(sessions);
                if (mgrObj != null && Marshal.IsComObject(mgrObj)) Marshal.ReleaseComObject(mgrObj);
                if (device != null) Marshal.ReleaseComObject(device);
                Marshal.ReleaseComObject(enumObj);
            }
            return max;
        }
    }
}
'@

# ---- 設定の読み込み ----
function Read-Settings {
    $s = Read-KeeperConfiguration $settingsPath
    $exe = $s.SoundKeeper
    if (-not [System.IO.Path]::IsPathRooted($exe)) { $exe = Join-Path $scriptDir $exe }
    $s.SoundKeeperPath = $exe
    return $s
}

function Get-Inv([double]$v) { $v.ToString([System.Globalization.CultureInfo]::InvariantCulture) }

$keeperProc = $null

$script:nextKeeperAttempt = [datetime]::MinValue
$script:keeperFailure = ''

function Set-KeeperFailure([string]$message) {
    $script:nextKeeperAttempt = [datetime]::UtcNow.AddSeconds(30)
    if ($message -ne $script:keeperFailure) {
        Write-Event ($message + ' Check the SoundKeeper path in settings.txt, download the matching executable from https://veg.by/projects/soundkeeper, and check Windows file permissions. Retry is limited to once every 30 seconds while audio is active.')
        $script:keeperFailure = $message
    }
}

function Start-Keeper($s) {
    if ([datetime]::UtcNow -lt $script:nextKeeperAttempt) { return $null }
    if (-not [System.IO.File]::Exists($s.SoundKeeperPath)) {
        Set-KeeperFailure ('SoundKeeper is missing or inaccessible: ' + $s.SoundKeeperPath)
        return $null
    }
    $argLine = "sine -f $(Get-Inv $s.Frequency) -a $(Get-Inv $s.Amplitude)"
    try {
        $p = Start-Process -FilePath $s.SoundKeeperPath -ArgumentList $argLine -WindowStyle Hidden -PassThru
    } catch {
        Set-KeeperFailure ('Cannot start SoundKeeper: ' + $s.SoundKeeperPath + ' (' + $_.Exception.Message + ')')
        return $null
    }
    if ($script:keeperFailure) { Write-Event 'SoundKeeper is available again.' }
    $script:keeperFailure = ''
    $script:nextKeeperAttempt = [datetime]::MinValue
    Write-Event ("{0:HH:mm:ss}  音を検出 → SoundKeeper 開始 ({1})" -f (Get-Date), $argLine)
    return $p
}

function Stop-Keeper([string]$reason) {
    if ($script:keeperProc -ne $null) {
        try { if (-not $script:keeperProc.HasExited) { $script:keeperProc.Kill() } } catch { }
        $script:keeperProc.Dispose()
        $script:keeperProc = $null
        Write-Event ("{0:HH:mm:ss}  {1} → SoundKeeper 停止" -f (Get-Date), $reason)
    }
}

# ---- メインループ ----
$settings  = Read-Settings
$settingsTime = if ([System.IO.File]::Exists($settingsPath)) { [System.IO.File]::GetLastWriteTimeUtc($settingsPath) } else { $null }
$lastSound = [datetime]::MinValue
$myPid     = [uint32]$PID
$exclude = New-Object 'System.Collections.Generic.HashSet[uint32]'
[void]$exclude.Add($myPid)

Write-Event 'SpeakerKeeper 起動しました。'
Write-Event ("  音: {0}Hz / {1}%   余韻: {2}秒   検出しきい値: {3}" -f `
    (Get-Inv $settings.Frequency), (Get-Inv $settings.Amplitude), $settings.LingerSeconds, (Get-Inv $settings.Threshold))
if ($settings.DeviceName -ne '') {
    Write-Event ("  対象デバイス: 名前に「{0}」を含む出力先のときだけ動作" -f $settings.DeviceName)
} else {
    Write-Event '  対象デバイス: 指定なし(どの出力先でも動作)'
}
Write-Event '  (このウィンドウを閉じると終了します)'
$lastDevice = $null
if (-not [System.IO.File]::Exists($settings.SoundKeeperPath)) {
    Set-KeeperFailure ('SoundKeeper is missing or inaccessible: ' + $settings.SoundKeeperPath)
}

    while ($true) {
        if ($StopFile -ne '' -and (Test-Path -LiteralPath $StopFile)) { break }
        # 設定ファイルが保存し直されたら読み込み直す
        $t = if ([System.IO.File]::Exists($settingsPath)) { [System.IO.File]::GetLastWriteTimeUtc($settingsPath) } else { $null }
        if ($t -ne $settingsTime) {
                $settingsTime = $t
                $settings = Read-Settings
                Write-Event ("{0:HH:mm:ss}  settings.txt を読み込み直しました ({1}Hz / {2}% / 余韻 {3}秒)" -f `
                    (Get-Date), (Get-Inv $settings.Frequency), (Get-Inv $settings.Amplitude), $settings.LingerSeconds)
                Stop-Keeper '設定変更'
                $script:nextKeeperAttempt = [datetime]::MinValue
                $script:keeperFailure = ''
        }

        # 今の出力先が対象デバイスか確認(ヘッドホンなどに切り替えたら止める)
        $device = ''
        try { $device = [SpeakerKeeperAudio.Meter]::GetDefaultDeviceName() } catch { $device = '' }
        if ($device -ne $lastDevice) {
            Stop-Keeper '出力デバイス変更'
            $lastSound = [datetime]::MinValue
            $lastDevice = $device
            Write-Event ("{0:HH:mm:ss}  現在の出力先: {1}" -f (Get-Date), $device)
        }
        $isTarget = ($settings.DeviceName -eq '') -or $device.Contains($settings.DeviceName)
        if (-not $isTarget) {
            Stop-Keeper '対象外のデバイスに切り替わった'
            $lastSound = [datetime]::MinValue
            Start-Sleep -Milliseconds 500
            continue
        }

        # SoundKeeper 自身とこのスクリプトの音は除外して測る
        $exclude.Clear()
        [void]$exclude.Add($myPid)
        if ($null -ne $keeperProc -and -not $keeperProc.HasExited) { [void]$exclude.Add([uint32]$keeperProc.Id) }
        $peak = 0
        try { $peak = [SpeakerKeeperAudio.Meter]::GetOtherAppsPeak($exclude, [string]$settings.AppName) } catch { $peak = 0 }

        if ($null -ne $keeperProc -and $keeperProc.HasExited) {
            $keeperProc.Dispose()
            $keeperProc = $null
            Set-KeeperFailure ('SoundKeeper exited unexpectedly: ' + $settings.SoundKeeperPath)
        }
        $now = Get-Date
        if ($peak -gt $settings.Threshold) {
            $lastSound = $now
            if ($keeperProc -eq $null -or $keeperProc.HasExited) {
                $keeperProc = Start-Keeper $settings
            }
        }
        elseif ($keeperProc -ne $null -and ($now - $lastSound).TotalSeconds -ge $settings.LingerSeconds) {
            Stop-Keeper ("無音が {0} 秒続いた" -f $settings.LingerSeconds)
        }

        Start-Sleep -Milliseconds 250
    }
}
finally {
    try {
        if ($null -ne $script:keeperProc) { Stop-Keeper '終了' }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
