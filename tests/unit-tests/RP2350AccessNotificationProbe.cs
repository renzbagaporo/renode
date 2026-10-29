// Verify that the real GPIO callback can access its ACCESSCTRL provider on a
// foreign thread, without inheriting the callback producer's transaction state.
using System;
using System.Threading;
using Antmicro.Migrant;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.GPIOPort;
using Antmicro.Renode.Peripherals.Miscellaneous;

namespace Antmicro.Renode.PeripheralsTests
{
    public sealed class RP2350AccessNotificationProbe : IDoubleWordPeripheral, IKnownSize
    {
        public RP2350AccessNotificationProbe(RP2_GPIOBank0 gpio, RP2350_AccessControl access)
        {
            this.access = access;
            gpio.DriveChanged += OnDriveChanged;
        }
        public void Arm() { armed = true; status = 0; }
        public uint ReadDoubleWord(long offset)
        {
            worker?.Join(2000);
            return status;
        }
        public void WriteDoubleWord(long offset, uint value) { }
        public void Reset() { armed = false; status = 0; }
        public long Size => 0x1000;
        private void OnDriveChanged(int pin, bool level, bool enabled)
        {
            if(!armed || pin != 0) return;
            armed = false;
            var done = new ManualResetEventSlim();
            var success = false;
            worker = new Thread(() =>
            {
                try
                {
                    var value = access.ReadDoubleWord(0xc);
                    access.WriteDoubleWord(0xc, value);
                    success = true;
                }
                finally { done.Set(); }
            }) { IsBackground = true };
            worker.Start();
            status = done.Wait(2000) && success ? 1u : 2u;
        }
        private readonly RP2350_AccessControl access;
        [Transient]
        private Thread worker;
        private bool armed;
        private uint status;
    }
}
