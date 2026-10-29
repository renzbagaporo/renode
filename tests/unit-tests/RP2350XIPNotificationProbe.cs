// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
using System.Threading;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.MemoryControllers;
using Antmicro.Renode.Peripherals.Memory;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class RP2350XIPNotificationProbe : IDoubleWordPeripheral, IKnownSize
    {
        public RP2350XIPNotificationProbe(RP2350_XIP cache, RP2350_XIPMemory memory = null)
        {
            this.cache = cache;
            this.memory = memory;
            cache.ConfigurationChanged += CheckForeignAccess;
            cache.ContentsChanged += (_, __) => CheckForeignAccess();
        }
        public uint ReadDoubleWord(long offset) => (uint)Status;
        public void WriteDoubleWord(long offset, uint value) => Reset();
        public long Size => 4;
        public int Status { get; private set; }
        public uint ExpectedWord { get; set; }
        public bool ObservedPartialWord { get; private set; }
        public void Reset() { Status = 0; }
        private void CheckForeignAccess()
        {
            var worker = new Thread(() =>
            {
                cache.ReadDoubleWord(0);
                cache.RecordAccess(false);
                if(memory != null && memory.ReadDoubleWord(0x1ffc000) != ExpectedWord) ObservedPartialWord = true;
            });
            worker.IsBackground = true;
            worker.Start();
            Status = worker.Join(2000) ? 1 : 2;
        }
        private readonly RP2350_XIP cache;
        private readonly RP2350_XIPMemory memory;
    }
}
