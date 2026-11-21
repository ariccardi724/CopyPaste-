#Requires -Version 5.1
# ClipQueue Final v4 - Rock-Solid Borderless WPF Sequential Clipboard Manager for Windows
# Zero external dependencies: runs natively on Windows 10 / 11 via built-in WPF & PowerShell.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Native Win32 helpers: Low-Level Keyboard Hook (never misses Ctrl+V), Clipboard Seq, & TopMost without focus steal
if (-not ([System.Management.Automation.PSTypeName]'ClipQueueNativeV4').Type) {
    Add-Type @"
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class ClipQueueNativeV4 {
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN     = 0x0100;
    private const int WM_SYSKEYDOWN  = 0x0104;
    private const int VK_CONTROL     = 0x11;
    private const int VK_C           = 0x43;
    private const int VK_V           = 0x56;
    private const int VK_X           = 0x58;

    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private const uint SWP_NOMOVE     = 0x0002;
    private const uint SWP_NOSIZE     = 0x0001;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private static LowLevelKeyboardProc _proc = HookCallback;
    private static IntPtr _hookId = IntPtr.Zero;

    private static int _pasteCount = 0;
    private static long _lastCopyTick = 0;
    private static long _lastPasteTick = 0;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    public static void EnforceTopMostNoActivate(IntPtr hwnd) {
        if (hwnd != IntPtr.Zero) {
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    public static bool InstallKeyboardHook() {
        if (_hookId != IntPtr.Zero) return true;
        using (Process curProcess = Process.GetCurrentProcess())
        using (ProcessModule curModule = curProcess.MainModule) {
            IntPtr hMod = curModule != null ? GetModuleHandle(curModule.ModuleName) : IntPtr.Zero;
            _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, hMod, 0);
        }
        return _hookId != IntPtr.Zero;
    }

    public static void UninstallKeyboardHook() {
        if (_hookId != IntPtr.Zero) {
            UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
        }
    }

    public static int ConsumePasteCount() {
        return Interlocked.Exchange(ref _pasteCount, 0);
    }

    public static bool WasCopyKeyPressedRecently(int withinMs) {
        long last = Interlocked.Read(ref _lastCopyTick);
        if (last == 0) return false;
        long diff = unchecked(Environment.TickCount - (int)last);
        return diff >= 0 && diff <= withinMs;
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN)) {
            int vkCode = Marshal.ReadInt32(lParam);
            bool ctrlDown = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
            if (ctrlDown) {
                if (vkCode == VK_V) {
                    long now = Environment.TickCount;
                    long prev = Interlocked.Read(ref _lastPasteTick);
                    // Ignore key-repeat bounce under 60ms, but capture every distinct Ctrl+V press
                    if (prev == 0 || unchecked((int)now - (int)prev) > 60) {
                        Interlocked.Exchange(ref _lastPasteTick, now);
                        Interlocked.Increment(ref _pasteCount);
                    }
                } else if (vkCode == VK_C || vkCode == VK_X) {
                    Interlocked.Exchange(ref _lastCopyTick, Environment.TickCount);
                }
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }
}

public class ClipItem : INotifyPropertyChanged {
    private string _id;
    private string _text;
    private string _indexLabel;
    private bool _isActive;
    private bool _isFlashed;

    public string Id {
        get { return _id; }
        set { _id = value; OnPropertyChanged("Id"); }
    }

    public string Text {
        get { return _text; }
        set {
            _text = value ?? "";
            OnPropertyChanged("Text");
            OnPropertyChanged("Preview");
        }
    }

    public string Preview {
        get {
            if (string.IsNullOrEmpty(_text)) return "";
            string clean = _text.Replace("\r\n", " ").Replace("\n", " ").Replace("\r", " ").Trim();
            return clean.Length > 90 ? clean.Substring(0, 90) + "..." : clean;
        }
    }

    public string IndexLabel {
        get { return _indexLabel; }
        set { _indexLabel = value; OnPropertyChanged("IndexLabel"); }
    }

    public bool IsActive {
        get { return _isActive; }
        set { _isActive = value; OnPropertyChanged("IsActive"); }
    }

    public bool IsFlashed {
        get { return _isFlashed; }
        set { _isFlashed = value; OnPropertyChanged("IsFlashed"); }
    }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string name) {
        var handler = PropertyChanged;
        if (handler != null) handler(this, new PropertyChangedEventArgs(name));
    }
}
"@
}

# --- Safe Error Logger (prevents silent crashes) ---
$script:logPath = Join-Path $PSScriptRoot "clipqueue_error.log"
function Write-SafeLog {
    param([string]$Message)
    try {
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $script:logPath -Value "[$stamp] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

# --- XAML UI Definition ---
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClipQueue"
        Width="372" Height="500"
        MinWidth="260" MinHeight="180"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ResizeMode="NoResize"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">

    <Window.Resources>
        <!-- Custom Thin Dark ScrollBar -->
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Width" Value="6"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid Background="Transparent" Margin="1,4,1,4">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="{x:Type Thumb}">
                                                <Border Background="#38FFFFFF" CornerRadius="3"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Sleek Header Icon Button Style -->
        <Style x:Key="HeaderIconBtn" TargetType="{x:Type Button}">
            <Setter Property="Width" Value="28"/>
            <Setter Property="Height" Value="26"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#A1A7B8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#20FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#30FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Close Button Hover Red -->
        <Style x:Key="CloseIconBtn" TargetType="{x:Type Button}" BasedOn="{StaticResource HeaderIconBtn}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="Bd" Background="Transparent" CornerRadius="7">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#D93838"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Hover-Reveal Card Action Button -->
        <Style x:Key="CardActionBtn" TargetType="{x:Type Button}">
            <Setter Property="Width" Value="24"/>
            <Setter Property="Height" Value="24"/>
            <Setter Property="Background" Value="#18FFFFFF"/>
            <Setter Property="Foreground" Value="#C8CEDE"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="3,0,0,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#34FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Pill Footer Button -->
        <Style x:Key="FooterBtn" TargetType="{x:Type Button}">
            <Setter Property="Height" Value="30"/>
            <Setter Property="Padding" Value="12,0"/>
            <Setter Property="Background" Value="#18FFFFFF"/>
            <Setter Property="Foreground" Value="#E2E6F0"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#28FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#38FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Primary Accent Button -->
        <Style x:Key="AccentBtn" TargetType="{x:Type Button}" BasedOn="{StaticResource FooterBtn}">
            <Setter Property="Background" Value="#3B82F6"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#2563EB"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1D4ED8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Strip Default ListBoxItem Blue Selection Chrome -->
        <Style x:Key="CleanListItem" TargetType="{x:Type ListBoxItem}">
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Margin" Value="0,0,0,6"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ListBoxItem}">
                        <ContentPresenter/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Invisible Hit-Test Resize Edge/Corner Style -->
        <Style x:Key="EdgeResizeThumb" TargetType="{x:Type Thumb}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border Background="Transparent"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
    <!-- Outer Shadow Shell -->
    <Border x:Name="MainShell"
            Margin="14"
            CornerRadius="14"
            Background="#EE141622"
            BorderBrush="#28FFFFFF"
            BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.58" Color="#000000"/>
        </Border.Effect>

        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="44"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Custom Draggable Title Bar -->
            <Border x:Name="TitleBar"
                    Grid.Row="0"
                    Background="#10FFFFFF"
                    CornerRadius="14,14,0,0"
                    BorderBrush="#16FFFFFF"
                    BorderThickness="0,0,0,1"
                    Padding="12,0,8,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <!-- Left: Brand Dot + Title + Count Pill (or Mini Pill Next-Up Preview Only) -->
                    <Grid Grid.Column="0" VerticalAlignment="Center" Margin="0,0,6,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Ellipse x:Name="CaptureDot" Grid.Column="0" Width="8" Height="8" Fill="#22C55E" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TxtTitle" Grid.Column="1" Text="ClipQueue" Foreground="#F3F5FA"
                                   FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        <Border x:Name="CountBadge" Grid.Column="2" Background="#1EFFFFFF" CornerRadius="6" Padding="6,1" Margin="8,0,0,0" VerticalAlignment="Center">
                            <TextBlock x:Name="TxtCount" Text="0" Foreground="#B4BCCF" FontFamily="Segoe UI" FontSize="11" FontWeight="SemiBold"/>
                        </Border>
                        <TextBlock x:Name="TxtMiniPreview" Grid.Column="3" Text="" Foreground="#EEF1F8"
                                   FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"
                                   Margin="0,0,4,0" TextTrimming="CharacterEllipsis"
                                   Visibility="Collapsed"/>
                    </Grid>

                    <!-- Right: Subtle Icon Badges (Pin, Capture, Collapse, Minimize, Close) -->
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Button x:Name="BtnPin" Style="{StaticResource HeaderIconBtn}" ToolTip="Always on Top: ON" Margin="0,0,2,0">
                            <Path x:Name="IconPin" Data="M16,12V4H17V2H7V4H8V12L6,14V16H11.2V22H12.8V16H18V14L16,12Z"
                                  Fill="#60A5FA" Stretch="Uniform" Width="13" Height="13"/>
                        </Button>

                        <Button x:Name="BtnCapture" Style="{StaticResource HeaderIconBtn}" ToolTip="Auto-Capture: ON" Margin="0,0,2,0">
                            <Path x:Name="IconCapture" Data="M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M12,7A5,5 0 0,1 17,12A5,5 0 0,1 12,17A5,5 0 0,1 7,12A5,5 0 0,1 12,7Z"
                                  Fill="#22C55E" Stretch="Uniform" Width="13" Height="13"/>
                        </Button>

                        <Button x:Name="BtnCollapse" Style="{StaticResource HeaderIconBtn}" ToolTip="Collapse to Mini Pill" Margin="0,0,2,0">
                            <Path x:Name="IconCollapse" Data="M7.41,15.41L12,10.83L16.59,15.41L18,14L12,8L6,14L7.41,15.41Z"
                                  Fill="#A1A7B8" Stretch="Uniform" Width="12" Height="12"/>
                        </Button>

                        <Button x:Name="BtnMinimize" Style="{StaticResource HeaderIconBtn}" ToolTip="Minimize" Margin="0,0,2,0">
                            <Path Data="M20,14H4V10H20" Fill="#A1A7B8" Stretch="Uniform" Width="10" Height="10"/>
                        </Button>

                        <Button x:Name="BtnClose" Style="{StaticResource CloseIconBtn}" ToolTip="Close">
                            <Path Data="M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12L19,6.41Z"
                                  Fill="#A1A7B8" Stretch="Uniform" Width="10" Height="10"/>
                        </Button>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Main Queue List Area -->
            <Grid x:Name="BodyPanel" Grid.Row="1" Margin="10,10,10,6">
                <StackPanel x:Name="EmptyState" VerticalAlignment="Center" HorizontalAlignment="Center" Opacity="0.55">
                    <Path Data="M19,3H14.82C14.4,1.84 13.3,1 12,1C10.7,1 9.6,1.84 9.18,3H5A2,2 0 0,0 3,5V19A2,2 0 0,0 5,21H19A2,2 0 0,0 21,19V5A2,2 0 0,0 19,3M12,3A1,1 0 0,1 13,4A1,1 0 0,1 12,5A1,1 0 0,1 11,4A1,1 0 0,1 12,3Z"
                          Fill="#8E96AB" Stretch="Uniform" Width="28" Height="28" Margin="0,0,0,8"/>
                    <TextBlock Text="Queue is empty" Foreground="#CBD2E1" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Center"/>
                </StackPanel>

                <ListBox x:Name="QueueList"
                         Background="Transparent"
                         BorderThickness="0"
                         AllowDrop="True"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                         ScrollViewer.VerticalScrollBarVisibility="Auto"
                         ItemContainerStyle="{StaticResource CleanListItem}">
                    <ListBox.ItemTemplate>
                        <DataTemplate>
                            <Border x:Name="CardBorder"
                                    CornerRadius="10"
                                    Background="#14FFFFFF"
                                    BorderBrush="#1AFFFFFF"
                                    BorderThickness="1"
                                    Padding="10,9,8,9"
                                    Cursor="Hand">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>

                                    <TextBlock x:Name="NumText"
                                               Grid.Column="0"
                                               Text="{Binding IndexLabel}"
                                               Foreground="#8891A8"
                                               FontFamily="Segoe UI"
                                               FontSize="11.5"
                                               FontWeight="Bold"
                                               VerticalAlignment="Center"
                                               Margin="0,0,9,0"/>

                                    <TextBlock Grid.Column="1"
                                               Text="{Binding Preview}"
                                               Foreground="#EEF1F8"
                                               FontFamily="Segoe UI"
                                               FontSize="12.5"
                                               VerticalAlignment="Center"
                                               TextTrimming="CharacterEllipsis"/>

                                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="6,0,0,0">
                                        <Border x:Name="NextBadge"
                                                Background="#3B82F6"
                                                CornerRadius="5"
                                                Padding="6,2"
                                                Margin="0,0,2,0"
                                                Visibility="Collapsed"
                                                VerticalAlignment="Center">
                                            <TextBlock Text="NEXT" Foreground="#FFFFFF" FontFamily="Segoe UI" FontSize="9.5" FontWeight="Bold"/>
                                        </Border>

                                        <StackPanel x:Name="HoverActions" Orientation="Horizontal" Visibility="Collapsed">
                                            <Button Style="{StaticResource CardActionBtn}" Tag="Edit" ToolTip="Edit">
                                                <Path Data="M20.71,7.04C21.1,6.65 21.1,6 20.71,5.63L18.37,3.29C18,2.9 17.35,2.9 16.96,3.29L15.12,5.12L18.87,8.87M3,17.25V21H6.75L17.81,9.93L14.06,6.18L3,17.25Z"
                                                      Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                                      Stretch="Uniform" Width="11" Height="11"/>
                                            </Button>
                                            <Button Style="{StaticResource CardActionBtn}" Tag="Delete" ToolTip="Delete">
                                                <Path Data="M19,4H15.5L14.5,3H9.5L8.5,4H5V6H19M6,19A2,2 0 0,0 8,21H16A2,2 0 0,0 18,19V7H6V19Z"
                                                      Fill="#F87171"
                                                      Stretch="Uniform" Width="11" Height="11"/>
                                            </Button>
                                        </StackPanel>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <DataTemplate.Triggers>
                                <Trigger SourceName="CardBorder" Property="IsMouseOver" Value="True">
                                    <Setter TargetName="CardBorder" Property="Background" Value="#20FFFFFF"/>
                                    <Setter TargetName="CardBorder" Property="BorderBrush" Value="#34FFFFFF"/>
                                    <Setter TargetName="HoverActions" Property="Visibility" Value="Visible"/>
                                </Trigger>

                                <DataTrigger Binding="{Binding IsActive}" Value="True">
                                    <Setter TargetName="CardBorder" Property="Background" Value="#2A3B82F6"/>
                                    <Setter TargetName="CardBorder" Property="BorderBrush" Value="#993B82F6"/>
                                    <Setter TargetName="NumText" Property="Foreground" Value="#93C5FD"/>
                                    <Setter TargetName="NextBadge" Property="Visibility" Value="Visible"/>
                                </DataTrigger>

                                <DataTrigger Binding="{Binding IsFlashed}" Value="True">
                                    <Setter TargetName="CardBorder" Property="Background" Value="#3A22C55E"/>
                                    <Setter TargetName="CardBorder" Property="BorderBrush" Value="#CC22C55E"/>
                                </DataTrigger>
                            </DataTemplate.Triggers>
                        </DataTemplate>
                    </ListBox.ItemTemplate>
                </ListBox>
            </Grid>

            <!-- Inline Edit / Add Drawer -->
            <Border x:Name="EditDrawer"
                    Grid.Row="2"
                    Background="#1AFFFFFF"
                    BorderBrush="#24FFFFFF"
                    BorderThickness="0,1,0,0"
                    Padding="10"
                    Visibility="Collapsed">
                <StackPanel>
                    <TextBox x:Name="TxtEdit"
                             Height="68"
                             AcceptsReturn="True"
                             TextWrapping="Wrap"
                             VerticalScrollBarVisibility="Auto"
                             Background="#CC0E101A"
                             Foreground="#F3F5FA"
                             CaretBrush="#60A5FA"
                             BorderBrush="#33FFFFFF"
                             BorderThickness="1"
                             Padding="8,6"
                             FontFamily="Segoe UI"
                             FontSize="12.5"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
                        <Button x:Name="BtnCancelEdit" Content="Cancel" Style="{StaticResource FooterBtn}" Height="26" Padding="10,0" Margin="0,0,6,0"/>
                        <Button x:Name="BtnSaveEdit" Content="Save" Style="{StaticResource AccentBtn}" Height="26" Padding="14,0"/>
                    </StackPanel>
                </StackPanel>
            </Border>

            <!-- Clean Bottom Action Bar -->
            <Border x:Name="FooterBar"
                    Grid.Row="3"
                    Background="#0BFFFFFF"
                    CornerRadius="0,0,14,14"
                    BorderBrush="#14FFFFFF"
                    BorderThickness="0,1,0,0"
                    Padding="10,8,10,8">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <Button x:Name="BtnAdd" Grid.Column="0" Content="+ Add" Style="{StaticResource FooterBtn}" Margin="0,0,6,0"/>
                    <Button x:Name="BtnClear" Grid.Column="1" Content="Clear" Style="{StaticResource FooterBtn}" Foreground="#9CA3B8"/>
                    <Button x:Name="BtnNext" Grid.Column="3" Content="Next  &#x2192;" Style="{StaticResource AccentBtn}" Padding="16,0"/>
                </Grid>
            </Border>

            <!-- Subtle Visual Bottom-Right Resize Grip Indicator -->
            <Path x:Name="ResizeGripVisual"
                  Grid.Row="3"
                  Data="M 10,2 L 2,10 M 10,6 L 6,10"
                  Stroke="#48FFFFFF"
                  StrokeThickness="1.3"
                  StrokeStartLineCap="Round"
                  StrokeEndLineCap="Round"
                  Width="11" Height="11"
                  HorizontalAlignment="Right"
                  VerticalAlignment="Bottom"
                  Margin="0,0,5,5"
                  IsHitTestVisible="False"/>
        </Grid>
    </Border>

    <!-- 8-Directional Edge & Corner Resize Handles -->
    <Grid Margin="10">
        <Thumb x:Name="ResizeLeft"   Style="{StaticResource EdgeResizeThumb}" Width="7"  HorizontalAlignment="Left"   VerticalAlignment="Stretch" Margin="0,10,0,10" Cursor="SizeWE"/>
        <Thumb x:Name="ResizeRight"  Style="{StaticResource EdgeResizeThumb}" Width="7"  HorizontalAlignment="Right"  VerticalAlignment="Stretch" Margin="0,10,0,10" Cursor="SizeWE"/>
        <Thumb x:Name="ResizeTop"    Style="{StaticResource EdgeResizeThumb}" Height="7" HorizontalAlignment="Stretch" VerticalAlignment="Top"    Margin="10,0,10,0" Cursor="SizeNS"/>
        <Thumb x:Name="ResizeBottom" Style="{StaticResource EdgeResizeThumb}" Height="7" HorizontalAlignment="Stretch" VerticalAlignment="Bottom" Margin="10,0,10,0" Cursor="SizeNS"/>

        <Thumb x:Name="ResizeTopLeft"     Style="{StaticResource EdgeResizeThumb}" Width="12" Height="12" HorizontalAlignment="Left"  VerticalAlignment="Top"    Cursor="SizeNWSE"/>
        <Thumb x:Name="ResizeTopRight"    Style="{StaticResource EdgeResizeThumb}" Width="12" Height="12" HorizontalAlignment="Right" VerticalAlignment="Top"    Cursor="SizeNESW"/>
        <Thumb x:Name="ResizeBottomLeft"  Style="{StaticResource EdgeResizeThumb}" Width="12" Height="12" HorizontalAlignment="Left"  VerticalAlignment="Bottom" Cursor="SizeNESW"/>
        <Thumb x:Name="ResizeBottomRight" Style="{StaticResource EdgeResizeThumb}" Width="14" Height="14" HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE"/>
    </Grid>
    </Grid>
</Window>
"@

# Load XAML
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Global WPF Dispatcher crash guard (prevents silent exits)
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    Write-SafeLog "DispatcherException: $($e.Exception.ToString())"
    $e.Handled = $true
})

# Load custom app icon
$iconPath = Join-Path $PSScriptRoot "ClipQueue.ico"
if (Test-Path $iconPath) {
    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath))
    } catch {}
}

# Position near top-right of primary screen
$workArea = [System.Windows.SystemParameters]::WorkArea
$window.Left = $workArea.Right - $window.Width - 16
$window.Top  = $workArea.Top + 48

# Bind Named Controls
$mainShell         = $window.FindName("MainShell")
$titleBar          = $window.FindName("TitleBar")
$captureDot        = $window.FindName("CaptureDot")
$txtTitle          = $window.FindName("TxtTitle")
$countBadge        = $window.FindName("CountBadge")
$txtCount          = $window.FindName("TxtCount")
$txtMiniPreview    = $window.FindName("TxtMiniPreview")
$btnPin            = $window.FindName("BtnPin")
$iconPin           = $window.FindName("IconPin")
$btnCapture        = $window.FindName("BtnCapture")
$iconCapture       = $window.FindName("IconCapture")
$btnCollapse       = $window.FindName("BtnCollapse")
$iconCollapse      = $window.FindName("IconCollapse")
$btnMinimize       = $window.FindName("BtnMinimize")
$btnClose          = $window.FindName("BtnClose")
$bodyPanel         = $window.FindName("BodyPanel")
$emptyState        = $window.FindName("EmptyState")
$queueList         = $window.FindName("QueueList")
$editDrawer        = $window.FindName("EditDrawer")
$txtEdit           = $window.FindName("TxtEdit")
$btnSaveEdit       = $window.FindName("BtnSaveEdit")
$btnCancelEdit     = $window.FindName("BtnCancelEdit")
$footerBar         = $window.FindName("FooterBar")
$btnAdd            = $window.FindName("BtnAdd")
$btnClear          = $window.FindName("BtnClear")
$btnNext           = $window.FindName("BtnNext")
$resizeGripVisual  = $window.FindName("ResizeGripVisual")
$resizeLeft        = $window.FindName("ResizeLeft")
$resizeRight       = $window.FindName("ResizeRight")
$resizeTop         = $window.FindName("ResizeTop")
$resizeBottom      = $window.FindName("ResizeBottom")
$resizeTopLeft     = $window.FindName("ResizeTopLeft")
$resizeTopRight    = $window.FindName("ResizeTopRight")
$resizeBottomLeft  = $window.FindName("ResizeBottomLeft")
$resizeBottomRight = $window.FindName("ResizeBottomRight")

# --- State ---
$script:items            = New-Object 'System.Collections.ObjectModel.ObservableCollection[ClipItem]'
$queueList.ItemsSource   = $script:items

$script:activeIndex      = -1
$script:lastClipboard    = ""
$script:lastClipSeq      = [ClipQueueNativeV4]::GetClipboardSequenceNumber()
$script:lastWrittenText  = ""
$script:lastWrittenAt    = [DateTime]::MinValue
$script:lastWrittenSeq   = [uint32]0
$script:lastCapturedText = ""
$script:lastCapturedAt   = [DateTime]::MinValue
$script:isWritingClip    = $false
$script:pendingPrimeText = $null
$script:primeRetriesLeft = 0
$script:isPinned         = $true
$script:isCapturing      = $true
$script:isCollapsed      = $false
$script:expandedHeight   = 500
$script:expandedWidth    = 372
$script:suppressSelect   = $false
$script:editingItem      = $null
$script:isAddingNew      = $false
$script:dragItem         = $null
$script:dragStartPt      = [System.Windows.Point]::new(0, 0)
$script:windowHandle     = [IntPtr]::Zero
$script:hwndSource       = $null
$script:trayIcon         = $null

$brushBlue  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#60A5FA")
$brushGreen = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#22C55E")
$brushMuted = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6B7280")

# Seed lastClipboard so whatever is already on the clipboard at startup is NOT auto-captured
try {
    if ([System.Windows.Clipboard]::ContainsText()) {
        $script:lastClipboard = [System.Windows.Clipboard]::GetText()
    }
} catch {}

# --- Safe Tree Helper (handles Run / ContentElement without crashing!) ---
function Get-SafeParent {
    param($obj)
    if ($null -eq $obj) { return $null }
    try {
        if ($obj -is [System.Windows.Media.Visual] -or $obj -is [System.Windows.Media.Media3D.Visual3D]) {
            return [System.Windows.Media.VisualTreeHelper]::GetParent($obj)
        }
        if ($obj -is [System.Windows.DependencyObject]) {
            return [System.Windows.LogicalTreeHelper]::GetParent($obj)
        }
    } catch {}
    return $null
}

function Find-AncestorButton {
    param($depObj)
    $cur = $depObj
    while ($null -ne $cur) {
        if ($cur -is [System.Windows.Controls.Button]) { return $cur }
        $cur = Get-SafeParent $cur
    }
    return $null
}

function Get-AncestorListBoxItem {
    param($depObj)
    $cur = $depObj
    while ($null -ne $cur) {
        if ($cur -is [System.Windows.Controls.ListBoxItem]) { return $cur }
        $cur = Get-SafeParent $cur
    }
    return $null
}

# --- Reliable Clipboard Write with Async Retry ---
function Try-WriteClipboardNow {
    param([string]$Text)
    $script:isWritingClip = $true
    $ok = $false
    for ($i = 0; $i -lt 5; $i++) {
        try {
            [System.Windows.Clipboard]::SetDataObject($Text, $true)
            $seq = [ClipQueueNativeV4]::GetClipboardSequenceNumber()
            $script:lastClipboard   = $Text
            $script:lastWrittenText = $Text
            $script:lastWrittenAt   = [DateTime]::UtcNow
            $script:lastWrittenSeq  = $seq
            $script:lastClipSeq     = $seq
            $ok = $true
            break
        } catch {
            Start-Sleep -Milliseconds 25
        }
    }
    $script:isWritingClip = $false
    return $ok
}

function Set-ClipboardSafe {
    param([string]$Text)
    if (Try-WriteClipboardNow -Text $Text) {
        $script:pendingPrimeText = $null
        $script:primeRetriesLeft = 0
        $primeRetryTimer.Stop()
        return $true
    }
    # Another app still has the clipboard locked; retry cleanly in background without freezing UI
    $script:pendingPrimeText = $Text
    $script:primeRetriesLeft = 10
    $primeRetryTimer.Stop()
    $primeRetryTimer.Start()
    return $false
}

function Ensure-OnScreen {
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($window.Left -lt ($wa.Left - 80) -or $window.Left -gt ($wa.Right - 60)) {
            $window.Left = $wa.Right - $window.Width - 16
        }
        if ($window.Top -lt ($wa.Top - 20) -or $window.Top -gt ($wa.Bottom - 60)) {
            $window.Top = $wa.Top + 48
        }
    } catch {}
}

function Bring-ToFront {
    try {
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            $window.WindowState = [System.Windows.WindowState]::Normal
        }
        Ensure-OnScreen
        $window.Show()
        $window.Topmost = $false
        $window.Topmost = $script:isPinned
        [void]$window.Activate()
    } catch {}
}

function Sync-UIState {
    $count = $script:items.Count
    $emptyState.Visibility = if ($count -eq 0) { "Visible" } else { "Collapsed" }

    for ($i = 0; $i -lt $count; $i++) {
        $script:items[$i].IndexLabel = "$($i + 1)."
        $script:items[$i].IsActive   = ($i -eq $script:activeIndex)
    }

    if ($count -eq 0) {
        $txtCount.Text = "0"
        $txtMiniPreview.Text = ""
    } elseif ($script:activeIndex -ge 0 -and $script:activeIndex -lt $count) {
        $txtCount.Text = "$($script:activeIndex + 1)/$count"
        $txtMiniPreview.Text = $script:items[$script:activeIndex].Preview
    } else {
        $txtCount.Text = "0"
        $txtMiniPreview.Text = ""
    }

    $script:suppressSelect = $true
    if ($script:activeIndex -ge 0 -and $script:activeIndex -lt $count) {
        $queueList.SelectedIndex = $script:activeIndex
        $queueList.ScrollIntoView($script:items[$script:activeIndex])
    } else {
        $queueList.SelectedIndex = -1
    }
    $script:suppressSelect = $false
}

function Prime-ActiveItem {
    if ($script:activeIndex -ge 0 -and $script:activeIndex -lt $script:items.Count) {
        [void](Set-ClipboardSafe -Text $script:items[$script:activeIndex].Text)
    }
    Sync-UIState
}

function Consume-PastedItem {
    if ($script:items.Count -eq 0) { return }
    if ($script:activeIndex -ge 0 -and $script:activeIndex -lt $script:items.Count) {
        $pastedText = $script:items[$script:activeIndex].Text
        $script:items.RemoveAt($script:activeIndex)

        if ($script:items.Count -eq 0) {
            # Queue is now empty: keep lastClipboard = pastedText & lock seq so it is NEVER ghost re-added!
            $script:activeIndex      = -1
            $script:pendingPrimeText = $null
            $primeRetryTimer.Stop()
            $script:lastClipboard    = $pastedText
            $script:lastClipSeq      = [ClipQueueNativeV4]::GetClipboardSequenceNumber()
            Sync-UIState
        } else {
            if ($script:activeIndex -ge $script:items.Count) {
                $script:activeIndex = 0
            }
            Prime-ActiveItem
        }
    }
}

function Advance-Queue {
    if ($script:items.Count -eq 0) { return }
    if ($script:activeIndex -ge 0 -and $script:activeIndex -lt $script:items.Count) {
        if ($script:activeIndex + 1 -lt $script:items.Count) {
            $script:activeIndex++
        } else {
            $script:activeIndex = 0
        }
        Prime-ActiveItem
    }
}

function Check-ClipboardChange {
    if (-not $script:isCapturing -or $script:isWritingClip) { return }

    $seq = [ClipQueueNativeV4]::GetClipboardSequenceNumber()
    if ($seq -eq $script:lastClipSeq -or $seq -eq $script:lastWrittenSeq) { return }

    try {
        if (-not [System.Windows.Clipboard]::ContainsText()) {
            $script:lastClipSeq = $seq
            return
        }

        $current = [System.Windows.Clipboard]::GetText()
        $script:lastClipSeq = $seq

        if ([string]::IsNullOrEmpty($current)) { return }

        # Ignore delayed notifications caused by our own Set-ClipboardSafe write
        $msSinceWrite = ([DateTime]::UtcNow - $script:lastWrittenAt).TotalMilliseconds
        if ($current -eq $script:lastWrittenText -and $msSinceWrite -lt 1200) {
            return
        }

        # Ignore double-fires from apps (Chrome/Word/Excel/EMR) for a single Ctrl+C
        $msSinceCap = ([DateTime]::UtcNow - $script:lastCapturedAt).TotalMilliseconds
        if ($current -eq $script:lastCapturedText -and $msSinceCap -lt 900) {
            return
        }

        # If clipboard text equals what we already knew was on the clipboard (e.g. idle noise / clipboard history),
        # ONLY accept it if the user genuinely pressed Ctrl+C / Ctrl+X within the last 1.5 seconds.
        if ($current -eq $script:lastClipboard) {
            if (-not [ClipQueueNativeV4]::WasCopyKeyPressedRecently(1500)) {
                return
            }
        }

        $script:lastClipboard    = $current
        $script:lastCapturedText = $current
        $script:lastCapturedAt   = [DateTime]::UtcNow

        $newItem = New-Object ClipItem
        $newItem.Id   = [guid]::NewGuid().ToString()
        $newItem.Text = $current
        $script:items.Add($newItem)

        if ($script:activeIndex -lt 0 -or $script:activeIndex -ge ($script:items.Count - 1)) {
            $script:activeIndex = $script:items.Count - 1
        }
        Prime-ActiveItem
    } catch {
        # Clipboard momentarily locked by source app; do NOT update lastClipSeq so the next tick retries cleanly
    }
}

function Open-EditDrawer {
    param([ClipItem]$Item, [bool]$IsNew = $false)
    if ($script:isCollapsed) { Toggle-Collapse }
    $script:isAddingNew = $IsNew
    $script:editingItem = $Item
    $txtEdit.Text = if ($IsNew -or -not $Item) { "" } else { $Item.Text }
    $editDrawer.Visibility = "Visible"
    $txtEdit.Focus()
    $txtEdit.CaretIndex = $txtEdit.Text.Length
}

function Close-EditDrawer {
    $editDrawer.Visibility = "Collapsed"
    $script:editingItem = $null
    $script:isAddingNew = $false
}

function Save-EditDrawer {
    $val = $txtEdit.Text
    if ([string]::IsNullOrWhiteSpace($val)) {
        Close-EditDrawer
        return
    }
    if ($script:isAddingNew) {
        $newItem = New-Object ClipItem
        $newItem.Id   = [guid]::NewGuid().ToString()
        $newItem.Text = $val
        $script:items.Add($newItem)
        if ($script:activeIndex -lt 0 -or $script:activeIndex -ge ($script:items.Count - 1)) {
            $script:activeIndex = $script:items.Count - 1
        }
        Prime-ActiveItem
    } elseif ($script:editingItem) {
        $script:editingItem.Text = $val
        $idx = $script:items.IndexOf($script:editingItem)
        if ($idx -eq $script:activeIndex) {
            Prime-ActiveItem
        } else {
            Sync-UIState
        }
    }
    Close-EditDrawer
}

function Remove-ClipItem {
    param([ClipItem]$Item)
    if (-not $Item) { return }
    $idx = $script:items.IndexOf($Item)
    if ($idx -lt 0) { return }

    $wasActive = ($idx -eq $script:activeIndex)
    $script:items.RemoveAt($idx)

    if ($script:items.Count -eq 0) {
        $script:activeIndex = -1
        $script:lastClipSeq = [ClipQueueNativeV4]::GetClipboardSequenceNumber()
        Sync-UIState
    } elseif ($idx -lt $script:activeIndex) {
        $script:activeIndex--
        Sync-UIState
    } elseif ($wasActive) {
        if ($script:activeIndex -ge $script:items.Count) {
            $script:activeIndex = $script:items.Count - 1
        }
        Prime-ActiveItem
    } else {
        Sync-UIState
    }
}

function Toggle-Collapse {
    $script:isCollapsed = -not $script:isCollapsed
    if ($script:isCollapsed) {
        $script:expandedHeight = $window.Height
        $script:expandedWidth  = $window.Width
        Close-EditDrawer
        $bodyPanel.Visibility         = "Collapsed"
        $footerBar.Visibility         = "Collapsed"
        $resizeGripVisual.Visibility  = "Collapsed"
        $resizeTop.Visibility         = "Collapsed"
        $resizeBottom.Visibility      = "Collapsed"
        $resizeTopLeft.Visibility     = "Collapsed"
        $resizeTopRight.Visibility    = "Collapsed"
        $resizeBottomLeft.Visibility  = "Collapsed"
        $resizeBottomRight.Visibility = "Collapsed"
        $txtTitle.Visibility          = "Collapsed"
        $countBadge.Visibility        = "Collapsed"
        $txtMiniPreview.Visibility    = "Visible"
        $titleBar.CornerRadius        = New-Object System.Windows.CornerRadius(14)
        $titleBar.BorderThickness     = New-Object System.Windows.Thickness(0)
        $window.MinHeight = 72
        $window.Height    = 72
        $btnCollapse.ToolTip = "Expand Queue"
        $iconCollapse.Data = [System.Windows.Media.Geometry]::Parse("M7.41,8.58L12,13.17L16.59,8.58L18,10L12,16L6,10L7.41,8.58Z")
    } else {
        $bodyPanel.Visibility         = "Visible"
        $footerBar.Visibility         = "Visible"
        $resizeGripVisual.Visibility  = "Visible"
        $resizeTop.Visibility         = "Visible"
        $resizeBottom.Visibility      = "Visible"
        $resizeTopLeft.Visibility     = "Visible"
        $resizeTopRight.Visibility    = "Visible"
        $resizeBottomLeft.Visibility  = "Visible"
        $resizeBottomRight.Visibility = "Visible"
        $txtTitle.Visibility          = "Visible"
        $countBadge.Visibility        = "Visible"
        $txtMiniPreview.Visibility    = "Collapsed"
        $titleBar.CornerRadius        = New-Object System.Windows.CornerRadius(14,14,0,0)
        $titleBar.BorderThickness     = New-Object System.Windows.Thickness(0,0,0,1)
        $window.MinHeight = 180
        $window.Height    = $script:expandedHeight
        $window.Width     = $script:expandedWidth
        $btnCollapse.ToolTip = "Collapse to Mini Pill"
        $iconCollapse.Data = [System.Windows.Media.Geometry]::Parse("M7.41,15.41L12,10.83L16.59,15.41L18,14L12,8L6,14L7.41,15.41Z")
    }
}

# --- Window Drag & 8-Directional Resize ---
$titleBar.Add_MouseLeftButtonDown({
    param($sender, $e)
    try {
        if (Find-AncestorButton $e.OriginalSource) { return }
        if ($e.ClickCount -eq 2) {
            Toggle-Collapse
        } elseif ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            $window.DragMove()
        }
    } catch {}
})

function Resize-WindowEdge {
    param(
        [double]$dLeft = 0,
        [double]$dTop = 0,
        [double]$dRight = 0,
        [double]$dBottom = 0
    )
    try {
        if ($dLeft -ne 0) {
            $newW = $window.Width - $dLeft
            if ($newW -lt $window.MinWidth) {
                $dLeft = $window.Width - $window.MinWidth
                $newW  = $window.MinWidth
            }
            $window.Left  += $dLeft
            $window.Width  = $newW
        }
        if ($dRight -ne 0) {
            $newW = $window.Width + $dRight
            if ($newW -lt $window.MinWidth) { $newW = $window.MinWidth }
            $window.Width = $newW
        }
        if (-not $script:isCollapsed) {
            if ($dTop -ne 0) {
                $newH = $window.Height - $dTop
                if ($newH -lt $window.MinHeight) {
                    $dTop = $window.Height - $window.MinHeight
                    $newH = $window.MinHeight
                }
                $window.Top    += $dTop
                $window.Height  = $newH
            }
            if ($dBottom -ne 0) {
                $newH = $window.Height + $dBottom
                if ($newH -lt $window.MinHeight) { $newH = $window.MinHeight }
                $window.Height = $newH
            }
            $script:expandedHeight = $window.Height
        }
        $script:expandedWidth = $window.Width
    } catch {}
}

$resizeLeft.Add_DragDelta({        param($s, $e) Resize-WindowEdge -dLeft $e.HorizontalChange })
$resizeRight.Add_DragDelta({       param($s, $e) Resize-WindowEdge -dRight $e.HorizontalChange })
$resizeTop.Add_DragDelta({         param($s, $e) Resize-WindowEdge -dTop $e.VerticalChange })
$resizeBottom.Add_DragDelta({      param($s, $e) Resize-WindowEdge -dBottom $e.VerticalChange })
$resizeTopLeft.Add_DragDelta({     param($s, $e) Resize-WindowEdge -dLeft $e.HorizontalChange -dTop $e.VerticalChange })
$resizeTopRight.Add_DragDelta({    param($s, $e) Resize-WindowEdge -dRight $e.HorizontalChange -dTop $e.VerticalChange })
$resizeBottomLeft.Add_DragDelta({  param($s, $e) Resize-WindowEdge -dLeft $e.HorizontalChange -dBottom $e.VerticalChange })
$resizeBottomRight.Add_DragDelta({ param($s, $e) Resize-WindowEdge -dRight $e.HorizontalChange -dBottom $e.VerticalChange })

# --- Header Buttons ---
$btnPin.Add_Click({
    $script:isPinned = -not $script:isPinned
    $window.Topmost  = $script:isPinned
    if ($script:isPinned) {
        $iconPin.Fill   = $brushBlue
        $btnPin.ToolTip = "Always on Top: ON"
        if ($script:windowHandle -ne [IntPtr]::Zero) {
            [ClipQueueNativeV4]::EnforceTopMostNoActivate($script:windowHandle)
        }
    } else {
        $iconPin.Fill   = $brushMuted
        $btnPin.ToolTip = "Always on Top: OFF"
    }
})

$btnCapture.Add_Click({
    $script:isCapturing = -not $script:isCapturing
    if ($script:isCapturing) {
        $iconCapture.Fill   = $brushGreen
        $captureDot.Fill    = $brushGreen
        $btnCapture.ToolTip = "Auto-Capture: ON"
        $script:lastClipSeq = [ClipQueueNativeV4]::GetClipboardSequenceNumber()
        try {
            if ([System.Windows.Clipboard]::ContainsText()) {
                $script:lastClipboard = [System.Windows.Clipboard]::GetText()
            }
        } catch {}
    } else {
        $iconCapture.Fill   = $brushMuted
        $captureDot.Fill    = $brushMuted
        $btnCapture.ToolTip = "Auto-Capture: OFF (Paused)"
    }
})

$btnCollapse.Add_Click({ Toggle-Collapse })
$btnMinimize.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$btnClose.Add_Click({ $window.Close() })

# --- Footer & Edit Drawer Buttons ---
$btnAdd.Add_Click({ Open-EditDrawer -Item $null -IsNew $true })
$btnClear.Add_Click({
    $script:items.Clear()
    $script:activeIndex = -1
    $script:pendingPrimeText = $null
    $primeRetryTimer.Stop()
    Close-EditDrawer
    $script:lastClipSeq = [ClipQueueNativeV4]::GetClipboardSequenceNumber()
    try {
        if ([System.Windows.Clipboard]::ContainsText()) {
            $script:lastClipboard = [System.Windows.Clipboard]::GetText()
        }
    } catch {}
    Sync-UIState
})
$btnNext.Add_Click({ Advance-Queue })
$btnSaveEdit.Add_Click({ Save-EditDrawer })
$btnCancelEdit.Add_Click({ Close-EditDrawer })

$txtEdit.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter -and
        ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        $e.Handled = $true
        Save-EditDrawer
    } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
        $e.Handled = $true
        Close-EditDrawer
    }
})

# --- Hover-Reveal Card Action Buttons (Safe Visual/Logical Walk) ---
$queueList.AddHandler(
    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        try {
            $btn = Find-AncestorButton $e.OriginalSource
            if ($btn -and $btn.Tag) {
                $e.Handled = $true
                $item = $btn.DataContext -as [ClipItem]
                if ($btn.Tag -eq "Edit" -and $item) {
                    Open-EditDrawer -Item $item -IsNew $false
                } elseif ($btn.Tag -eq "Delete" -and $item) {
                    Remove-ClipItem -Item $item
                }
            }
        } catch { Write-SafeLog "CardActionClick: $_" }
    }
)

# --- ListBox Selection, Double-Click Edit & Drag-and-Drop Reorder ---
$queueList.Add_SelectionChanged({
    if ($script:suppressSelect) { return }
    if ($queueList.SelectedIndex -ge 0 -and $queueList.SelectedIndex -lt $script:items.Count) {
        $script:activeIndex = $queueList.SelectedIndex
        Prime-ActiveItem
    }
})

$queueList.Add_MouseDoubleClick({
    param($sender, $e)
    try {
        if (Find-AncestorButton $e.OriginalSource) { return }
        if ($queueList.SelectedItem -is [ClipItem]) {
            Open-EditDrawer -Item $queueList.SelectedItem -IsNew $false
        }
    } catch {}
})

$queueList.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    try {
        if (Find-AncestorButton $e.OriginalSource) {
            $script:dragItem = $null
            return
        }
        $script:dragStartPt = $e.GetPosition($queueList)
        $lbi = Get-AncestorListBoxItem $e.OriginalSource
        $script:dragItem = if ($lbi) { $lbi.DataContext -as [ClipItem] } else { $null }
    } catch {
        $script:dragItem = $null
    }
})

$queueList.Add_PreviewMouseMove({
    param($sender, $e)
    try {
        if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed -and $script:dragItem) {
            $pos = $e.GetPosition($queueList)
            $dx = [Math]::Abs($pos.X - $script:dragStartPt.X)
            $dy = [Math]::Abs($pos.Y - $script:dragStartPt.Y)
            if ($dx -gt 6 -or $dy -gt 6) {
                $itemToDrag = $script:dragItem
                $script:dragItem = $null
                [void][System.Windows.DragDrop]::DoDragDrop($queueList, $itemToDrag, [System.Windows.DragDropEffects]::Move)
            }
        }
    } catch {
        $script:dragItem = $null
    }
})

$queueList.Add_DragOver({
    param($sender, $e)
    $e.Effects = [System.Windows.DragDropEffects]::Move
    $e.Handled = $true
})

$queueList.Add_Drop({
    param($sender, $e)
    try {
        $dropped = $e.Data.GetData([ClipItem])
        if (-not $dropped) { return }

        $targetLbi = Get-AncestorListBoxItem $e.OriginalSource
        $oldIdx = $script:items.IndexOf($dropped)
        $newIdx = if ($targetLbi) { $script:items.IndexOf($targetLbi.DataContext) } else { $script:items.Count - 1 }

        if ($oldIdx -ge 0 -and $newIdx -ge 0 -and $oldIdx -ne $newIdx) {
            $activeId = $null
            if ($script:activeIndex -ge 0 -and $script:activeIndex -lt $script:items.Count) {
                $activeId = $script:items[$script:activeIndex].Id
            }

            $script:items.Move($oldIdx, $newIdx)

            if ($activeId) {
                for ($i = 0; $i -lt $script:items.Count; $i++) {
                    if ($script:items[$i].Id -eq $activeId) {
                        $script:activeIndex = $i
                        break
                    }
                }
            }
            Prime-ActiveItem
        }
    } catch { Write-SafeLog "Drop: $_" }
})

# --- Timers ---
# 1. Backup clipboard check timer (250ms) alongside WM_CLIPBOARDUPDATE
$clipTimer = New-Object System.Windows.Threading.DispatcherTimer
$clipTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$clipTimer.Add_Tick({ Check-ClipboardChange })

# 2. Retry timer if clipboard was momentarily locked during Prime-ActiveItem
$primeRetryTimer = New-Object System.Windows.Threading.DispatcherTimer
$primeRetryTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$primeRetryTimer.Add_Tick({
    if ($null -eq $script:pendingPrimeText -or $script:primeRetriesLeft -le 0) {
        $primeRetryTimer.Stop()
        return
    }
    $script:primeRetriesLeft--
    if (Try-WriteClipboardNow -Text $script:pendingPrimeText) {
        $script:pendingPrimeText = $null
        $script:primeRetriesLeft = 0
        $primeRetryTimer.Stop()
    }
})

# 3. Delayed consume timer (160ms after Ctrl+V so target app finishes pasting)
$advanceTimer = New-Object System.Windows.Threading.DispatcherTimer
$advanceTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$advanceTimer.Add_Tick({
    $advanceTimer.Stop()
    Consume-PastedItem
})

# 4. Low-level keyboard hook event pump (25ms, reads atomic counter set by WH_KEYBOARD_LL)
$keyTimer = New-Object System.Windows.Threading.DispatcherTimer
$keyTimer.Interval = [TimeSpan]::FromMilliseconds(25)
$keyTimer.Add_Tick({
    $pastes = [ClipQueueNativeV4]::ConsumePasteCount()
    if ($pastes -gt 0 -and -not $txtEdit.IsKeyboardFocused) {
        if ($script:activeIndex -ge 0 -and $script:activeIndex -lt $script:items.Count) {
            # If a previous paste was still waiting to consume, consume it immediately so rapid Ctrl+V never drops items
            if ($advanceTimer.IsEnabled) {
                $advanceTimer.Stop()
                Consume-PastedItem
            }
            if ($script:activeIndex -ge 0 -and $script:activeIndex -lt $script:items.Count) {
                $advanceTimer.Start()
            }
        }
    }
})

# 5. Gentle Always-on-Top watchdog (keeps pinned window above other apps without stealing focus)
$topmostTimer = New-Object System.Windows.Threading.DispatcherTimer
$topmostTimer.Interval = [TimeSpan]::FromSeconds(2)
$topmostTimer.Add_Tick({
    if ($script:isPinned -and $window.WindowState -ne [System.Windows.WindowState]::Minimized -and $script:windowHandle -ne [IntPtr]::Zero) {
        [ClipQueueNativeV4]::EnforceTopMostNoActivate($script:windowHandle)
    }
})

# --- System Tray Icon (so ClipQueue can never go missing) ---
function Initialize-TrayIcon {
    try {
        $tray = New-Object System.Windows.Forms.NotifyIcon
        if (Test-Path $iconPath) {
            $tray.Icon = New-Object System.Drawing.Icon($iconPath)
        } else {
            $tray.Icon = [System.Drawing.SystemIcons]::Application
        }
        $tray.Text = "ClipQueue (Click to show)"
        $tray.Visible = $true

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $miShow = $menu.Items.Add("Show / Bring to Front")
        $miShow.Add_Click({ Bring-ToFront })

        $miReset = $menu.Items.Add("Reset Position")
        $miReset.Add_Click({
            $wa = [System.Windows.SystemParameters]::WorkArea
            $window.Left = $wa.Right - $window.Width - 16
            $window.Top  = $wa.Top + 48
            Bring-ToFront
        })

        $miCollapse = $menu.Items.Add("Toggle Mini Pill")
        $miCollapse.Add_Click({
            Bring-ToFront
            Toggle-Collapse
        })

        [void]$menu.Items.Add("-")
        $miExit = $menu.Items.Add("Exit ClipQueue")
        $miExit.Add_Click({ $window.Close() })

        $tray.ContextMenuStrip = $menu
        $tray.Add_MouseClick({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                Bring-ToFront
            }
        })

        $script:trayIcon = $tray
    } catch { Write-SafeLog "TrayInit: $_" }
}

# --- Window Lifecycle & Native Hooks ---
$window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $script:windowHandle = $helper.Handle
        $script:hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($script:windowHandle)

        # Register native WM_CLIPBOARDUPDATE (0x031D) listener
        [void][ClipQueueNativeV4]::AddClipboardFormatListener($script:windowHandle)
        $script:hwndSource.AddHook([System.Windows.Interop.HwndSourceHook]{
            param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
            if ($msg -eq 0x031D) {
                # Queue check asynchronously on dispatcher so Win32 message returns immediately
                $window.Dispatcher.BeginInvoke([Action]{ Check-ClipboardChange }) | Out-Null
            }
            return [IntPtr]::Zero
        })
    } catch { Write-SafeLog "SourceInit: $_" }
})

$window.Add_Deactivated({
    if ($script:isPinned -and $window.WindowState -ne [System.Windows.WindowState]::Minimized -and $script:windowHandle -ne [IntPtr]::Zero) {
        [ClipQueueNativeV4]::EnforceTopMostNoActivate($script:windowHandle)
    }
})

$window.Add_Loaded({
    Sync-UIState
    Initialize-TrayIcon
    [void][ClipQueueNativeV4]::InstallKeyboardHook()
    $clipTimer.Start()
    $keyTimer.Start()
    $topmostTimer.Start()
})

$window.Add_Closed({
    $clipTimer.Stop()
    $keyTimer.Stop()
    $advanceTimer.Stop()
    $primeRetryTimer.Stop()
    $topmostTimer.Stop()
    [ClipQueueNativeV4]::UninstallKeyboardHook()
    if ($script:windowHandle -ne [IntPtr]::Zero) {
        [void][ClipQueueNativeV4]::RemoveClipboardFormatListener($script:windowHandle)
    }
    if ($script:trayIcon) {
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
    }
})

[void]$window.ShowDialog()
