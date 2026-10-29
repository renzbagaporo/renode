// Test access to the actual DP/AP transfer engine, without a SWD pin driver.
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.CPU
{
    public sealed class RP2350TestDebugPort : RP2350_DebugPort, IDoubleWordPeripheral, IKnownSize
    {
        public RP2350TestDebugPort(IMachine machine, CortexM cpu0, CortexM cpu1) : base(machine, cpu0, cpu1) { }
        public long Size => 0x1000;
        public uint ReadDoubleWord(long offset) => ReadPowerControl();
        public void WriteDoubleWord(long offset, uint value) => CompleteWrite(false, (byte)(offset & 0xc), value);
        public void EnableDebugPower() => CompleteWrite(false, 4, 0x50000000);
        public uint ReadPowerControl()
        {
            BeginTransfer(false, true, 4, out var value);
            return value;
        }
        public uint ReadCoreMemory(int core, uint address, bool secure = true)
        {
            var ap = core == 0 ? 0x2000u : 0x4000u;
            WriteAP(ap + 0xd00, 0x0b800052u | (secure ? 0u : 0x40000000u));
            WriteAP(ap + 0xd04, address);
            return ReadAP(ap + 0xd0c);
        }
        public void WriteCoreMemory(int core, uint address, uint value, bool secure = true)
        {
            var ap = core == 0 ? 0x2000u : 0x4000u;
            WriteAP(ap + 0xd00, 0x0b800052u | (secure ? 0u : 0x40000000u));
            WriteAP(ap + 0xd04, address);
            WriteAP(ap + 0xd0c, value);
        }
        private uint ReadAP(uint address)
        {
            CompleteWrite(false, 8, address & ~0xfu);
            if((int)BeginTransfer(true, true, (byte)(address & 0xc), out var _) != 1) throw new InvalidOperationException("AP read refused");
            BeginTransfer(false, true, 12, out var value);
            return value;
        }
        private void WriteAP(uint address, uint value)
        {
            CompleteWrite(false, 8, address & ~0xfu);
            if((int)BeginTransfer(true, false, (byte)(address & 0xc), out var _) != 1) throw new InvalidOperationException("AP write refused");
            CompleteWrite(true, (byte)(address & 0xc), value);
        }
        public void Rescue(bool asserted)
        {
            CompleteWrite(false, 8, 0x80000);
            var ack = BeginTransfer(true, false, 0, out var _);
            if((int)ack != 1) throw new InvalidOperationException("RP-AP refused transfer");
            CompleteWrite(true, 0, asserted ? 0x80000000u : 0);
        }
    }
}
