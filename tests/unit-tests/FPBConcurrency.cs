// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
using System;
using System.Threading;
using System.Threading.Tasks;

using Antmicro.Renode.Core;
using Antmicro.Renode.Exceptions;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class FPBConcurrencyTester : IDoubleWordPeripheral, IKnownSize
    {
        public FPBConcurrencyTester(IMachine machine, CortexM cpu0, CortexM cpu1)
        {
            this.machine = machine;
            this.cpu0 = cpu0;
            this.cpu1 = cpu1;
        }

        public void ReconfigureThroughMemAPWhileCorePollsRegisters()
        {
            using(var running = new ManualResetEventSlim())
            {
                var ownerThread = Thread.CurrentThread.ManagedThreadId;
                var executionThread = ownerThread;
                Action<ulong, uint> hook = (address, size) =>
                {
                    if(address == 0x108)
                    {
                        executionThread = Thread.CurrentThread.ManagedThreadId;
                        running.Set();
                    }
                };
                cpu0.AssembleBlock(0x100, "movw r0, #0x2000; movt r0, #0xe000; loop: ldr r1, [r0]; adds r2, #1; b loop");
                cpu0.PC = 0x100;
                cpu1.IsHalted = true;
                cpu0.SetHookAtBlockBegin(hook);
                var ap = new TestMemAP(machine, cpu0, cpu1);
                ap.PowerUp();
                ap.WriteMemory(0xe000edf0, 0xa05f0001);
                Assert(ap.ReadMemory(0xe0002000) == 0x10000080, "MEM-AP did not read the FPBv2 capability");
                try
                {
                    EmulationManager.Instance.CurrentEmulation.StartAll();
                    Assert(running.Wait(TimeSpan.FromSeconds(10)), "CPU did not enter its FPB polling loop");
                    Assert(executionThread != ownerThread, "Polling did not execute on the CPU thread");
                    var writer = Task.Run(() =>
                    {
                        for(var i = 0; i < 2000; i++)
                        {
                            ap.WriteMemory(0xe0002008, 0x20000101u + (uint)(i & 1) * 2);
                            ap.WriteMemory(0xe0002000, (uint)(2 | (i & 1)));
                            Assert((ap.ReadMemory(0xe0002000) & ~1u) == 0x10000080, "Torn FPB control read");
                        }
                        ap.WriteMemory(0xe0002008, 0x109);
                        ap.WriteMemory(0xe0002000, 3);
                    });
                    Assert(writer.Wait(TimeSpan.FromSeconds(15)), "MEM-AP programming deadlocked against the polling CPU");
                    Assert(SpinWait.SpinUntil(() => cpu0.HaltedByDebugger, TimeSpan.FromSeconds(10)), "New comparator did not halt the polling CPU");
                    Assert(cpu0.PC.RawValue == 0x108, "Comparator halt PC was imprecise");
                    Assert(cpu0.GetRegister(2).RawValue != 0, "Polling CPU did not execute real load instructions");
                    Assert(ap.ReadMemory(0xe000ed30) == 2, "MEM-AP did not observe DFSR.BKPT");
                }
                finally
                {
                    EmulationManager.Instance.CurrentEmulation.PauseAll();
                    cpu0.SetHookAtBlockBegin(null);
                }
            }
        }

        public void VerifyMemAPCoreIsolation()
        {
            var ap = new TestMemAP(machine, cpu0, cpu1);
            ap.PowerUp();
            ap.WriteMemory(0xe0002008, 0x101);
            ap.WriteMemory(0xe0002000, 3);
            Assert(ap.ReadMemory(0xe0002000) == 0x10000081, "Core0 FPB control did not enable");
            Assert(ap.ReadMemory(0xe0002000, 1) == 0x10000080, "Core0 FPB leaked into core1");
            Assert(ap.ReadMemory(0xe0002008, 1) == 0, "Comparator leaked into the other MEM-AP bank");
        }

        public uint ReadDoubleWord(long offset) => 0;
        public void WriteDoubleWord(long offset, uint value) { }
        public void Reset() { }
        public long Size => 4;

        private static void Assert(bool condition, string message)
        {
            if(!condition) throw new RecoverableException(message);
        }

        private sealed class TestMemAP : RP2350_DebugPort
        {
            public TestMemAP(IMachine machine, CortexM cpu0, CortexM cpu1) : base(machine, cpu0, cpu1) { }
            public void PowerUp() => CompleteWrite(false, 4, 0x50000000);

            public void WriteMemory(uint address, uint value, uint core = 0)
            {
                var bank = core == 0 ? 0x2000u : 0x4000u;
                WriteAP(bank + 0xd00, 0x23000002);
                WriteAP(bank + 0xd04, address);
                WriteAP(bank + 0xd0c, value);
            }

            public uint ReadMemory(uint address, uint core = 0)
            {
                var bank = core == 0 ? 0x2000u : 0x4000u;
                WriteAP(bank + 0xd00, 0x23000002);
                WriteAP(bank + 0xd04, address);
                var port = Select(bank + 0xd0c);
                Assert((int)BeginTransfer(true, true, port, out var _) == 1, "MEM-AP read was not acknowledged");
                Assert((int)BeginTransfer(false, true, 12, out var value) == 1, "MEM-AP read buffer was not acknowledged");
                return value;
            }

            private byte Select(uint address)
            {
                CompleteWrite(false, 8, address & ~0xfu);
                return (byte)(address & 0xc);
            }

            private void WriteAP(uint address, uint value)
            {
                var port = Select(address);
                Assert((int)BeginTransfer(true, false, port, out var _) == 1, "MEM-AP write was not acknowledged");
                CompleteWrite(true, port, value);
            }
        }

        private readonly IMachine machine;
        private readonly CortexM cpu0;
        private readonly CortexM cpu1;
    }
}
