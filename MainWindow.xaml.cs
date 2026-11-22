using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace ClipQueue
{
    public class ClipItem : INotifyPropertyChanged
    {
        private string _id;
        private string _text;
        private string _indexLabel;
        private bool _isActive;

        public string Id
        {
            get => _id;
            set { _id = value; OnPropertyChanged(nameof(Id)); }
        }

        public string Text
        {
            get => _text;
            set
            {
                _text = value ?? string.Empty;
                OnPropertyChanged(nameof(Text));
                OnPropertyChanged(nameof(Preview));
            }
        }

        public string Preview
        {
            get
            {
                if (string.IsNullOrEmpty(_text)) return string.Empty;
                string clean = _text.Replace("\r\n", " ").Replace("\n", " ").Replace("\r", " ").Trim();
                return clean.Length > 90 ? clean.Substring(0, 90) + "..." : clean;
            }
        }

        public string IndexLabel
        {
            get => _indexLabel;
            set { _indexLabel = value; OnPropertyChanged(nameof(IndexLabel)); }
        }

        public bool IsActive
        {
            get => _isActive;
            set { _isActive = value; OnPropertyChanged(nameof(IsActive)); }
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public partial class MainWindow : Window
    {
        private readonly ObservableCollection<ClipItem> _items = new ObservableCollection<ClipItem>();

        private int _activeIndex = -1;
        private string _lastClipboard = string.Empty;
        private uint _lastClipSeq;
        private uint _lastWrittenSeq;
        private string _lastWrittenText = string.Empty;
        private DateTime _lastWrittenAt = DateTime.MinValue;
        private string _lastCapturedText = string.Empty;
        private DateTime _lastCapturedAt = DateTime.MinValue;

        // Delayed rendering state (enables detection of Right-Click -> Paste, Edit -> Paste, Shift+Insert, AND Ctrl+V)
        private bool _isWritingClip = false;
        private string _delayedText = null;
        private string _delayedItemId = null;
        private DateTime _delayedArmedAt = DateTime.MinValue;
        private int _rearmCountForItem = 0;

        private string _pendingConsumeItemId = null;
        private string _pendingPrimeItemId = null;
        private int _primeRetriesLeft = 0;

        private bool _isPinned = true;
        private bool _isCapturing = true;
        private bool _isCollapsed = false;
        private double _expandedHeight = 500;
        private double _expandedWidth = 372;
        private bool _suppressSelect = false;

        private ClipItem _editingItem = null;
        private bool _isAddingNew = false;
        private ClipItem _dragItem = null;
        private Point _dragStartPt;

        private IntPtr _windowHandle = IntPtr.Zero;
        private HwndSource _hwndSource = null;
        private System.Windows.Forms.NotifyIcon _trayIcon = null;

        private readonly DispatcherTimer _clipTimer;
        private readonly DispatcherTimer _primeRetryTimer;
        private readonly DispatcherTimer _consumeTimer;
        private readonly DispatcherTimer _rearmTimer;
        private readonly DispatcherTimer _keyTimer;
        private readonly DispatcherTimer _topmostTimer;

        private readonly SolidColorBrush _brushBlue  = new SolidColorBrush(Color.FromRgb(0x60, 0xA5, 0xFA));
        private readonly SolidColorBrush _brushGreen = new SolidColorBrush(Color.FromRgb(0x22, 0xC5, 0x5E));
        private readonly SolidColorBrush _brushMuted = new SolidColorBrush(Color.FromRgb(0x6B, 0x72, 0x80));

        public MainWindow()
        {
            InitializeComponent();
            QueueList.ItemsSource = _items;

            Rect wa = SystemParameters.WorkArea;
            Left = wa.Right - Width - 16;
            Top = wa.Top + 48;

            _lastClipSeq = NativeWin32.GetClipboardSequenceNumber();
            try
            {
                if (Clipboard.ContainsText())
                {
                    _lastClipboard = Clipboard.GetText();
                }
            }
            catch { }

            _clipTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            _clipTimer.Tick += (_, __) => CheckClipboardChange();

            _primeRetryTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
            _primeRetryTimer.Tick += PrimeRetryTimer_Tick;

            _consumeTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(160) };
            _consumeTimer.Tick += ConsumeTimer_Tick;

            _rearmTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
            _rearmTimer.Tick += RearmTimer_Tick;

            _keyTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(25) };
            _keyTimer.Tick += KeyTimer_Tick;

            _topmostTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            _topmostTimer.Tick += (_, __) =>
            {
                if (_isPinned && WindowState != WindowState.Minimized && _windowHandle != IntPtr.Zero)
                {
                    NativeWin32.EnforceTopMostNoActivate(_windowHandle);
                }
            };

            SourceInitialized += MainWindow_SourceInitialized;
            Loaded += MainWindow_Loaded;
            Deactivated += MainWindow_Deactivated;
            Closed += MainWindow_Closed;
        }

        private void MainWindow_SourceInitialized(object sender, EventArgs e)
        {
            _windowHandle = new WindowInteropHelper(this).Handle;
            _hwndSource = HwndSource.FromHwnd(_windowHandle);
            _hwndSource?.AddHook(WndProc);
            NativeWin32.AddClipboardFormatListener(_windowHandle);
        }

        private void MainWindow_Loaded(object sender, RoutedEventArgs e)
        {
            SyncUIState();
            InitializeTrayIcon();
            NativeWin32.InstallKeyboardHook();
            _clipTimer.Start();
            _keyTimer.Start();
            _topmostTimer.Start();
        }

        private void MainWindow_Deactivated(object sender, EventArgs e)
        {
            if (_isPinned && WindowState != WindowState.Minimized && _windowHandle != IntPtr.Zero)
            {
                NativeWin32.EnforceTopMostNoActivate(_windowHandle);
            }
        }

        private void MainWindow_Closed(object sender, EventArgs e)
        {
            _clipTimer.Stop();
            _keyTimer.Stop();
            _consumeTimer.Stop();
            _primeRetryTimer.Stop();
            _rearmTimer.Stop();
            _topmostTimer.Stop();
            NativeWin32.UninstallKeyboardHook();

            if (_windowHandle != IntPtr.Zero)
            {
                NativeWin32.RemoveClipboardFormatListener(_windowHandle);
            }
            if (_trayIcon != null)
            {
                _trayIcon.Visible = false;
                _trayIcon.Dispose();
                _trayIcon = null;
            }
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == NativeWin32.WM_RENDERFORMAT)
            {
                if (wParam.ToInt32() == (int)NativeWin32.CF_UNICODETEXT && _delayedText != null)
                {
                    NativeWin32.RenderUnicodeTextToClipboard(_delayedText);
                    _lastClipSeq = NativeWin32.GetClipboardSequenceNumber();

                    double msSinceArmed = (DateTime.UtcNow - _delayedArmedAt).TotalMilliseconds;
                    if (msSinceArmed >= 250)
                    {
                        // Genuine paste (Right-Click -> Paste, Ctrl+V, Edit -> Paste, Shift+Insert)
                        string itemId = _delayedItemId;
                        Dispatcher.BeginInvoke(new Action(() => ScheduleConsume(itemId)));
                    }
                    else if (_rearmCountForItem < 2)
                    {
                        // Immediate background reader (e.g. Windows Clipboard History) — re-arm without consuming
                        _rearmCountForItem++;
                        Dispatcher.BeginInvoke(new Action(() =>
                        {
                            _rearmTimer.Stop();
                            _rearmTimer.Start();
                        }));
                    }
                    handled = true;
                }
                return IntPtr.Zero;
            }

            if (msg == NativeWin32.WM_RENDERALLFORMATS)
            {
                if (_delayedText != null && NativeWin32.OpenClipboard(hwnd))
                {
                    try
                    {
                        NativeWin32.RenderUnicodeTextToClipboard(_delayedText);
                    }
                    finally
                    {
                        NativeWin32.CloseClipboard();
                    }
                }
                handled = true;
                return IntPtr.Zero;
            }

            if (msg == NativeWin32.WM_DESTROYCLIPBOARD)
            {
                if (!_isWritingClip)
                {
                    _delayedText = null;
                    _delayedItemId = null;
                }
                return IntPtr.Zero;
            }

            if (msg == NativeWin32.WM_CLIPBOARDUPDATE)
            {
                Dispatcher.BeginInvoke(new Action(CheckClipboardChange));
            }

            return IntPtr.Zero;
        }

        private bool TryArmDelayedClipboardNow(ClipItem item)
        {
            if (item == null || _windowHandle == IntPtr.Zero) return false;
            _isWritingClip = true;
            bool ok = false;
            for (int i = 0; i < 5; i++)
            {
                if (NativeWin32.SetDelayedClipboard(_windowHandle))
                {
                    uint seq = NativeWin32.GetClipboardSequenceNumber();
                    _delayedText = item.Text;
                    _delayedItemId = item.Id;
                    _delayedArmedAt = DateTime.UtcNow;
                    _lastClipboard = item.Text;
                    _lastWrittenText = item.Text;
                    _lastWrittenAt = DateTime.UtcNow;
                    _lastWrittenSeq = seq;
                    _lastClipSeq = seq;
                    ok = true;
                    break;
                }
                System.Threading.Thread.Sleep(20);
            }
            _isWritingClip = false;
            return ok;
        }

        private void PrimeActiveItem(bool resetRearmCounter = true)
        {
            if (_activeIndex >= 0 && _activeIndex < _items.Count)
            {
                ClipItem active = _items[_activeIndex];
                if (resetRearmCounter) _rearmCountForItem = 0;

                if (TryArmDelayedClipboardNow(active))
                {
                    _pendingPrimeItemId = null;
                    _primeRetriesLeft = 0;
                    _primeRetryTimer.Stop();
                }
                else
                {
                    _pendingPrimeItemId = active.Id;
                    _primeRetriesLeft = 10;
                    _primeRetryTimer.Stop();
                    _primeRetryTimer.Start();
                }
            }
            SyncUIState();
        }

        private void PrimeRetryTimer_Tick(object sender, EventArgs e)
        {
            if (string.IsNullOrEmpty(_pendingPrimeItemId) || _primeRetriesLeft <= 0)
            {
                _primeRetryTimer.Stop();
                return;
            }
            _primeRetriesLeft--;
            if (_activeIndex >= 0 && _activeIndex < _items.Count && _items[_activeIndex].Id == _pendingPrimeItemId)
            {
                if (TryArmDelayedClipboardNow(_items[_activeIndex]))
                {
                    _pendingPrimeItemId = null;
                    _primeRetriesLeft = 0;
                    _primeRetryTimer.Stop();
                }
            }
            else
            {
                _primeRetryTimer.Stop();
            }
        }

        private void RearmTimer_Tick(object sender, EventArgs e)
        {
            _rearmTimer.Stop();
            if (_activeIndex >= 0 && _activeIndex < _items.Count && !_consumeTimer.IsEnabled)
            {
                PrimeActiveItem(resetRearmCounter: false);
            }
        }

        private void ScheduleConsume(string itemId)
        {
            if (string.IsNullOrEmpty(itemId)) return;
            if (TxtEdit.IsKeyboardFocused) return;

            // If we already scheduled consumption for this exact item (e.g., Ctrl+V + WM_RENDERFORMAT both fired), deduplicate!
            if (_consumeTimer.IsEnabled && _pendingConsumeItemId == itemId)
            {
                return;
            }

            // If a DIFFERENT previous item was still waiting to consume during rapid pastes, consume it now
            if (_consumeTimer.IsEnabled && _pendingConsumeItemId != null && _pendingConsumeItemId != itemId)
            {
                _consumeTimer.Stop();
                ConsumeItemById(_pendingConsumeItemId);
            }

            _pendingConsumeItemId = itemId;
            _consumeTimer.Stop();
            _consumeTimer.Start();
        }

        private void ConsumeTimer_Tick(object sender, EventArgs e)
        {
            _consumeTimer.Stop();
            string id = _pendingConsumeItemId;
            _pendingConsumeItemId = null;
            if (!string.IsNullOrEmpty(id))
            {
                ConsumeItemById(id);
            }
        }

        private void ConsumeItemById(string itemId)
        {
            int idx = -1;
            for (int i = 0; i < _items.Count; i++)
            {
                if (_items[i].Id == itemId) { idx = i; break; }
            }
            if (idx < 0) return;

            string pastedText = _items[idx].Text;
            _items.RemoveAt(idx);

            if (_items.Count == 0)
            {
                _activeIndex = -1;
                _delayedText = null;
                _delayedItemId = null;
                _pendingPrimeItemId = null;
                _primeRetryTimer.Stop();
                _rearmTimer.Stop();
                _lastClipboard = pastedText;
                _lastClipSeq = NativeWin32.GetClipboardSequenceNumber();
                SyncUIState();
            }
            else
            {
                if (idx < _activeIndex)
                {
                    _activeIndex--;
                }
                else if (_activeIndex >= _items.Count)
                {
                    _activeIndex = 0;
                }
                PrimeActiveItem();
            }
        }

        private void KeyTimer_Tick(object sender, EventArgs e)
        {
            int pastes = NativeWin32.ConsumePasteCount();
            if (pastes > 0 && !TxtEdit.IsKeyboardFocused)
            {
                if (_activeIndex >= 0 && _activeIndex < _items.Count)
                {
                    ScheduleConsume(_items[_activeIndex].Id);
                }
            }
        }

        private void CheckClipboardChange()
        {
            if (!_isCapturing || _isWritingClip) return;

            uint seq = NativeWin32.GetClipboardSequenceNumber();
            if (seq == _lastClipSeq || seq == _lastWrittenSeq) return;

            // If we currently own delayed rendering for our own active item, don't read our own clipboard!
            if (_delayedItemId != null) return;

            try
            {
                if (!Clipboard.ContainsText())
                {
                    _lastClipSeq = seq;
                    return;
                }

                string current = Clipboard.GetText();
                _lastClipSeq = seq;

                if (string.IsNullOrEmpty(current)) return;

                double msSinceWrite = (DateTime.UtcNow - _lastWrittenAt).TotalMilliseconds;
                if (current == _lastWrittenText && msSinceWrite < 1200) return;

                double msSinceCap = (DateTime.UtcNow - _lastCapturedAt).TotalMilliseconds;
                if (current == _lastCapturedText && msSinceCap < 900) return;

                if (current == _lastClipboard && !NativeWin32.WasCopyKeyPressedRecently(1500))
                {
                    return;
                }

                _lastClipboard = current;
                _lastCapturedText = current;
                _lastCapturedAt = DateTime.UtcNow;

                var newItem = new ClipItem
                {
                    Id = Guid.NewGuid().ToString(),
                    Text = current
                };
                _items.Add(newItem);

                if (_activeIndex < 0 || _activeIndex >= _items.Count - 1)
                {
                    _activeIndex = _items.Count - 1;
                }
                PrimeActiveItem();
            }
            catch
            {
                // Source app briefly locked clipboard; next tick retries cleanly
            }
        }

        private void SyncUIState()
        {
            int count = _items.Count;
            EmptyState.Visibility = count == 0 ? Visibility.Visible : Visibility.Collapsed;

            for (int i = 0; i < count; i++)
            {
                _items[i].IndexLabel = $"{i + 1}.";
                _items[i].IsActive = (i == _activeIndex);
            }

            if (count == 0 || _activeIndex < 0 || _activeIndex >= count)
            {
                TxtCount.Text = "0";
                TxtMiniPreview.Text = string.Empty;
            }
            else
            {
                TxtCount.Text = $"{_activeIndex + 1}/{count}";
                TxtMiniPreview.Text = _items[_activeIndex].Preview;
            }

            _suppressSelect = true;
            if (_activeIndex >= 0 && _activeIndex < count)
            {
                QueueList.SelectedIndex = _activeIndex;
                QueueList.ScrollIntoView(_items[_activeIndex]);
            }
            else
            {
                QueueList.SelectedIndex = -1;
            }
            _suppressSelect = false;
        }

        // --- System Tray ---
        private void InitializeTrayIcon()
        {
            try
            {
                var tray = new System.Windows.Forms.NotifyIcon();
                string exePath = Process.GetCurrentProcess().MainModule?.FileName;
                if (!string.IsNullOrEmpty(exePath))
                {
                    tray.Icon = System.Drawing.Icon.ExtractAssociatedIcon(exePath);
                }
                if (tray.Icon == null)
                {
                    tray.Icon = System.Drawing.SystemIcons.Application;
                }

                tray.Text = "ClipQueue (Click to show)";
                tray.Visible = true;

                var menu = new System.Windows.Forms.ContextMenuStrip();
                menu.Items.Add("Show / Bring to Front", null, (_, __) => Dispatcher.Invoke(BringToFront));
                menu.Items.Add("Reset Position", null, (_, __) => Dispatcher.Invoke(() =>
                {
                    Rect wa = SystemParameters.WorkArea;
                    Left = wa.Right - Width - 16;
                    Top = wa.Top + 48;
                    BringToFront();
                }));
                menu.Items.Add("Toggle Mini Pill", null, (_, __) => Dispatcher.Invoke(() =>
                {
                    BringToFront();
                    ToggleCollapse();
                }));
                menu.Items.Add("-");
                menu.Items.Add("Exit ClipQueue", null, (_, __) => Dispatcher.Invoke(Close));

                tray.ContextMenuStrip = menu;
                tray.MouseClick += (_, e) =>
                {
                    if (e.Button == System.Windows.Forms.MouseButtons.Left)
                    {
                        Dispatcher.Invoke(BringToFront);
                    }
                };
                _trayIcon = tray;
            }
            catch { }
        }

        private void BringToFront()
        {
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
            Rect wa = SystemParameters.WorkArea;
            if (Left < wa.Left - 80 || Left > wa.Right - 60) Left = wa.Right - Width - 16;
            if (Top < wa.Top - 20 || Top > wa.Bottom - 60) Top = wa.Top + 48;
            Show();
            Topmost = false;
            Topmost = _isPinned;
            Activate();
        }

        // --- Header & Footer Actions ---
        private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (FindAncestor<Button>(e.OriginalSource as DependencyObject) != null) return;
            if (e.ClickCount == 2) ToggleCollapse();
            else if (e.LeftButton == MouseButtonState.Pressed) DragMove();
        }

        private void BtnPin_Click(object sender, RoutedEventArgs e)
        {
            _isPinned = !_isPinned;
            Topmost = _isPinned;
            IconPin.Fill = _isPinned ? _brushBlue : _brushMuted;
            BtnPin.ToolTip = _isPinned ? "Always on Top: ON" : "Always on Top: OFF";
            if (_isPinned && _windowHandle != IntPtr.Zero)
            {
                NativeWin32.EnforceTopMostNoActivate(_windowHandle);
            }
        }

        private void BtnCapture_Click(object sender, RoutedEventArgs e)
        {
            _isCapturing = !_isCapturing;
            IconCapture.Fill = _isCapturing ? _brushGreen : _brushMuted;
            CaptureDot.Fill = _isCapturing ? _brushGreen : _brushMuted;
            BtnCapture.ToolTip = _isCapturing ? "Auto-Capture: ON" : "Auto-Capture: OFF (Paused)";
            if (_isCapturing)
            {
                _lastClipSeq = NativeWin32.GetClipboardSequenceNumber();
            }
        }

        private void BtnCollapse_Click(object sender, RoutedEventArgs e) => ToggleCollapse();
        private void BtnMinimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
        private void BtnClose_Click(object sender, RoutedEventArgs e) => Close();

        private void ToggleCollapse()
        {
            _isCollapsed = !_isCollapsed;
            if (_isCollapsed)
            {
                _expandedHeight = Height;
                _expandedWidth = Width;
                CloseEditDrawer();
                BodyPanel.Visibility = Visibility.Collapsed;
                FooterBar.Visibility = Visibility.Collapsed;
                ResizeGripVisual.Visibility = Visibility.Collapsed;
                ResizeTop.Visibility = Visibility.Collapsed;
                ResizeBottom.Visibility = Visibility.Collapsed;
                ResizeTopLeft.Visibility = Visibility.Collapsed;
                ResizeTopRight.Visibility = Visibility.Collapsed;
                ResizeBottomLeft.Visibility = Visibility.Collapsed;
                ResizeBottomRight.Visibility = Visibility.Collapsed;
                TxtTitle.Visibility = Visibility.Collapsed;
                CountBadge.Visibility = Visibility.Collapsed;
                TxtMiniPreview.Visibility = Visibility.Visible;
                TitleBar.CornerRadius = new CornerRadius(14);
                TitleBar.BorderThickness = new Thickness(0);
                MinHeight = 72;
                Height = 72;
                BtnCollapse.ToolTip = "Expand Queue";
                IconCollapse.Data = Geometry.Parse("M7.41,8.58L12,13.17L16.59,8.58L18,10L12,16L6,10L7.41,8.58Z");
            }
            else
            {
                BodyPanel.Visibility = Visibility.Visible;
                FooterBar.Visibility = Visibility.Visible;
                ResizeGripVisual.Visibility = Visibility.Visible;
                ResizeTop.Visibility = Visibility.Visible;
                ResizeBottom.Visibility = Visibility.Visible;
                ResizeTopLeft.Visibility = Visibility.Visible;
                ResizeTopRight.Visibility = Visibility.Visible;
                ResizeBottomLeft.Visibility = Visibility.Visible;
                ResizeBottomRight.Visibility = Visibility.Visible;
                TxtTitle.Visibility = Visibility.Visible;
                CountBadge.Visibility = Visibility.Visible;
                TxtMiniPreview.Visibility = Visibility.Collapsed;
                TitleBar.CornerRadius = new CornerRadius(14, 14, 0, 0);
                TitleBar.BorderThickness = new Thickness(0, 0, 0, 1);
                MinHeight = 180;
                Height = _expandedHeight;
                Width = _expandedWidth;
                BtnCollapse.ToolTip = "Collapse to Mini Pill";
                IconCollapse.Data = Geometry.Parse("M7.41,15.41L12,10.83L16.59,15.41L18,14L12,8L6,14L7.41,15.41Z");
            }
        }

        private void BtnAdd_Click(object sender, RoutedEventArgs e) => OpenEditDrawer(null, true);

        private void BtnClear_Click(object sender, RoutedEventArgs e)
        {
            _items.Clear();
            _activeIndex = -1;
            _delayedText = null;
            _delayedItemId = null;
            _pendingPrimeItemId = null;
            _primeRetryTimer.Stop();
            _rearmTimer.Stop();
            CloseEditDrawer();
            _lastClipSeq = NativeWin32.GetClipboardSequenceNumber();
            SyncUIState();
        }

        private void BtnNext_Click(object sender, RoutedEventArgs e)
        {
            if (_items.Count == 0) return;
            _activeIndex = (_activeIndex + 1) % _items.Count;
            PrimeActiveItem();
        }

        // --- Edit Drawer ---
        private void OpenEditDrawer(ClipItem item, bool isNew)
        {
            if (_isCollapsed) ToggleCollapse();
            _isAddingNew = isNew;
            _editingItem = item;
            TxtEdit.Text = isNew || item == null ? string.Empty : item.Text;
            EditDrawer.Visibility = Visibility.Visible;
            TxtEdit.Focus();
            TxtEdit.CaretIndex = TxtEdit.Text.Length;
        }

        private void CloseEditDrawer()
        {
            EditDrawer.Visibility = Visibility.Collapsed;
            _editingItem = null;
            _isAddingNew = false;
        }

        private void SaveEditDrawer()
        {
            string val = TxtEdit.Text;
            if (string.IsNullOrWhiteSpace(val)) { CloseEditDrawer(); return; }

            if (_isAddingNew)
            {
                var item = new ClipItem { Id = Guid.NewGuid().ToString(), Text = val };
                _items.Add(item);
                if (_activeIndex < 0 || _activeIndex >= _items.Count - 1)
                {
                    _activeIndex = _items.Count - 1;
                }
                PrimeActiveItem();
            }
            else if (_editingItem != null)
            {
                _editingItem.Text = val;
                int idx = _items.IndexOf(_editingItem);
                if (idx == _activeIndex) PrimeActiveItem();
                else SyncUIState();
            }
            CloseEditDrawer();
        }

        private void BtnSaveEdit_Click(object sender, RoutedEventArgs e) => SaveEditDrawer();
        private void BtnCancelEdit_Click(object sender, RoutedEventArgs e) => CloseEditDrawer();

        private void TxtEdit_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Control) != 0)
            {
                e.Handled = true;
                SaveEditDrawer();
            }
            else if (e.Key == Key.Escape)
            {
                e.Handled = true;
                CloseEditDrawer();
            }
        }

        // --- Card Actions & ListBox Drag/Drop ---
        private void CardEdit_Click(object sender, RoutedEventArgs e)
        {
            e.Handled = true;
            if ((sender as FrameworkElement)?.DataContext is ClipItem item)
            {
                OpenEditDrawer(item, false);
            }
        }

        private void CardDelete_Click(object sender, RoutedEventArgs e)
        {
            e.Handled = true;
            if ((sender as FrameworkElement)?.DataContext is ClipItem item)
            {
                ConsumeItemById(item.Id);
            }
        }

        private void QueueList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_suppressSelect) return;
            if (QueueList.SelectedIndex >= 0 && QueueList.SelectedIndex < _items.Count)
            {
                _activeIndex = QueueList.SelectedIndex;
                PrimeActiveItem();
            }
        }

        private void QueueList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
        {
            if (FindAncestor<Button>(e.OriginalSource as DependencyObject) != null) return;
            if (QueueList.SelectedItem is ClipItem item) OpenEditDrawer(item, false);
        }

        private void QueueList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (FindAncestor<Button>(e.OriginalSource as DependencyObject) != null)
            {
                _dragItem = null;
                return;
            }
            _dragStartPt = e.GetPosition(QueueList);
            var lbi = FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject);
            _dragItem = lbi?.DataContext as ClipItem;
        }

        private void QueueList_PreviewMouseMove(object sender, MouseEventArgs e)
        {
            if (e.LeftButton == MouseButtonState.Pressed && _dragItem != null)
            {
                Point pos = e.GetPosition(QueueList);
                if (Math.Abs(pos.X - _dragStartPt.X) > 6 || Math.Abs(pos.Y - _dragStartPt.Y) > 6)
                {
                    ClipItem toDrag = _dragItem;
                    _dragItem = null;
                    DragDrop.DoDragDrop(QueueList, toDrag, DragDropEffects.Move);
                }
            }
        }

        private void QueueList_DragOver(object sender, DragEventArgs e)
        {
            e.Effects = DragDropEffects.Move;
            e.Handled = true;
        }

        private void QueueList_Drop(object sender, DragEventArgs e)
        {
            if (!(e.Data.GetData(typeof(ClipItem)) is ClipItem dropped)) return;
            var targetLbi = FindAncestor<ListBoxItem>(e.OriginalSource as DependencyObject);
            int oldIdx = _items.IndexOf(dropped);
            int newIdx = targetLbi?.DataContext is ClipItem targetItem ? _items.IndexOf(targetItem) : _items.Count - 1;

            if (oldIdx >= 0 && newIdx >= 0 && oldIdx != newIdx)
            {
                string activeId = (_activeIndex >= 0 && _activeIndex < _items.Count) ? _items[_activeIndex].Id : null;
                _items.Move(oldIdx, newIdx);
                if (activeId != null)
                {
                    for (int i = 0; i < _items.Count; i++)
                    {
                        if (_items[i].Id == activeId) { _activeIndex = i; break; }
                    }
                }
                PrimeActiveItem();
            }
        }

        // --- 8-Way Resize ---
        private void ResizeWindowEdge(double dLeft = 0, double dTop = 0, double dRight = 0, double dBottom = 0)
        {
            if (dLeft != 0)
            {
                double newW = Width - dLeft;
                if (newW < MinWidth) { dLeft = Width - MinWidth; newW = MinWidth; }
                Left += dLeft;
                Width = newW;
            }
            if (dRight != 0)
            {
                Width = Math.Max(MinWidth, Width + dRight);
            }
            if (!_isCollapsed)
            {
                if (dTop != 0)
                {
                    double newH = Height - dTop;
                    if (newH < MinHeight) { dTop = Height - MinHeight; newH = MinHeight; }
                    Top += dTop;
                    Height = newH;
                }
                if (dBottom != 0)
                {
                    Height = Math.Max(MinHeight, Height + dBottom);
                }
                _expandedHeight = Height;
            }
            _expandedWidth = Width;
        }

        private void ResizeLeft_DragDelta(object s, DragDeltaEventArgs e)        => ResizeWindowEdge(dLeft: e.HorizontalChange);
        private void ResizeRight_DragDelta(object s, DragDeltaEventArgs e)       => ResizeWindowEdge(dRight: e.HorizontalChange);
        private void ResizeTop_DragDelta(object s, DragDeltaEventArgs e)         => ResizeWindowEdge(dTop: e.VerticalChange);
        private void ResizeBottom_DragDelta(object s, DragDeltaEventArgs e)      => ResizeWindowEdge(dBottom: e.VerticalChange);
        private void ResizeTopLeft_DragDelta(object s, DragDeltaEventArgs e)     => ResizeWindowEdge(dLeft: e.HorizontalChange, dTop: e.VerticalChange);
        private void ResizeTopRight_DragDelta(object s, DragDeltaEventArgs e)    => ResizeWindowEdge(dRight: e.HorizontalChange, dTop: e.VerticalChange);
        private void ResizeBottomLeft_DragDelta(object s, DragDeltaEventArgs e)  => ResizeWindowEdge(dLeft: e.HorizontalChange, dBottom: e.VerticalChange);
        private void ResizeBottomRight_DragDelta(object s, DragDeltaEventArgs e) => ResizeWindowEdge(dRight: e.HorizontalChange, dBottom: e.VerticalChange);

        private static T FindAncestor<T>(DependencyObject current) where T : DependencyObject
        {
            while (current != null)
            {
                if (current is T match) return match;
                current = (current is Visual || current is System.Windows.Media.Media3D.Visual3D)
                    ? VisualTreeHelper.GetParent(current)
                    : LogicalTreeHelper.GetParent(current);
            }
            return null;
        }
    }
}
