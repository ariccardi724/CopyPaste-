using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace ClipQueue
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += OnDispatcherUnhandledException;
        }

        private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            try
            {
                string logPath = Path.Combine(AppContext.BaseDirectory, "clipqueue_error.log");
                File.AppendAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {e.Exception}\r\n");
            }
            catch { }
            e.Handled = true;
        }
    }
}
