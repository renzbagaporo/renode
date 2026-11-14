// Test access to the rescue DP, without a SWD pin driver.
using Antmicro.Renode.Core;

namespace Antmicro.Renode.Peripherals.CPU
{
    public sealed class RP2040TestDebugPort : RP2040_DebugPort
    {
        public RP2040TestDebugPort(IMachine machine, CortexM cpu0, CortexM cpu1) : base(machine, cpu0, cpu1) { }

        // TARGETSEL the rescue DP and set or clear its CDBGPWRUPREQ.
        public void Rescue(bool asserted)
        {
            SelectTarget(0xf1002927);
            CompleteWrite(false, 4, asserted ? 0x10000000u : 0);
        }
    }
}
